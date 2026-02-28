import Foundation
import ProvinodeRoomContracts
import UIKit

@MainActor
final class CaptureViewModel: ObservableObject {
    @Published var discoveredEndpoints: [PairingEndpoint] = []
    @Published var selectedEndpoint: PairingEndpoint?
    @Published var manualHost: String = ""
    @Published var manualPort: String = "7448"
    @Published var pairingCode: String = ""
    @Published var pairingNonce: String = ""
    @Published var status: String = "Idle"
    @Published var isCapturing = false
    @Published var metrics = ScanSessionMetrics()
    @Published var lastSessionDirectory: URL?
    @Published var lastExportPath: URL?

    private let discovery = LanDiscoveryService()
    private let trustStore: TrustStore
    private let pairingService: PairingService
    private let transport = QuicTransportClient()
    private let deviceId = ULID.generate()

    private var pipeline: RoomCapturePipeline?

    init() {
        do {
            let trustStore = try TrustStore()
            self.trustStore = trustStore
            self.pairingService = PairingService(trustStore: trustStore)
        } catch {
            fatalError("Unable to initialize trust store: \(error.localizedDescription)")
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
            let trust = try await pairingService.confirmPairing(
                endpoint: endpoint,
                pairingNonce: pairingNonce,
                pairingCode: pairingCode,
                scanDeviceId: deviceId,
                scanDisplayName: UIDevice.current.name,
                scanCertFingerprintSha256: Sha256.hex(of: deviceId),
                desktopCertFingerprintSha256: Sha256.hex(of: endpoint.desktopDeviceId))
            status = "Paired with \(trust.peer_display_name)"
        } catch {
            status = "Pairing failed: \(error.localizedDescription)"
        }
    }

    func startCapture() async {
        guard !isCapturing else { return }

        let sessionId = ULID.generate()
        let recorder: SessionRecorder
        do {
            recorder = try SessionRecorder(
                sessionId: sessionId,
                sourceDeviceId: deviceId,
                producerVersion: "0.1.0")
        } catch {
            status = "Recorder init failed: \(error.localizedDescription)"
            return
        }

        if let endpoint = resolvedStreamingEndpoint(),
           let trustedPeer = await trustStore.trustedPeer(deviceId: endpoint.desktopDeviceId)
        {
            do {
                try await transport.connect(
                    host: endpoint.host,
                    port: endpoint.port,
                    pinnedFingerprintSha256: trustedPeer.peer_cert_fingerprint_sha256,
                    sessionId: sessionId)
                status = "Secure QUIC connected"
            } catch {
                status = "QUIC connect failed: \(error.localizedDescription)"
            }
        } else {
            status = "No trusted desktop selected, recording locally only"
        }

        let pipeline = RoomCapturePipeline(
            sessionId: sessionId,
            sourceDeviceId: deviceId,
            recorder: recorder,
            transport: resolvedStreamingEndpoint() == nil ? nil : transport)

        do {
            try pipeline.start()
            self.pipeline = pipeline
            isCapturing = true
            status = "Capturing"

            Task { [weak self] in
                while let self, self.isCapturing {
                    self.metrics = pipeline.metrics
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        } catch {
            status = "Capture start failed: \(error.localizedDescription)"
            await transport.disconnect()
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
        return PairingEndpoint(
            host: manualHost.trimmingCharacters(in: .whitespacesAndNewlines),
            port: port,
            displayName: "Manual endpoint",
            desktopDeviceId: "manual-endpoint")
    }

    private func resolvedStreamingEndpoint() -> PairingEndpoint? {
        if let selectedEndpoint {
            return PairingEndpoint(
                host: selectedEndpoint.host,
                port: 7447,
                displayName: selectedEndpoint.displayName,
                desktopDeviceId: selectedEndpoint.desktopDeviceId)
        }

        guard !manualHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        return PairingEndpoint(
            host: manualHost.trimmingCharacters(in: .whitespacesAndNewlines),
            port: 7447,
            displayName: "Manual endpoint",
            desktopDeviceId: "manual-endpoint")
    }
}
