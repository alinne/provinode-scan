import Foundation
import ProvinodeRoomContracts
import UIKit

@MainActor
final class CaptureViewModel: ObservableObject {
    @Published var discoveredEndpoints: [PairingEndpoint] = []
    @Published var selectedEndpoint: PairingEndpoint?
    @Published var manualHost: String = ""
    @Published var manualPort: String = "7448"
    @Published var manualQuicPort: String = "7447"
    @Published var manualPairingFingerprintSha256: String = ""
    @Published var pairingCode: String = ""
    @Published var pairingNonce: String = ""
    @Published var pairingQrPayloadJson: String = ""
    @Published var isQrScannerPresented = false
    @Published var isCalibrationPatternPresented = false
    @Published var status: String = "Idle"
    @Published var isCapturing = false
    @Published var metrics = ScanSessionMetrics()
    @Published var lastSessionDirectory: URL?
    @Published var lastExportPath: URL?

    private let discovery = LanDiscoveryService()
    private let trustStore: TrustStore
    private let scanIdentityStore: ScanIdentityStore
    private let pairingService: PairingService
    private let scanIdentity: ScanIdentityMaterial
    private let transport = QuicTransportClient()

    private var pipeline: RoomCapturePipeline?

    init() {
        do {
            let trustStore = try TrustStore()
            self.trustStore = trustStore
            self.pairingService = PairingService(trustStore: trustStore)
            let identityStore = try ScanIdentityStore()
            self.scanIdentityStore = identityStore
            self.scanIdentity = identityStore.material()
        } catch {
            fatalError("Unable to initialize scan app stores: \(error.localizedDescription)")
        }
    }

    func startDiscovery() async {
        discovery.start()
        while !Task.isCancelled {
            discoveredEndpoints = discovery.endpoints
            if selectedEndpoint == nil {
                selectedEndpoint = discoveredEndpoints.first
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    func stopDiscovery() {
        discovery.stop()
    }

    func pair() async {
        guard let endpoint = resolvedPairingEndpoint() else {
            status = "Select or enter a desktop pairing endpoint first"
            return
        }
        guard !pairingCode.isEmpty else {
            status = "Enter the short pairing code"
            return
        }
        guard !pairingNonce.isEmpty else {
            status = "Enter the pairing nonce shown by desktop"
            return
        }

        status = "Pairing..."

        do {
            let result = try await pairingService.confirmPairing(
                endpoint: endpoint,
                pairingNonce: pairingNonce,
                pairingCode: pairingCode,
                scanDeviceId: scanIdentity.deviceId,
                scanDisplayName: UIDevice.current.name,
                scanCertFingerprintSha256: scanIdentity.certFingerprintSha256,
                desktopCertFingerprintSha256: endpoint.pairingCertFingerprintSha256 ?? "")

            if let scanClientMtls = result.scan_client_mtls,
               let pkcs12Data = Data(base64Encoded: scanClientMtls.pkcs12_b64)
            {
                try scanIdentityStore.persistClientTlsIdentity(
                    pkcs12Data: pkcs12Data,
                    password: scanClientMtls.password,
                    certFingerprintSha256: scanClientMtls.cert_fingerprint_sha256)
            } else if result.scan_client_mtls != nil {
                throw PairingError.serverRejected
            }

            status = "Paired with \(result.trust_record.peer_display_name)"
        } catch {
            status = "Pairing failed: \(error.localizedDescription)"
        }
    }

    func applyPairingQrPayload(_ rawPayload: String) {
        let trimmed = rawPayload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            status = "QR payload is empty"
            return
        }

        guard let data = trimmed.data(using: .utf8) else {
            status = "QR payload is not UTF-8"
            return
        }

        do {
            let payload = try JSONDecoder().decode(PairingQrPayload.self, from: data)
            guard let pairingUrl = URL(string: payload.pairing_endpoint) else {
                status = "QR payload pairing endpoint is invalid"
                return
            }
            guard let pairingHost = pairingUrl.host,
                  !pairingHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                status = "QR payload pairing endpoint is missing a host"
                return
            }
            guard pairingUrl.scheme?.lowercased() == "https" else {
                status = "QR payload pairing endpoint must use https"
                return
            }
            guard isSupportedWireVersion(payload.protocol_version) else {
                status = "QR payload protocol version is unsupported"
                return
            }
            guard !isExpired(payload.expires_at_utc) else {
                status = "QR payload has expired. Start a new pairing session."
                return
            }
            guard isValidSha256Hex(payload.desktop_cert_fingerprint_sha256) else {
                status = "QR payload desktop certificate fingerprint is invalid"
                return
            }
            guard isValidSignaturePayload(payload.signature_b64) else {
                status = "QR payload signature is missing or invalid"
                return
            }
            guard let quicHostPort = parseHostAndPort(payload.quic_endpoint) else {
                status = "QR payload QUIC endpoint is invalid"
                return
            }
            guard isValidPort(quicHostPort.port) else {
                status = "QR payload QUIC endpoint port is invalid"
                return
            }

            manualHost = pairingHost
            manualPort = String(pairingUrl.port ?? 7448)
            manualPairingFingerprintSha256 = payload.desktop_cert_fingerprint_sha256.lowercased()
            pairingCode = payload.pairing_code
            pairingNonce = payload.pairing_nonce

            manualHost = quicHostPort.host
            manualQuicPort = String(quicHostPort.port)

            selectedEndpoint = nil
            status = "QR payload imported"
        } catch {
            status = "QR payload parse failed: \(error.localizedDescription)"
        }
    }

    func onQrScanResult(_ payload: String) {
        pairingQrPayloadJson = payload
        applyPairingQrPayload(payload)
        isQrScannerPresented = false
    }

    func startCapture() async {
        guard !isCapturing else { return }

        let sessionId = ULID.generate()
        var activeTransport: QuicTransportClient?
        var sessionMetadata: [String: String] = [:]
        let recorder: SessionRecorder
        do {
            recorder = try SessionRecorder(
                sessionId: sessionId,
                sourceDeviceId: scanIdentity.deviceId,
                producerVersion: "0.1.0")
        } catch {
            status = "Recorder init failed: \(error.localizedDescription)"
            return
        }

        if let endpoint = resolvedStreamingEndpoint(),
           let trustedPeer = await trustedPeer(for: endpoint)
        {
            sessionMetadata[RoomMetadataKeys.pairedPeerDeviceId] = trustedPeer.peer_device_id
            sessionMetadata[RoomMetadataKeys.pairedPeerCertFingerprintSha256] = trustedPeer.peer_cert_fingerprint_sha256

            if let scanClientMtlsIdentity = scanIdentityStore.clientTlsIdentity() {
                do {
                    try await transport.connect(
                        host: endpoint.host,
                        port: endpoint.port,
                        pinnedFingerprintSha256: trustedPeer.peer_cert_fingerprint_sha256,
                        sessionId: sessionId,
                        scanIdentity: scanIdentity,
                        scanClientMtlsIdentity: scanClientMtlsIdentity)
                    status = "Secure QUIC connected"
                    activeTransport = transport
                } catch {
                    status = "QUIC connect failed, retrying while recording locally: \(error.localizedDescription)"
                    await transport.disconnect()
                }
            } else {
                status = "Missing scanner mTLS identity. Re-run pairing, recording locally for now."
                await transport.disconnect()
            }
        } else {
            status = "No trusted desktop selected, recording locally only"
            await transport.disconnect()
        }

        let capturePipeline = RoomCapturePipeline(
            sessionId: sessionId,
            sourceDeviceId: scanIdentity.deviceId,
            sessionMetadata: sessionMetadata,
            recorder: recorder,
            transport: activeTransport)
        self.pipeline = capturePipeline

        await transport.setBackpressureHandler { [weak self] hint in
            guard let self else { return }
            await self.applyBackpressureHint(hint)
        }

        do {
            try capturePipeline.start()
            isCapturing = true
            status = "Capturing"

            Task { [weak self] in
                while let self, self.isCapturing {
                    if let pipeline = self.pipeline {
                        self.metrics = pipeline.metrics
                    }
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        } catch {
            status = "Capture start failed: \(error.localizedDescription)"
            await transport.disconnect()
            self.pipeline = nil
        }
    }

    func stopCapture() async {
        guard isCapturing, let pipeline else { return }

        do {
            let directory = try await pipeline.stop()
            lastSessionDirectory = directory
            status = "Capture saved: \(directory.lastPathComponent)"
        } catch {
            status = "Capture finalize failed: \(error.localizedDescription)"
        }

        await transport.disconnect()
        self.pipeline = nil
        isCapturing = false
    }

    func exportLastSession() {
        guard let source = lastSessionDirectory else {
            status = "No session available to export"
            return
        }

        do {
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            let exportRoot = documents.appendingPathComponent("RoomCaptureExports", isDirectory: true)
            try FileManager.default.createDirectory(at: exportRoot, withIntermediateDirectories: true)

            let destination = exportRoot.appendingPathComponent("\(source.lastPathComponent).roomcapture", isDirectory: true)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }

            try FileManager.default.copyItem(at: source, to: destination)
            lastExportPath = destination
            status = "Exported session to \(destination.lastPathComponent)"
        } catch {
            status = "Export failed: \(error.localizedDescription)"
        }
    }

    private func resolvedPairingEndpoint() -> PairingEndpoint? {
        if let selectedEndpoint {
            return selectedEndpoint
        }

        guard !manualHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        let port = Int(manualPort) ?? 7448
        let fingerprint = manualPairingFingerprintSha256
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return PairingEndpoint(
            host: manualHost.trimmingCharacters(in: .whitespacesAndNewlines),
            port: port,
            quicPort: Int(manualQuicPort) ?? 7447,
            pairingScheme: "https",
            pairingCertFingerprintSha256: fingerprint.isEmpty ? nil : fingerprint,
            displayName: "Manual endpoint",
            desktopDeviceId: "manual-endpoint")
    }

    private func resolvedStreamingEndpoint() -> PairingEndpoint? {
        if let selectedEndpoint {
            return PairingEndpoint(
                host: selectedEndpoint.host,
                port: selectedEndpoint.quicPort,
                quicPort: selectedEndpoint.quicPort,
                pairingScheme: selectedEndpoint.pairingScheme,
                pairingCertFingerprintSha256: selectedEndpoint.pairingCertFingerprintSha256,
                displayName: selectedEndpoint.displayName,
                desktopDeviceId: selectedEndpoint.desktopDeviceId)
        }

        guard !manualHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        let manualFingerprint = manualPairingFingerprintSha256
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let quicPort = Int(manualQuicPort) ?? 7447
        return PairingEndpoint(
            host: manualHost.trimmingCharacters(in: .whitespacesAndNewlines),
            port: quicPort,
            quicPort: quicPort,
            pairingScheme: "https",
            pairingCertFingerprintSha256: manualFingerprint.isEmpty ? nil : manualFingerprint,
            displayName: "Manual endpoint",
            desktopDeviceId: "manual-endpoint")
    }

    private func trustedPeer(for endpoint: PairingEndpoint) async -> TrustRecord? {
        if let trusted = await trustStore.trustedPeer(deviceId: endpoint.desktopDeviceId) {
            return trusted
        }

        guard endpoint.desktopDeviceId == "manual-endpoint",
              let fingerprint = endpoint.pairingCertFingerprintSha256?.lowercased(),
              !fingerprint.isEmpty
        else {
            return nil
        }

        let trustedByFingerprint = await trustStore.all().first {
            $0.peer_cert_fingerprint_sha256.caseInsensitiveCompare(fingerprint) == .orderedSame &&
                $0.status.caseInsensitiveCompare("trusted") == .orderedSame
        }

        return trustedByFingerprint
    }

    private func applyBackpressureHint(_ hint: BackpressureHint) {
        pipeline?.applyBackpressureHint(hint)
    }

    private func parseHostAndPort(_ value: String) -> (host: String, port: Int)? {
        if let asUrl = URL(string: value),
           let host = asUrl.host {
            return (host, asUrl.port ?? 7447)
        }

        let parts = value.split(separator: ":", omittingEmptySubsequences: true)
        guard parts.count == 2, let port = Int(parts[1]) else {
            return nil
        }

        return (String(parts[0]), port)
    }

    private func isValidPort(_ port: Int) -> Bool {
        (1...65535).contains(port)
    }

    private func isExpired(_ expiresAtUtc: String) -> Bool {
        guard let expiresAt = parseIso8601Utc(expiresAtUtc) else {
            return true
        }

        return expiresAt <= Date()
    }

    private func isSupportedWireVersion(_ version: String) -> Bool {
        guard let major = version.split(separator: ".", maxSplits: 1).first,
              major == "1"
        else {
            return false
        }

        return true
    }

    private func isValidSha256Hex(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == 64 else {
            return false
        }

        return trimmed.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 48...57, 65...70, 97...102:
                return true
            default:
                return false
            }
        }
    }

    private func parseIso8601Utc(_ value: String) -> Date? {
        let internet = ISO8601DateFormatter()
        internet.formatOptions = [.withInternetDateTime]
        if let parsed = internet.date(from: value) {
            return parsed
        }

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value)
    }

    private func isValidSignaturePayload(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let decoded = Data(base64Encoded: trimmed)
        else {
            return false
        }

        return decoded.count == 32
    }
}
