import Foundation
import ProvinodeRoomContracts
import UIKit

@MainActor
final class CaptureViewModel: ObservableObject {
    @Published var discoveredEndpoints: [PairingEndpoint] = []
    @Published var selectedEndpoint: PairingEndpoint?
    @Published var manualHost: String = ""
    @Published var manualPort: String = "7448"
    @Published var manualQuicHost: String = ""
    @Published var manualQuicPort: String = "7447"
    @Published var manualPairingFingerprintSha256: String = ""
    @Published var pairingCode: String = ""
    @Published var pairingNonce: String = ""
    @Published var pairingQrPayloadJson: String = ""
    @Published var isQrScannerPresented = false
    @Published var isCalibrationPatternPresented = false
    @Published var status: String = "Idle"
    @Published var isCapturing = false
    @Published var captureState: ScanCaptureState = .unpaired
    @Published var captureHealth = CaptureHealthSnapshot.empty
    @Published var captureCoaching: String = "Pair with a desktop to begin."
    @Published var safeToStop = false
    @Published var metrics = ScanSessionMetrics()
    @Published var lastSessionDirectory: URL?
    @Published var lastExportPath: URL?
    @Published var activeSessionId: String = ""
    @Published var recordedSessions: [RecordedSessionSummary] = []
    @Published var trustedPeers: [TrustRecord] = []
    @Published var selectedRecordedSessionId: String = ""
    @Published var selectedTrustDeviceId: String = ""
    @Published var sessionLibraryFilter: String = ""
    @Published var trustFilter: String = ""

    var filteredRecordedSessions: [RecordedSessionSummary] {
        let filter = sessionLibraryFilter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !filter.isEmpty else { return recordedSessions }
        return recordedSessions.filter { session in
            session.sessionId.lowercased().contains(filter) ||
            session.sourceDeviceId.lowercased().contains(filter) ||
            session.integrityStatus.lowercased().contains(filter)
        }
    }

    var selectedRecordedSessionSummary: RecordedSessionSummary? {
        let selectedId = selectedRecordedSessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        return recordedSessions.first(where: { $0.sessionId == selectedId }) ?? filteredRecordedSessions.first
    }

    var filteredTrustedPeers: [TrustRecord] {
        let filter = trustFilter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !filter.isEmpty else { return trustedPeers }
        return trustedPeers.filter { peer in
            peer.peer_device_id.lowercased().contains(filter) ||
            peer.peer_display_name.lowercased().contains(filter) ||
            peer.status.lowercased().contains(filter)
        }
    }

    var selectedTrustRecord: TrustRecord? {
        let selectedId = selectedTrustDeviceId.trimmingCharacters(in: .whitespacesAndNewlines)
        return trustedPeers.first(where: { $0.peer_device_id == selectedId }) ?? filteredTrustedPeers.first
    }

    var exportRootPath: URL {
        RecordedSessionLibrary.exportDirectory()
    }

    private let discovery = LanDiscoveryService()
    private let trustStore: TrustStore
    private let scanIdentityStore: ScanIdentityStore
    private let pairingService: PairingService
    private let qrVerifier: PairingQrVerifying
    private let scanIdentity: ScanIdentityMaterial
    private let transport = QuicTransportClient()
    private let simulatorAutoPairEnabled: Bool
    private let simulatorAutoCaptureDurationSeconds: Double?
    private let simulatorAutoExportEnabled: Bool
    private let simulatorSessionIdOverride: String?
    private let simulatorDisableEngineSecureChannel: Bool

    private var pipeline: RoomCapturePipeline?
    private var simulatorAutomationStarted = false
    private var isStreamingConnected = false
    private var bootstrapImportTask: Task<Void, Never>?

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        qrVerifier: PairingQrVerifying = PairingQrVerificationService())
    {
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
        self.qrVerifier = qrVerifier

        #if targetEnvironment(simulator)
        simulatorAutoPairEnabled = Self.isTruthy(environment["PROVINODE_SCAN_AUTOPAIR"])
        simulatorAutoExportEnabled = Self.isTruthy(environment["PROVINODE_SCAN_AUTO_EXPORT"])
        if let rawSeconds = environment["PROVINODE_SCAN_AUTO_CAPTURE_SECONDS"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           let seconds = Double(rawSeconds),
           seconds > 0
        {
            simulatorAutoCaptureDurationSeconds = seconds
        } else {
            simulatorAutoCaptureDurationSeconds = nil
        }

        if let rawSessionId = environment["PROVINODE_SCAN_SESSION_ID"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !rawSessionId.isEmpty
        {
            simulatorSessionIdOverride = rawSessionId
        } else {
            simulatorSessionIdOverride = nil
        }
        simulatorDisableEngineSecureChannel = Self.isTruthy(environment["PROVINODE_SCAN_DISABLE_ENGINE_SECURE_CHANNEL"])
        #else
        simulatorAutoPairEnabled = false
        simulatorAutoExportEnabled = false
        simulatorAutoCaptureDurationSeconds = nil
        simulatorSessionIdOverride = nil
        simulatorDisableEngineSecureChannel = false
        #endif

        applySimulatorBootstrapIfPresent(environment: environment)
        triggerSimulatorAutomationIfNeeded()
        Task { [weak self] in
            await self?.refreshSessionLibrary()
            await self?.refreshTrustRecords()
            self?.updateCaptureDerivedState()
        }
    }

    func startDiscovery() async {
        discovery.start()
        while !Task.isCancelled {
            discoveredEndpoints = discovery.endpoints
            if selectedEndpoint == nil {
                selectedEndpoint = discoveredEndpoints.first
            }

            triggerSimulatorAutomationIfNeeded()

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
            await refreshTrustRecords()
            updateCaptureDerivedState()
        } catch {
            status = "Pairing failed: \(error.localizedDescription)"
            updateCaptureDerivedState()
        }
    }

    func applyPairingQrPayload(_ rawPayload: String) async {
        do {
            let verified = try await qrVerifier.verify(rawPayload: rawPayload)
            manualHost = verified.pairingHost
            manualPort = String(verified.pairingPort)
            manualPairingFingerprintSha256 = verified.payload.desktop_cert_fingerprint_sha256.lowercased()
            pairingCode = verified.payload.pairing_code
            pairingNonce = verified.payload.pairing_nonce
            manualQuicHost = verified.quicHost
            manualQuicPort = String(verified.quicPort)

            selectedEndpoint = nil
            status = "QR payload verified"
        } catch let error as PairingQrVerificationError {
            status = error.localizedDescription
        } catch {
            status = "QR payload parse failed: \(error.localizedDescription)"
        }
    }

    func onQrScanResult(_ payload: String) {
        pairingQrPayloadJson = payload
        Task { [weak self] in
            await self?.applyPairingQrPayload(payload)
        }
        isQrScannerPresented = false
    }

    func waitForInitialImports() async {
        await bootstrapImportTask?.value
    }

    func startCapture() async {
        guard !isCapturing else { return }

        let sessionId = simulatorSessionIdOverride ?? ULID.generate()
        activeSessionId = sessionId
        var activeTransport: QuicTransportClient?
        var sessionMetadata: [String: String] = [:]
        sessionMetadata[RoomMetadataKeys.roomSchemaVersion] = RoomContractVersions.roomCaptureSessionManifest
        sessionMetadata[RoomMetadataKeys.captureStartedAtUtc] = Self.captureTimestampFormatter.string(from: .now)
        sessionMetadata["room.capture_pose_space"] = "PhoneARWorld"
        sessionMetadata["room.capture_intrinsics_space"] = "DesktopCameraSpace"
        sessionMetadata["room.capture_transform_representation"] = "world_from_camera"
        sessionMetadata["room.capture_camera_convention"] = "camera+x-right+y-down+z-forward"
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
                        scanClientMtlsIdentity: scanClientMtlsIdentity,
                        requireEngineSecureChannel: !simulatorDisableEngineSecureChannel)
                    status = "Secure QUIC connected"
                    activeTransport = transport
                    isStreamingConnected = true
                } catch {
                    status = "QUIC connect failed, retrying while recording locally: \(error.localizedDescription)"
                    await transport.disconnect()
                    isStreamingConnected = false
                }
            } else {
                status = "Missing scanner mTLS identity. Re-run pairing, recording locally for now."
                await transport.disconnect()
                isStreamingConnected = false
            }
        } else {
            status = "No trusted desktop selected, recording locally only"
            await transport.disconnect()
            isStreamingConnected = false
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
            updateCaptureDerivedState()

            Task { [weak self] in
                while let self, self.isCapturing {
                    if let pipeline = self.pipeline {
                        self.metrics = pipeline.metrics
                        self.refreshCaptureHealth()
                    }
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        } catch {
            status = "Capture start failed: \(error.localizedDescription)"
            await transport.disconnect()
            self.pipeline = nil
            isStreamingConnected = false
            updateCaptureDerivedState()
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
        isStreamingConnected = false
        await refreshSessionLibrary()
        refreshCaptureHealth()
        updateCaptureDerivedState()
    }

    func exportLastSession() {
        guard let sessionId = lastSessionDirectory?.lastPathComponent ?? recordedSessions.first(where: { $0.sessionId == selectedRecordedSessionId })?.sessionId else {
            status = "No session available to export"
            return
        }

        exportSession(sessionId: sessionId)
    }

    func exportSession(sessionId: String) {
        guard let source = recordedSessions.first(where: { $0.sessionId == sessionId })?.sessionDirectory ?? lastSessionDirectory else {
            status = "Session not found for export"
            updateCaptureDerivedState()
            return
        }

        do {
            let exportRoot = RecordedSessionLibrary.exportDirectory()
            try FileManager.default.createDirectory(at: exportRoot, withIntermediateDirectories: true)

            let destination = exportRoot.appendingPathComponent("\(source.lastPathComponent).roomcapture", isDirectory: true)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }

            try FileManager.default.copyItem(at: source, to: destination)
            lastExportPath = destination
            status = "Exported session to \(destination.lastPathComponent)"
            Task { [weak self] in
                await self?.refreshSessionLibrary()
                self?.updateCaptureDerivedState()
            }
        } catch {
            status = "Export failed: \(error.localizedDescription)"
            updateCaptureDerivedState()
        }
    }

    func exportAllSessions() {
        for session in filteredRecordedSessions {
            exportSession(sessionId: session.sessionId)
        }
    }

    func refreshSessionLibrary() async {
        do {
            recordedSessions = try RecordedSessionLibrary.list()
            if !recordedSessions.contains(where: { $0.sessionId == selectedRecordedSessionId }) {
                selectedRecordedSessionId = recordedSessions.first?.sessionId ?? ""
            }
        } catch {
            status = "Session library refresh failed: \(error.localizedDescription)"
        }
        updateCaptureDerivedState()
    }

    func refreshTrustRecords() async {
        trustedPeers = await trustStore.all()
        if !trustedPeers.contains(where: { $0.peer_device_id == selectedTrustDeviceId }) {
            selectedTrustDeviceId = trustedPeers.first?.peer_device_id ?? ""
        }
        updateCaptureDerivedState()
    }

    func revokeTrustedDesktop() async {
        let deviceId = selectedTrustDeviceId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !deviceId.isEmpty else {
            status = "Select a trusted desktop to revoke"
            updateCaptureDerivedState()
            return
        }

        do {
            try await trustStore.remove(deviceId: deviceId)
            status = "Revoked trust for \(deviceId)"
            await refreshTrustRecords()
        } catch {
            status = "Trust revoke failed: \(error.localizedDescription)"
            updateCaptureDerivedState()
        }
    }

    func resetTrustedDesktops() async {
        do {
            try await trustStore.reset()
            status = "Reset trusted desktop list"
            await refreshTrustRecords()
        } catch {
            status = "Trust reset failed: \(error.localizedDescription)"
            updateCaptureDerivedState()
        }
    }

    func recomputeCaptureHealthForTesting() {
        refreshCaptureHealth()
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
        let streamingHost = manualQuicHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? manualHost.trimmingCharacters(in: .whitespacesAndNewlines)
            : manualQuicHost.trimmingCharacters(in: .whitespacesAndNewlines)
        return PairingEndpoint(
            host: streamingHost,
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

    private func refreshCaptureHealth() {
        let unmet = unmetCriteria()
        safeToStop = unmet.isEmpty
        captureHealth = CaptureHealthSnapshot(
            session_id: activeSessionId.isEmpty ? (lastSessionDirectory?.lastPathComponent ?? "") : activeSessionId,
            capture_state: captureState.rawValue,
            safe_to_stop: safeToStop,
            sample_count: metrics.emittedSamples,
            dropped_sample_count: metrics.droppedSamples,
            keyframe_count: metrics.keyframeCount,
            depth_frame_count: metrics.depthCount,
            mesh_batch_count: metrics.meshCount,
            avg_keyframe_fps: metrics.avgKeyframeFps,
            pose_confidence: metrics.poseConfidence,
            duration_seconds: metrics.captureDurationSeconds,
            unmet_criteria: unmet)

        if safeToStop {
            let qualityScore = Int(metrics.twinQualityScore.rounded())
            let matchScore = Int(metrics.twinMatchReadinessScore.rounded())
            captureCoaching = "Safe to stop. Virtual twin quality looks stable (\(qualityScore)/100), camera-match readiness \(matchScore)/100."
        } else if unmet.isEmpty {
            captureCoaching = "Capture not started."
        } else {
            captureCoaching = coachingMessage(for: unmet)
        }
        updateCaptureDerivedState()
    }

    private func unmetCriteria() -> [String] {
        guard isCapturing || metrics.emittedSamples > 0 else {
            return ["capture_not_started"]
        }

        var unmet: [String] = []
        if metrics.keyframeCount < 24 {
            unmet.append("keyframes")
        }
        if !(metrics.depthCount >= 60 || metrics.meshCount >= 12) {
            unmet.append("depth_or_mesh")
        }
        if metrics.captureDurationSeconds < 20 {
            unmet.append("duration_seconds")
        }
        if metrics.poseConfidence < 0.60 {
            unmet.append("pose_confidence")
        }
        if metrics.keyframeCount >= 16 && metrics.depthPerKeyframe < 2.4 {
            unmet.append("depth_density")
        }
        if metrics.keyframeCount >= 16 && metrics.meshPerKeyframe < 0.22 {
            unmet.append("mesh_coverage")
        }
        if metrics.captureDurationSeconds >= 12 && metrics.poseConfidence < 0.72 {
            unmet.append("pose_stability")
        }
        if metrics.captureDurationSeconds >= 16 && metrics.structuralCoverageScore < 0.62 {
            unmet.append("fixture_span")
        }
        if metrics.captureDurationSeconds >= 18 && metrics.perimeterCoverageScore < 0.60 {
            unmet.append("perimeter_pass")
        }
        if metrics.keyframeCount >= 20 && metrics.twinMatchReadinessScore < 68 {
            unmet.append("viewport_match_readiness")
        }
        return unmet
    }

    private func coachingMessage(for unmet: [String]) -> String {
        var guidance: [String] = []
        if unmet.contains("keyframes") {
            guidance.append("collect more keyframes")
        }
        if unmet.contains("depth_or_mesh") || unmet.contains("depth_density") {
            guidance.append("slow down and revisit visible surfaces for denser depth")
        }
        if unmet.contains("mesh_coverage") {
            guidance.append("trace wall-floor corners and large furniture edges to strengthen the mesh")
        }
        if unmet.contains("fixture_span") {
            guidance.append("include ceiling lines, floor edges, and the opposite wall to lock permanent fixtures")
        }
        if unmet.contains("perimeter_pass") {
            guidance.append("walk the room perimeter and pause at the far corners before stopping")
        }
        if unmet.contains("viewport_match_readiness") {
            guidance.append("favor long wall edges and fixed furniture so later camera matching has stable landmarks")
        }
        if unmet.contains("duration_seconds") {
            guidance.append("keep scanning longer to cover the room perimeter")
        }
        if unmet.contains("pose_confidence") || unmet.contains("pose_stability") {
            guidance.append("steady the phone and include textured edges for more stable tracking")
        }

        let distinctGuidance = Array(NSOrderedSet(array: guidance)) as? [String] ?? guidance
        if distinctGuidance.isEmpty {
            return "Waiting on: \(unmet.joined(separator: ", "))"
        }

        let qualityScore = Int(metrics.twinQualityScore.rounded())
        let matchScore = Int(metrics.twinMatchReadinessScore.rounded())
        return "Waiting on: \(unmet.joined(separator: ", ")). Next best actions: \(distinctGuidance.joined(separator: "; ")). Twin quality \(qualityScore)/100. Camera-match readiness \(matchScore)/100."
    }

    private func updateCaptureDerivedState() {
        if status.localizedCaseInsensitiveContains("failed") || status.localizedCaseInsensitiveContains("error") {
            captureState = .error
            return
        }

        if isCapturing {
            captureState = isStreamingConnected ? .streaming : .recording
            return
        }

        if lastExportPath != nil {
            captureState = .exported
            return
        }

        let hasTrust = !trustedPeers.isEmpty
        let hasEndpoint = selectedEndpoint != nil || !manualHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if hasTrust && hasEndpoint {
            captureState = .ready
        } else if hasTrust {
            captureState = .paired
        } else {
            captureState = .unpaired
        }
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

    private func runSimulatorAutomationFlow() async {
        #if targetEnvironment(simulator)
        guard simulatorAutoPairEnabled else { return }

        var backgroundTaskId: UIBackgroundTaskIdentifier = .invalid
        backgroundTaskId = UIApplication.shared.beginBackgroundTask(withName: "ProvinodeScanSimulatorAutomation")
        defer {
            if backgroundTaskId != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTaskId)
            }
        }

        await pair()
        guard let captureSeconds = simulatorAutoCaptureDurationSeconds, captureSeconds > 0 else {
            return
        }

        await startCapture()
        guard isCapturing else { return }

        let delayNs = UInt64(max(1, captureSeconds) * 1_000_000_000)
        try? await Task.sleep(nanoseconds: delayNs)

        if isCapturing {
            await stopCapture()
            if simulatorAutoExportEnabled {
                exportLastSession()
            }
        }
        #endif
    }

    private func triggerSimulatorAutomationIfNeeded() {
        #if targetEnvironment(simulator)
        guard simulatorAutoPairEnabled, !simulatorAutomationStarted else { return }
        simulatorAutomationStarted = true
        Task { [weak self] in
            await self?.runSimulatorAutomationFlow()
        }
        #endif
    }

    private func applySimulatorBootstrapIfPresent(environment: [String: String]) {
        #if targetEnvironment(simulator)
        if let payloadPath = environment["PROVINODE_SCAN_QR_PAYLOAD_PATH"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !payloadPath.isEmpty
        {
            do {
                let payload = try String(contentsOfFile: payloadPath, encoding: .utf8)
                pairingQrPayloadJson = payload
                bootstrapImportTask = Task { [weak self] in
                    await self?.applyPairingQrPayload(payload)
                }
                return
            } catch {
                status = "Simulator QR payload file failed to load: \(error.localizedDescription)"
            }
        }

        if let payloadJson = environment["PROVINODE_SCAN_QR_PAYLOAD_JSON"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !payloadJson.isEmpty
        {
            pairingQrPayloadJson = payloadJson
            bootstrapImportTask = Task { [weak self] in
                await self?.applyPairingQrPayload(payloadJson)
            }
        }
        #endif
    }

    private static func isTruthy(_ value: String?) -> Bool {
        guard let trimmed = value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
            !trimmed.isEmpty
        else {
            return false
        }

        switch trimmed {
        case "1", "true", "yes", "on":
            return true
        default:
            return false
        }
    }

    private static let captureTimestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

private extension CaptureHealthSnapshot {
    static var empty: CaptureHealthSnapshot {
        CaptureHealthSnapshot(
            session_id: "",
            capture_state: ScanCaptureState.unpaired.rawValue,
            safe_to_stop: false,
            sample_count: 0,
            dropped_sample_count: 0,
            keyframe_count: 0,
            depth_frame_count: 0,
            mesh_batch_count: 0,
            avg_keyframe_fps: 0,
            pose_confidence: 0,
            duration_seconds: 0,
            unmet_criteria: ["capture_not_started"])
    }
}
