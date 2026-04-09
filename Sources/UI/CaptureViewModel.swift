import Foundation
import LinnaeusEngineClientSdkApple
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
    private let pairingService: any PairingSessionClient
    private let scanIdentity: ScanIdentityMaterial
    private let transport = QuicTransportClient()
    private let simulatorAutoPairEnabled: Bool
    private let simulatorAutoCaptureDurationSeconds: Double?
    private let simulatorAutoExportEnabled: Bool
    private let simulatorSessionIdOverride: String?
    private let simulatorDisableEngineSecureChannel: Bool

    private var pipeline: RoomCapturePipeline?
    private var activeRemoteCaptureSession: ActiveRemoteCaptureSession?
    private var simulatorAutomationStarted = false

    private struct PreparedPairingSession {
        let status: PairingSessionStatusResponse
        let startedNewSession: Bool
    }

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        pairingService: (any PairingSessionClient)? = nil
    ) {
        do {
            let trustStore = try TrustStore()
            self.trustStore = trustStore
            self.pairingService = pairingService ?? PairingService(trustStore: trustStore)
            let identityStore = try ScanIdentityStore()
            self.scanIdentityStore = identityStore
            self.scanIdentity = identityStore.material()
        } catch {
            fatalError("Unable to initialize scan app stores: \(error.localizedDescription)")
        }

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

        status = "Pairing..."

        do {
            let preparedSession = try await preparePairingSession(endpoint: endpoint)
            guard !pairingCode.isEmpty, !pairingNonce.isEmpty else {
                status = preparedSession.startedNewSession
                    ? "Pairing session started. Import the current QR payload, then confirm pairing."
                    : "Pairing session is active. Import the current QR payload, then confirm pairing."
                return
            }

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
                throw PairingError.serverRejected(nil)
            }

            status = "Paired with \(result.trust_record.peer_display_name)"
        } catch {
            status = Self.describePairingFailure(error)
        }
    }

    func applyPairingQrPayload(_ rawPayload: String) {
        do {
            let result = try ClientSessionPreparation.importPairingQrPayload(rawPayload)
            manualHost = result.quicHost
            manualPort = String(result.pairingPort)
            manualQuicPort = String(result.quicPort)
            manualPairingFingerprintSha256 = result.pairingFingerprintSha256
            pairingCode = result.pairingCode
            pairingNonce = result.pairingNonce
            selectedEndpoint = nil
            status = "QR payload imported"
        } catch {
            status = error.localizedDescription
        }
    }

    func onQrScanResult(_ payload: String) {
        pairingQrPayloadJson = payload
        applyPairingQrPayload(payload)
        isQrScannerPresented = false
    }

    static func describePairingFailure(_ error: Error) -> String {
        guard let pairingError = error as? PairingError else {
            return "Pairing failed: \(error.localizedDescription)"
        }

        let description = pairingError.localizedDescription
        switch pairingError {
        case .authorityUnavailable:
            if pairingError.inFlight {
                return appendPairingDiagnosticReference(
                    to: "Pairing waiting on authority: \(description)",
                    pairingError: pairingError)
            }

            return appendPairingDiagnosticReference(
                to: "Pairing unavailable: \(description)",
                pairingError: pairingError)
        case .sessionUnavailable, .expired:
            return "Pairing session unavailable: \(description)"
        case .attemptLimitReached:
            return "Pairing attempts exhausted: \(description)"
        case .lockedOut:
            return "Pairing locked: \(description)"
        case .invalidCode:
            return "Pairing rejected: \(description)"
        case .serverRejected, .untrustedEndpoint:
            return appendPairingDiagnosticReference(
                to: "Pairing failed: \(description)",
                pairingError: pairingError)
        }
    }

    func startCapture() async {
        guard !isCapturing else { return }

        let sessionId = simulatorSessionIdOverride ?? ULID.generate()
        var activeTransport: QuicTransportClient?
        var remoteVideoStream: RemoteCaptureVideoStreamContext?
        let sessionTraceparent = ScanTraceContext.makeTraceparent()
        var sessionMetadata = Self.makeSessionMetadata(
            sessionId: sessionId,
            traceparent: sessionTraceparent)
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
            sessionMetadata = Self.makeSessionMetadata(
                sessionId: sessionId,
                traceparent: sessionTraceparent,
                trustedPeer: trustedPeer)

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

                    do {
                        let remoteCaptureSession = try await startRemoteCaptureVideoSession(
                            transport: transport,
                            sessionId: sessionId,
                            endpoint: endpoint,
                            trustedPeer: trustedPeer)
                        activeRemoteCaptureSession = remoteCaptureSession
                        remoteVideoStream = remoteCaptureSession.videoStream
                        status = "Remote capture video session ready"
                    } catch {
                        status = "Remote capture session failed, recording locally only: \(error.localizedDescription)"
                        activeRemoteCaptureSession = nil
                        remoteVideoStream = nil
                        activeTransport = nil
                        await transport.setControlPayloadHandler(nil)
                        await transport.setLifecycleEventHandler(nil)
                        await transport.disconnect()
                    }
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
            transport: activeTransport,
            remoteVideoStream: remoteVideoStream)
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
            if let activeRemoteCaptureSession {
                await stopRemoteCaptureVideoSession(activeRemoteCaptureSession)
            }
            await transport.setControlPayloadHandler(nil)
            await transport.setLifecycleEventHandler(nil)
            await transport.disconnect()
            activeRemoteCaptureSession = nil
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

        if let activeRemoteCaptureSession {
            await stopRemoteCaptureVideoSession(activeRemoteCaptureSession)
        }

        await transport.setControlPayloadHandler(nil)
        await transport.setLifecycleEventHandler(nil)
        await transport.disconnect()
        activeRemoteCaptureSession = nil
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
        ClientSessionPreparation.resolvePairingEndpoint(
            selectedEndpoint: selectedEndpoint,
            manualHost: manualHost,
            manualPort: manualPort,
            manualQuicPort: manualQuicPort,
            manualPairingFingerprintSha256: manualPairingFingerprintSha256)
    }

    private func preparePairingSession(endpoint: PairingEndpoint) async throws -> PreparedPairingSession {
        let activeStatus = try await pairingService.getActivePairingSession(endpoint: endpoint)
        if !ClientSessionPreparation.shouldStartPairingSession(for: activeStatus) {
            return PreparedPairingSession(status: activeStatus, startedNewSession: false)
        }

        let startedStatus = try await pairingService.startPairingSession(endpoint: endpoint)
        return PreparedPairingSession(status: startedStatus, startedNewSession: true)
    }

    private func resolvedStreamingEndpoint() -> PairingEndpoint? {
        ClientSessionPreparation.resolveStreamingEndpoint(
            selectedEndpoint: selectedEndpoint,
            manualHost: manualHost,
            manualQuicPort: manualQuicPort,
            manualPairingFingerprintSha256: manualPairingFingerprintSha256)
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
                applyPairingQrPayload(payload)
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
            applyPairingQrPayload(payloadJson)
        }
        #endif
    }

    static func makeSessionMetadata(
        sessionId: String,
        traceparent: String,
        trustedPeer: TrustRecord? = nil
    ) -> [String: String] {
        var metadata: [String: String] = [
            RoomMetadataKeys.roomSessionId: sessionId,
            RoomMetadataKeys.roomTraceparent: traceparent
        ]

        if let trustedPeer {
            metadata[RoomMetadataKeys.pairedPeerDeviceId] = trustedPeer.peer_device_id
            metadata[RoomMetadataKeys.pairedPeerCertFingerprintSha256] = trustedPeer.peer_cert_fingerprint_sha256
        }

        return metadata
    }

    private static func appendPairingDiagnosticReference(
        to base: String,
        pairingError: PairingError
    ) -> String {
        guard let diagnosticReference = pairingError.diagnosticReference,
              !diagnosticReference.isEmpty,
              !base.localizedCaseInsensitiveContains(diagnosticReference)
        else {
            return base
        }

        return "\(base) See \(diagnosticReference)."
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

    private func startRemoteCaptureVideoSession(
        transport: QuicTransportClient,
        sessionId: String,
        endpoint: PairingEndpoint,
        trustedPeer: TrustRecord
    ) async throws -> ActiveRemoteCaptureSession {
        let controlPlane = RemoteCaptureControlPlane()
        await transport.setControlPayloadHandler { payload in
            await controlPlane.handleInboundPayload(payload)
        }
        await transport.setLifecycleEventHandler { event in
            await controlPlane.handleTransportLifecycleEvent(event)
        }

        let advertisement = makeRemoteCaptureAdvertisement(
            sessionId: sessionId,
            endpoint: endpoint,
            trustedPeer: trustedPeer)
        let advertisementMessage = ClientRemoteCaptureControlCodec.makeAdvertisementMessage(
            advertisement,
            emittedAtUtc: Self.remoteCaptureTimestamp())
        try await transport.sendControl(advertisementMessage)

        let registration = try await awaitRemoteCaptureRegistration(controlPlane)
        let remoteCaptureNodeId = registration.remoteCaptureNodeId

        let openGeneration = await controlPlane.currentSessionControlGeneration()
        let openRequest = ClientRemoteCaptureSessionControl(
            clientDeviceId: scanIdentity.deviceId,
            remoteCaptureNodeId: remoteCaptureNodeId,
            sessionId: sessionId,
            action: .open,
            requestedAtUtc: Self.remoteCaptureTimestamp())
        let openMessage = ClientRemoteCaptureControlCodec.makeSessionControlMessage(
            openRequest,
            emittedAtUtc: Self.remoteCaptureTimestamp())
        try await transport.sendControl(openMessage)

        let opened = try await awaitRemoteCaptureSessionControlResult(
            controlPlane,
            afterGeneration: openGeneration)
        guard opened.accepted else {
            throw NSError(
                domain: "CaptureViewModel",
                code: 3101,
                userInfo: [NSLocalizedDescriptionKey: opened.reasonText ?? "Remote capture session open was rejected."])
        }

        let startGeneration = await controlPlane.currentSessionControlGeneration()
        let startRequest = ClientRemoteCaptureSessionControl(
            clientDeviceId: scanIdentity.deviceId,
            remoteCaptureNodeId: remoteCaptureNodeId,
            sessionId: sessionId,
            action: .start,
            streamIds: [Self.remoteVideoStreamId],
            requestedAtUtc: Self.remoteCaptureTimestamp())
        let startMessage = ClientRemoteCaptureControlCodec.makeSessionControlMessage(
            startRequest,
            emittedAtUtc: Self.remoteCaptureTimestamp())
        try await transport.sendControl(startMessage)

        let started = try await awaitRemoteCaptureSessionControlResult(
            controlPlane,
            afterGeneration: startGeneration)
        guard started.accepted else {
            throw NSError(
                domain: "CaptureViewModel",
                code: 3102,
                userInfo: [NSLocalizedDescriptionKey: started.reasonText ?? "Remote capture video start was rejected."])
        }

        let activeRegistration = started.registration ?? registration
        let activeStream = activeRegistration.streams.first(where: { $0.streamId == Self.remoteVideoStreamId })
        let videoStream = RemoteCaptureVideoStreamContext(
            remoteCaptureNodeId: activeRegistration.remoteCaptureNodeId,
            clientDeviceId: scanIdentity.deviceId,
            sessionId: sessionId,
            streamId: Self.remoteVideoStreamId,
            timebaseId: activeStream?.timebase.timebaseId ?? Self.remoteVideoTimebaseId,
            syncGroupId: activeStream?.syncGroupId ?? Self.remoteVideoSyncGroupId,
            packetTimingProjection: { localCaptureTicks in
                await controlPlane.packetTimingProjection(localCaptureTicks: localCaptureTicks)
            })

        return ActiveRemoteCaptureSession(
            controlPlane: controlPlane,
            videoStream: videoStream)
    }

    private func stopRemoteCaptureVideoSession(_ session: ActiveRemoteCaptureSession) async {
        do {
            let stopGeneration = await session.controlPlane.currentSessionControlGeneration()
            let stopRequest = ClientRemoteCaptureSessionControl(
                clientDeviceId: scanIdentity.deviceId,
                remoteCaptureNodeId: session.videoStream.remoteCaptureNodeId,
                sessionId: session.videoStream.sessionId,
                action: .stop,
                streamIds: [session.videoStream.streamId],
                requestedAtUtc: Self.remoteCaptureTimestamp())
            try await transport.sendControl(
                ClientRemoteCaptureControlCodec.makeSessionControlMessage(
                    stopRequest,
                    emittedAtUtc: Self.remoteCaptureTimestamp()))
            _ = try await awaitRemoteCaptureSessionControlResult(session.controlPlane, afterGeneration: stopGeneration, timeoutSeconds: 2)

            let closeGeneration = await session.controlPlane.currentSessionControlGeneration()
            let closeRequest = ClientRemoteCaptureSessionControl(
                clientDeviceId: scanIdentity.deviceId,
                remoteCaptureNodeId: session.videoStream.remoteCaptureNodeId,
                sessionId: session.videoStream.sessionId,
                action: .close,
                requestedAtUtc: Self.remoteCaptureTimestamp())
            try await transport.sendControl(
                ClientRemoteCaptureControlCodec.makeSessionControlMessage(
                    closeRequest,
                    emittedAtUtc: Self.remoteCaptureTimestamp()))
            _ = try await awaitRemoteCaptureSessionControlResult(session.controlPlane, afterGeneration: closeGeneration, timeoutSeconds: 2)
        } catch {
            StructuredLog.emit(
                event: "remote_capture_session_stop_failed",
                level: "error",
                fields: [
                    "session_id": session.videoStream.sessionId,
                    "stream_id": session.videoStream.streamId,
                    "error": error.localizedDescription
                ])
        }
    }

    private func makeRemoteCaptureAdvertisement(
        sessionId: String,
        endpoint: PairingEndpoint,
        trustedPeer: TrustRecord
    ) -> ClientRemoteCaptureNodeAdvertisement {
        let timebase = ClientRemoteCaptureTimebaseDescriptor(
            timebaseId: Self.remoteVideoTimebaseId,
            kind: .deviceMonotonic,
            unitsPerSecond: 1_000_000_000,
            monotonic: true,
            syncGroupId: Self.remoteVideoSyncGroupId)
        let videoFormat = ClientRemoteCaptureVideoFormatDescriptor(
            width: 1920,
            height: 1080,
            framesPerSecond: 30,
            pixelFormat: "420f",
            encoding: "jpeg",
            orientation: .unspecified,
            cameraPosition: .back,
            intrinsicsAvailable: true)
        let stream = ClientRemoteCaptureStreamDescriptor(
            streamId: Self.remoteVideoStreamId,
            capabilityId: ClientRemoteCaptureCapabilityIds.cameraVideo,
            displayName: "Rear Camera",
            mediaKind: .video,
            state: .advertised,
            health: ClientRemoteCaptureStreamHealthSummary(
                healthState: .healthy,
                available: true,
                selectedForStreaming: false),
            timebase: timebase,
            syncGroupId: Self.remoteVideoSyncGroupId,
            primary: true,
            video: videoFormat)

        return ClientRemoteCaptureNodeAdvertisement(
            clientDeviceId: scanIdentity.deviceId,
            displayName: UIDevice.current.name,
            device: ClientRemoteCaptureDeviceDescriptor(
                platformId: "ios",
                operatingSystem: UIDevice.current.systemName,
                operatingSystemVersion: UIDevice.current.systemVersion,
                appId: Bundle.main.bundleIdentifier ?? "provinode.scan",
                appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
                deviceModel: UIDevice.current.model,
                deviceName: UIDevice.current.name,
                deviceClass: "phone",
                manufacturer: "Apple"),
            transport: ClientRemoteCaptureTransportDescriptor(
                transportProtocolId: "transport.quic.secure_capture",
                transportSessionId: sessionId,
                secureChannelSessionId: sessionId,
                pairingPeerId: trustedPeer.peer_device_id,
                advertisedEndpointId: "\(endpoint.host):\(endpoint.port)"),
            state: .registered,
            health: ClientRemoteCaptureNodeHealthSummary(
                healthState: .healthy,
                readyForGraphMaterialization: true,
                advertisedStreamCount: 1,
                activeStreamCount: 0,
                degradedStreamCount: 0,
                unavailableStreamCount: 0),
            capabilities: [
                ClientRemoteCaptureCapabilityAdvertisement(
                    capabilityId: ClientRemoteCaptureCapabilityIds.cameraVideo,
                    availability: .available,
                    optional: false,
                    displayName: "Camera Video",
                    streamIds: [Self.remoteVideoStreamId],
                    video: videoFormat)
            ],
            streams: [stream],
            advertisedAtUtc: Self.remoteCaptureTimestamp())
    }

    private func awaitRemoteCaptureRegistration(
        _ controlPlane: RemoteCaptureControlPlane,
        timeoutSeconds: Double = 5
    ) async throws -> ClientRemoteCaptureNodeRegistration {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if let registration = await controlPlane.currentRegistration() {
                return registration
            }

            try await Task.sleep(for: .milliseconds(50))
        }

        throw NSError(
            domain: "CaptureViewModel",
            code: 3103,
            userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for remote capture node registration."])
    }

    private func awaitRemoteCaptureSessionControlResult(
        _ controlPlane: RemoteCaptureControlPlane,
        afterGeneration generation: Int,
        timeoutSeconds: Double = 5
    ) async throws -> ClientRemoteCaptureSessionControlResult {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            let currentGeneration = await controlPlane.currentSessionControlGeneration()
            if currentGeneration > generation,
               let result = await controlPlane.latestSessionControlResult() {
                return result
            }

            try await Task.sleep(for: .milliseconds(50))
        }

        throw NSError(
            domain: "CaptureViewModel",
            code: 3104,
            userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for remote capture session control result."])
    }

    private static var remoteVideoStreamId: String { "video-main" }
    private static var remoteVideoTimebaseId: String { "ios.monotonic.ns" }
    private static var remoteVideoSyncGroupId: String { "sync-video-main" }

    private static func remoteCaptureTimestamp() -> String {
        ISO8601DateFormatter.fractional.string(from: .now)
    }
}

private struct ActiveRemoteCaptureSession: Sendable {
    let controlPlane: RemoteCaptureControlPlane
    let videoStream: RemoteCaptureVideoStreamContext
}

private actor RemoteCaptureControlPlane {
    private var stateMachine = ClientRemoteCaptureSessionStateMachine(localMonotonicDomainId: "ios.dispatch.uptime.ns")
    private var latestControlResultValue: ClientRemoteCaptureSessionControlResult?
    private var sessionControlGenerationValue = 0

    func handleInboundPayload(_ payload: Data) async -> Bool {
        guard let message = try? ClientRemoteCaptureControlCodec.decode(payload) else {
            return false
        }

        let previousTiming = stateMachine.timingSnapshot
        if let action = stateMachine.apply(
            message,
            localReceiveTicks: Self.monotonicTicks(),
            observedAtUtc: Self.remoteCaptureTimestamp())
        {
            switch action {
            case .registration:
                break
            case .sessionControlResult(let result):
                latestControlResultValue = result
                sessionControlGenerationValue += 1
            }
        }

        emitTimingTransitionIfNeeded(from: previousTiming, to: stateMachine.timingSnapshot)

        return true
    }

    func handleTransportLifecycleEvent(_ event: QuicTransportLifecycleEvent) {
        switch event {
        case .reconnecting(let sessionId):
            stateMachine.invalidateTiming(
                reasonCode: "remote_node.timing.transport_reconnecting",
                reasonText: "QUIC transport is reconnecting and the current engine timing projection is no longer trusted.",
                localNowTicks: Self.monotonicTicks())
            StructuredLog.emit(
                event: "remote_capture_timing_reset",
                fields: [
                    "session_id": sessionId,
                    "reason_code": "remote_node.timing.transport_reconnecting"
                ])

        case .disconnected(let sessionId):
            stateMachine.invalidateTiming(
                reasonCode: "remote_node.timing.transport_disconnected",
                reasonText: "QUIC transport disconnected and the current engine timing projection was cleared.",
                localNowTicks: Self.monotonicTicks())
            StructuredLog.emit(
                event: "remote_capture_timing_reset",
                fields: [
                    "session_id": sessionId,
                    "reason_code": "remote_node.timing.transport_disconnected"
                ])
        }
    }

    func currentRegistration() -> ClientRemoteCaptureNodeRegistration? {
        stateMachine.registration
    }

    func currentSessionControlGeneration() -> Int {
        sessionControlGenerationValue
    }

    func latestSessionControlResult() -> ClientRemoteCaptureSessionControlResult? {
        latestControlResultValue
    }

    func packetTimingProjection(localCaptureTicks: Int64) -> ClientRemoteNodePacketTimingProjection {
        stateMachine.projectPacketTiming(
            localCaptureTicks: localCaptureTicks,
            localNowTicks: Self.monotonicTicks())
    }

    private func emitTimingTransitionIfNeeded(
        from previous: ClientRemoteNodeTimingSnapshot,
        to current: ClientRemoteNodeTimingSnapshot
    ) {
        guard previous != current else {
            return
        }

        StructuredLog.emit(
            event: "remote_capture_timing_state_changed",
            fields: [
                "mapping_state": current.mappingState.rawValue,
                "lifecycle_state": current.lifecycleState.rawValue,
                "timing_session_id": current.timingSessionId ?? "",
                "timing_domain_id": current.timingDomainId ?? "",
                "timing_authority_id": current.timingAuthorityId ?? "",
                "correction_generation": String(current.correctionGeneration),
                "freshness_ms": current.freshnessMs.map(String.init) ?? "",
                "mapping_age_ms": current.mappingAgeMs.map(String.init) ?? "",
                "confidence_score": current.confidenceScore.map { String(format: "%.3f", $0) } ?? "",
                "estimated_drift_ppm": current.estimatedDriftPpm.map { String(format: "%.3f", $0) } ?? "",
                "error_bound_ms": current.errorBoundMs.map { String(format: "%.3f", $0) } ?? "",
                "jitter_ms": current.jitterMs.map { String(format: "%.3f", $0) } ?? "",
                "residual_ms": current.residualMs.map { String(format: "%.3f", $0) } ?? "",
                "last_reset_reason_code": current.lastResetReasonCode ?? "",
                "reason_code": current.reasonCode ?? ""
            ])
    }

    private static func monotonicTicks() -> Int64 {
        Int64(DispatchTime.now().uptimeNanoseconds)
    }

    private static func remoteCaptureTimestamp() -> String {
        ISO8601DateFormatter.fractional.string(from: .now)
    }
}

private extension ISO8601DateFormatter {
    static var fractional: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }
}
