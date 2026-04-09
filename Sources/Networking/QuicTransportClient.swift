import CryptoKit
import Foundation
import LinnaeusEngineClientSdkApple
import Network
import ProvinodeRoomContracts
import Security

actor QuicTransportClient {
    private var connection: NWConnection?
    private var receiveTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var sessionState: ClientQuicSessionState = .idle
    private var secureSession: EngineSecureChannelCrypto.SessionKeys?
    private var outboundCounter: Int64 = 0
    private var inboundCounter: Int64 = -1
    private var receiveBuffer = Data()
    private var activeSessionId = ""
    private var connectionPlan: ConnectionPlan?
    private var replayBuffer = ClientReplayBuffer(maxBufferedSampleFrames: 512)
    private var backpressureHandler: (@Sendable (BackpressureHint) async -> Void)?
    private var controlPayloadHandler: (@Sendable (Data) async -> Bool)?
    private var lifecycleEventHandler: (@Sendable (QuicTransportLifecycleEvent) async -> Void)?

    func setBackpressureHandler(_ handler: (@Sendable (BackpressureHint) async -> Void)?) {
        backpressureHandler = handler
    }

    func setControlPayloadHandler(_ handler: (@Sendable (Data) async -> Bool)?) {
        controlPayloadHandler = handler
    }

    func setLifecycleEventHandler(_ handler: (@Sendable (QuicTransportLifecycleEvent) async -> Void)?) {
        lifecycleEventHandler = handler
    }

    func connect(
        host: String,
        port: Int,
        pinnedFingerprintSha256: String?,
        sessionId: String,
        scanIdentity: ScanIdentityMaterial,
        scanClientMtlsIdentity: ScanClientTlsIdentityMaterial?,
        requireEngineSecureChannel: Bool = true
    ) async throws {
        reconnectTask?.cancel()
        reconnectTask = nil
        closeConnection(resetReplayState: false, clearPlan: false)
        sessionState = ClientQuicSessionPolicy.stateForConnectStart(isReconnect: false)

        let plan = ConnectionPlan(
            host: host,
            port: port,
            pinnedFingerprintSha256: pinnedFingerprintSha256,
            sessionId: sessionId,
            scanIdentity: scanIdentity,
            scanClientMtlsIdentity: scanClientMtlsIdentity,
            requireEngineSecureChannel: requireEngineSecureChannel)
        connectionPlan = plan
        activeSessionId = sessionId

        if replayBuffer.activeSessionId != sessionId {
            replayBuffer.reset(for: sessionId)
        }

        do {
            try await establishConnection(plan: plan, isReconnect: false)
        } catch {
            await handleConnectionFailure(error)
            throw error
        }
    }

    func disconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
        let sessionId = activeSessionId
        if !sessionId.isEmpty, let lifecycleEventHandler {
            Task { await lifecycleEventHandler(.disconnected(sessionId: sessionId)) }
        }
        closeConnection(resetReplayState: true, clearPlan: true)
    }

    func sendControl<T: Encodable>(_ value: T) throws {
        let payload = try JSONEncoder().encode(value)
        try sendPayload(channel: ClientQuicChannel.control.rawValue, payload: payload)
    }

    func sendSample(envelope: CaptureSampleEnvelope, payload: Data) throws {
        let envelopeData = try JSONEncoder().encode(envelope)
        var frame = Data()

        var envelopeSize = UInt32(envelopeData.count).bigEndian
        withUnsafeBytes(of: &envelopeSize) { frame.append(contentsOf: $0) }

        frame.append(envelopeData)
        frame.append(payload)

        replayBuffer.buffer(sampleSeq: envelope.sample_seq, frame: frame, activeSessionId: activeSessionId)
        let requiresSecureChannel = connectionPlan?.requireEngineSecureChannel ?? true
        if requiresSecureChannel && secureSession == nil {
            return
        }

        try sendPayload(channel: ClientQuicChannel.sample.rawValue, payload: frame)
    }

    func sendRemoteCaptureVideoFrame(
        envelope: ClientRemoteCaptureVideoPacketEnvelope,
        payload: Data
    ) throws {
        let frame = try ClientRemoteCaptureVideoPacketCodec.encodeFrame(
            envelope: envelope,
            payload: payload)

        replayBuffer.buffer(
            sampleSeq: envelope.packet.sequenceNumber,
            frame: frame,
            activeSessionId: activeSessionId)

        let requiresSecureChannel = connectionPlan?.requireEngineSecureChannel ?? true
        if requiresSecureChannel && secureSession == nil {
            return
        }

        try sendPayload(channel: ClientQuicChannel.sample.rawValue, payload: frame)
    }

    private func sendPayload(channel: UInt8, payload: Data) throws {
        let requiresSecureChannel = connectionPlan?.requireEngineSecureChannel ?? true
        if !requiresSecureChannel {
            try sendFrame(channel: channel, payload: payload)
            return
        }

        guard secureSession != nil else {
            throw NSError(domain: "QuicTransportClient", code: 2005, userInfo: [NSLocalizedDescriptionKey: "Secure session is not established"])
        }

        try sendSecurePayload(payloadChannel: Int(channel), payload: payload)
    }

    private func sendSecurePayload(payloadChannel: Int, payload: Data) throws {
        guard let secureSession else {
            throw NSError(domain: "QuicTransportClient", code: 2006, userInfo: [NSLocalizedDescriptionKey: "Missing secure session"])
        }

        let envelope = try ClientSecurePayloadCodec.encode(
            payloadChannel: payloadChannel,
            payload: payload,
            keys: secureSession,
            counter: outboundCounter)
        outboundCounter += 1

        let encryptedPayload = try JSONEncoder().encode(envelope)
        try sendFrame(channel: ClientQuicChannel.secureEnvelope.rawValue, payload: encryptedPayload)
    }

    private func performSecureHandshake(
        connection: NWConnection,
        sessionId: String,
        scanIdentity: ScanIdentityMaterial
    ) async throws {
        let keyPair = EngineSecureChannelCrypto.createEphemeralKeyPair()
        let helloNonce = ULID.generate()
        let createdAtUtc = ISO8601DateFormatter.fractional.string(from: .now)
        let signingPayload = EngineSecureChannelCrypto.buildSecureHelloSigningPayload(
            protocolId: RoomContractVersions.secureChannelProtocol,
            sessionId: sessionId,
            scanDeviceId: scanIdentity.deviceId,
            scanCertFingerprintSha256: scanIdentity.certFingerprintSha256,
            helloNonce: helloNonce,
            clientEphemeralPublicKeyB64: keyPair.publicKeyX963.base64EncodedString(),
            scanSigningPublicKeyB64: scanIdentity.signingPublicKeyB64)
        let signature = try EngineSecureChannelCrypto.signSecureHello(
            privateKeyRawB64: scanIdentity.signingPrivateKeyRawB64,
            payload: signingPayload)

        let signingPublicKeyLength = Data(base64Encoded: scanIdentity.signingPublicKeyB64)?.count ?? -1
        StructuredLog.emit(
            event: "quic_secure_hello_sending",
            fields: [
                "session_id": sessionId,
                "client_ephemeral_len_bytes": String(keyPair.publicKeyX963.count),
                "scan_signing_public_key_len_bytes": String(signingPublicKeyLength),
                "hello_signature_len_bytes": String(signature.count),
            ])

        let hello = SecureChannelHello(
            protocol: RoomContractVersions.secureChannelProtocol,
            session_id: sessionId,
            scan_device_id: scanIdentity.deviceId,
            scan_cert_fingerprint_sha256: scanIdentity.certFingerprintSha256,
            hello_nonce: helloNonce,
            client_ephemeral_public_key_b64: keyPair.publicKeyX963.base64EncodedString(),
            created_at_utc: createdAtUtc,
            scan_signing_public_key_b64: scanIdentity.signingPublicKeyB64,
            hello_signature_b64: signature.base64EncodedString())

        let helloPayload = try JSONEncoder().encode(hello)
        try sendFrame(channel: ClientQuicChannel.control.rawValue, payload: helloPayload)

        let ackFrame = try await readFrame(connection: connection)
        guard ackFrame.channel == ClientQuicChannel.control.rawValue else {
            throw NSError(domain: "QuicTransportClient", code: 2002, userInfo: [NSLocalizedDescriptionKey: "Expected secure handshake ack"])
        }

        let ack = try JSONDecoder().decode(SecureChannelAck.self, from: ackFrame.payload)
        guard ack.protocol == RoomContractVersions.secureChannelProtocol else {
            throw NSError(domain: "QuicTransportClient", code: 2003, userInfo: [NSLocalizedDescriptionKey: "Secure handshake protocol mismatch"])
        }
        guard ack.session_id == sessionId else {
            throw NSError(domain: "QuicTransportClient", code: 2007, userInfo: [NSLocalizedDescriptionKey: "Secure handshake session mismatch"])
        }

        let salt = Data(base64Encoded: ack.ack_salt_b64) ?? Data()
        let peerPublicKey = Data(base64Encoded: ack.server_ephemeral_public_key_b64) ?? Data()
        StructuredLog.emit(
            event: "quic_secure_hello_ack",
            fields: [
                "session_id": sessionId,
                "ack_salt_len_bytes": String(salt.count),
                "server_ephemeral_len_bytes": String(peerPublicKey.count),
            ])
        let keys = try EngineSecureChannelCrypto.deriveSessionKeys(
            localKeyPair: keyPair,
            peerPublicKeyX963: peerPublicKey,
            salt: salt)

        secureSession = keys
        outboundCounter = 0
        inboundCounter = -1
    }

    private func sendFrame(channel: UInt8, payload: Data) throws {
        guard let connection else {
            throw NSError(domain: "QuicTransportClient", code: 2001, userInfo: [NSLocalizedDescriptionKey: "No active QUIC connection"])
        }

        let frame = ClientQuicFrameCodec.encodeFrame(channel: channel, payload: payload)
        let sessionId = activeSessionId

        connection.send(content: frame, completion: .contentProcessed { error in
            if let error {
                StructuredLog.emit(
                    event: "quic_send_failed",
                    level: "error",
                    fields: [
                        "session_id": sessionId,
                        "error": error.localizedDescription,
                    ])
                Task { await self.handleConnectionFailure(error) }
            }
        })
    }

    private func waitUntilReadyAndStart(_ connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let continuationBox = ConnectionStartContinuationBox(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    continuationBox.resume()
                case .failed(let error):
                    continuationBox.resume(throwing: error)
                default:
                    break
                }
            }
            connection.start(queue: DispatchQueue.global(qos: .userInitiated))
        }
    }

    private func readFrame(connection: NWConnection) async throws -> (channel: UInt8, payload: Data) {
        var buffer = Data()

        while true {
            let chunk = try await readChunk(connection: connection)
            buffer.append(chunk)

            if let frame = ClientQuicFrameCodec.decodeNextFrame(from: &buffer) {
                return (frame.channel, frame.payload)
            }
        }
    }

    private func readChunk(connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let data, !data.isEmpty else {
                    continuation.resume(throwing: NSError(domain: "QuicTransportClient", code: 2004, userInfo: [NSLocalizedDescriptionKey: "Connection closed"]))
                    return
                }

                continuation.resume(returning: data)
            }
        }
    }

    private func startReceiveLoop(connection: NWConnection) {
        receiveTask?.cancel()
        receiveTask = Task(priority: .utility) { [connection] in
            await receiveLoop(connection: connection)
        }
    }

    private func receiveLoop(connection: NWConnection) async {
        while !Task.isCancelled {
            do {
                let chunk = try await readChunk(connection: connection)
                receiveBuffer.append(chunk)
                try await processBufferedFrames()
            } catch {
                StructuredLog.emit(
                    event: "quic_receive_failed",
                    level: "error",
                    fields: [
                        "session_id": activeSessionId,
                        "error": error.localizedDescription,
                    ])
                await handleConnectionFailure(error)
                break
            }
        }
    }

    private func processBufferedFrames() async throws {
        while true {
            guard let frame = ClientQuicFrameCodec.decodeNextFrame(from: &receiveBuffer) else {
                return
            }

            try await handleInboundFrame(channel: frame.channel, payload: frame.payload)
        }
    }

    private func handleInboundFrame(channel: UInt8, payload: Data) async throws {
        if channel == ClientQuicChannel.secureEnvelope.rawValue {
            try await handleSecureEnvelope(payload: payload)
            return
        }

        if channel == ClientQuicChannel.control.rawValue {
            try await handleControlPayload(payload)
        }
    }

    private func handleSecureEnvelope(payload: Data) async throws {
        guard let secureSession else {
            return
        }

        let envelope = try JSONDecoder().decode(SecureCipherEnvelope.self, from: payload)
        guard let opened = try ClientSecurePayloadCodec.open(
            envelope,
            keys: secureSession,
            minimumCounterExclusive: inboundCounter)
        else {
            return
        }

        inboundCounter = opened.counter

        if opened.payloadChannel == Int(ClientQuicChannel.control.rawValue) {
            try await handleControlPayload(opened.payload)
        }
    }

    private func handleControlPayload(_ payload: Data) async throws {
        if let controlPayloadHandler, await controlPayloadHandler(payload) {
            return
        }

        switch ClientQuicSessionPolicy.interpretControlPayload(
            payload,
            replayBuffer: &replayBuffer,
            activeSessionId: activeSessionId)
        {
        case let .replayFrames(frames):
            for frame in frames {
                try sendPayload(channel: ClientQuicChannel.sample.rawValue, payload: frame)
            }
        case let .backpressureHint(hint):
            if let backpressureHandler {
                await backpressureHandler(hint)
            }
        case nil:
            return
        }
    }

    private func establishConnection(plan: ConnectionPlan, isReconnect: Bool) async throws {
        sessionState = ClientQuicSessionPolicy.stateForConnectStart(isReconnect: isReconnect)
        let quicOptions = NWProtocolQUIC.Options(alpn: ["provinode-room-v1"])
        if let scanClientMtlsIdentity = plan.scanClientMtlsIdentity {
            let identity = try Self.importPkcs12Identity(
                pkcs12Data: scanClientMtlsIdentity.pkcs12Data,
                password: scanClientMtlsIdentity.password)
            let secIdentity = sec_identity_create(identity)!
            sec_protocol_options_set_local_identity(quicOptions.securityProtocolOptions, secIdentity)
        }

        sec_protocol_options_set_verify_block(quicOptions.securityProtocolOptions, { _, secTrust, complete in
            let trustRef = sec_trust_copy_ref(secTrust).takeRetainedValue()

            guard let chain = SecTrustCopyCertificateChain(trustRef) as? [SecCertificate],
                  let leaf = chain.first
            else {
                complete(false)
                return
            }

            let certificateData = SecCertificateCopyData(leaf) as Data
            let digest = SHA256.hash(data: certificateData).map { String(format: "%02x", $0) }.joined()
            if let pinnedFingerprintSha256 = plan.pinnedFingerprintSha256 {
                complete(digest.caseInsensitiveCompare(pinnedFingerprintSha256) == .orderedSame)
                return
            }

            var error: CFError?
            complete(SecTrustEvaluateWithError(trustRef, &error))
        }, DispatchQueue.global(qos: .userInitiated))

        let parameters = NWParameters(quic: quicOptions)
        parameters.allowLocalEndpointReuse = true

        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(plan.port)) else {
            throw NSError(domain: "QuicTransportClient", code: 2000, userInfo: [NSLocalizedDescriptionKey: "Invalid port"])
        }

        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(plan.host), port: nwPort)
        let connection = NWConnection(to: endpoint, using: parameters)
        try await waitUntilReadyAndStart(connection)

        self.connection = connection
        sessionState = ClientQuicSessionPolicy.stateForConnectionEstablished()
        activeSessionId = plan.sessionId
        receiveBuffer = Data()
        inboundCounter = -1
        if plan.requireEngineSecureChannel {
            try await performSecureHandshake(
                connection: connection,
                sessionId: plan.sessionId,
                scanIdentity: plan.scanIdentity)
        } else {
            secureSession = nil
            outboundCounter = 0
        }

        startReceiveLoop(connection: connection)

        let resumeCheckpoint = ClientQuicSessionPolicy.makeResumeCheckpoint(
            sessionId: plan.sessionId,
            lastAckedSampleSeq: replayBuffer.lastAckedSampleSeq,
            capturedAtUtc: ISO8601DateFormatter.fractional.string(from: .now),
            streamId: ClientQuicSessionPolicy.makeResumeStreamId(
                isReconnect: isReconnect,
                uniqueSuffix: ULID.generate()))
        try sendControl(resumeCheckpoint)
    }

    private func handleConnectionFailure(_ error: Error) async {
        guard ClientQuicSessionPolicy.shouldAttemptReconnect(
            hasConnectionPlan: connectionPlan != nil,
            reconnectInFlight: reconnectTask != nil)
        else {
            return
        }

        if !activeSessionId.isEmpty, let lifecycleEventHandler {
            await lifecycleEventHandler(.reconnecting(sessionId: activeSessionId))
        }
        closeConnection(resetReplayState: false, clearPlan: false)
        guard let plan = connectionPlan else {
            return
        }

        sessionState = .reconnecting

        reconnectTask = Task { [weak self] in
            guard let self else { return }
            await self.attemptReconnect(plan: plan)
        }
    }

    private func attemptReconnect(plan: ConnectionPlan) async {
        defer { reconnectTask = nil }

        for reconnectAttempt in ClientQuicSessionPolicy.reconnectAttempts() {
            if Task.isCancelled {
                return
            }

            if reconnectAttempt.delayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: reconnectAttempt.delayNanoseconds)
            }

            do {
                try await establishConnection(plan: plan, isReconnect: true)
                return
            } catch {
                StructuredLog.emit(
                    event: "quic_reconnect_attempt_failed",
                    level: "error",
                    fields: [
                        "session_id": activeSessionId,
                        "attempt": String(reconnectAttempt.attempt),
                        "error": error.localizedDescription,
                    ])
            }
        }

        sessionState = .disconnected
    }

    private func closeConnection(resetReplayState: Bool, clearPlan: Bool) {
        receiveTask?.cancel()
        receiveTask = nil
        connection?.cancel()
        connection = nil
        secureSession = nil
        outboundCounter = 0
        inboundCounter = -1
        receiveBuffer = Data()
        if clearPlan {
            activeSessionId = ""
        } else if let sessionId = connectionPlan?.sessionId {
            activeSessionId = sessionId
        }

        if clearPlan {
            connectionPlan = nil
        }

        if resetReplayState {
            replayBuffer.clear()
        }

        sessionState = ClientQuicSessionPolicy.stateForClosedConnection(
            clearPlan: clearPlan,
            reconnectPending: !clearPlan && reconnectTask != nil)
    }
}

enum QuicTransportLifecycleEvent: Sendable {
    case reconnecting(sessionId: String)
    case disconnected(sessionId: String)
}

private struct ConnectionPlan: Sendable {
    let host: String
    let port: Int
    let pinnedFingerprintSha256: String?
    let sessionId: String
    let scanIdentity: ScanIdentityMaterial
    let scanClientMtlsIdentity: ScanClientTlsIdentityMaterial?
    let requireEngineSecureChannel: Bool
}

private final class ConnectionStartContinuationBox: @unchecked Sendable {
    private let lock = NSLock()
    private let continuation: CheckedContinuation<Void, Error>
    private var didResume = false

    init(_ continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    func resume() {
        lock.lock()
        defer { lock.unlock() }
        guard !didResume else { return }
        didResume = true
        continuation.resume()
    }

    func resume(throwing error: Error) {
        lock.lock()
        defer { lock.unlock() }
        guard !didResume else { return }
        didResume = true
        continuation.resume(throwing: error)
    }
}

private extension ISO8601DateFormatter {
    static var fractional: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }
}

private extension QuicTransportClient {
    static func importPkcs12Identity(pkcs12Data: Data, password: String) throws -> SecIdentity {
        var items: CFArray?
        let options: NSDictionary = [kSecImportExportPassphrase as String: password]
        let status = SecPKCS12Import(pkcs12Data as CFData, options, &items)
        guard status == errSecSuccess,
              let importedItems = items as? [[String: Any]],
              let first = importedItems.first,
              let rawIdentity = first[kSecImportItemIdentity as String]
        else {
            throw NSError(
                domain: "QuicTransportClient",
                code: 2010,
                userInfo: [NSLocalizedDescriptionKey: "Failed to import scan client mTLS identity."])
        }

        let identity = rawIdentity as! SecIdentity
        return identity
    }
}
