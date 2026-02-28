import CryptoKit
import Foundation
import Network
import ProvinodeRoomContracts
import Security

actor QuicTransportClient {
    private let maxBufferedSampleFrames = 512
    private var connection: NWConnection?
    private var receiveTask: Task<Void, Never>?
    private var secureSession: EngineSecureChannelCrypto.SessionKeys?
    private var outboundCounter: Int64 = 0
    private var inboundCounter: Int64 = -1
    private var receiveBuffer = Data()
    private var lastAckedSampleSeq: Int64 = -1
    private var activeSessionId = ""
    private var bufferedSampleSessionId = ""
    private var bufferedSampleFrames: [Int64: Data] = [:]
    private var bufferedSampleOrder: [Int64] = []
    private var backpressureHandler: (@Sendable (BackpressureHint) async -> Void)?

    func setBackpressureHandler(_ handler: (@Sendable (BackpressureHint) async -> Void)?) {
        backpressureHandler = handler
    }

    func connect(
        host: String,
        port: Int,
        pinnedFingerprintSha256: String?,
        sessionId: String,
        scanIdentity: ScanIdentityMaterial
    ) async throws {
        let quicOptions = NWProtocolQUIC.Options(alpn: ["provinode-room-v1"])
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
            if let pinnedFingerprintSha256 {
                complete(digest.caseInsensitiveCompare(pinnedFingerprintSha256) == .orderedSame)
                return
            }

            var error: CFError?
            complete(SecTrustEvaluateWithError(trustRef, &error))
        }, DispatchQueue.global(qos: .userInitiated))

        let parameters = NWParameters(quic: quicOptions)
        parameters.allowLocalEndpointReuse = true

        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            throw NSError(domain: "QuicTransportClient", code: 2000, userInfo: [NSLocalizedDescriptionKey: "Invalid port"])
        }

        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: nwPort)
        let connection = NWConnection(to: endpoint, using: parameters)
        try await waitUntilReadyAndStart(connection)

        if bufferedSampleSessionId != sessionId {
            resetReplayBuffer(for: sessionId)
        }

        self.connection = connection
        self.activeSessionId = sessionId
        self.receiveBuffer = Data()
        self.inboundCounter = -1
        try await performSecureHandshake(
            connection: connection,
            sessionId: sessionId,
            scanIdentity: scanIdentity)

        let resumeCheckpoint = ResumeCheckpoint(
            session_id: sessionId,
            last_acked_sample_seq: lastAckedSampleSeq,
            captured_at_utc: ISO8601DateFormatter.fractional.string(from: .now),
            stream_id: "scan-\(ULID.generate())")
        try sendControl(resumeCheckpoint)

        startReceiveLoop(connection: connection)
    }

    func disconnect() {
        receiveTask?.cancel()
        receiveTask = nil
        connection?.cancel()
        connection = nil
        secureSession = nil
        outboundCounter = 0
        inboundCounter = -1
        receiveBuffer = Data()
        activeSessionId = ""
        bufferedSampleSessionId = ""
        bufferedSampleFrames.removeAll(keepingCapacity: false)
        bufferedSampleOrder.removeAll(keepingCapacity: false)
        lastAckedSampleSeq = -1
    }

    func sendControl<T: Encodable>(_ value: T) throws {
        let payload = try JSONEncoder().encode(value)
        try sendPayload(channel: 0x01, payload: payload)
    }

    func sendSample(envelope: CaptureSampleEnvelope, payload: Data) throws {
        let envelopeData = try JSONEncoder().encode(envelope)
        var frame = Data()

        var envelopeSize = UInt32(envelopeData.count).bigEndian
        withUnsafeBytes(of: &envelopeSize) { frame.append(contentsOf: $0) }

        frame.append(envelopeData)
        frame.append(payload)

        try sendPayload(channel: 0x02, payload: frame)
        bufferSampleFrame(sampleSeq: envelope.sample_seq, frame: frame)
    }

    private func sendPayload(channel: UInt8, payload: Data) throws {
        guard secureSession != nil else {
            throw NSError(domain: "QuicTransportClient", code: 2005, userInfo: [NSLocalizedDescriptionKey: "Secure session is not established"])
        }

        try sendSecurePayload(payloadChannel: Int(channel), payload: payload)
    }

    private func sendSecurePayload(payloadChannel: Int, payload: Data) throws {
        guard let secureSession else {
            throw NSError(domain: "QuicTransportClient", code: 2006, userInfo: [NSLocalizedDescriptionKey: "Missing secure session"])
        }

        let cipher = try EngineSecureChannelCrypto.encrypt(keys: secureSession, counter: outboundCounter, plaintext: payload)
        outboundCounter += 1

        let envelope = SecureCipherEnvelope(
            protocol: RoomContractVersions.secureChannelProtocol,
            payload_channel: payloadChannel,
            counter: cipher.counter,
            nonce_b64: cipher.nonce.base64EncodedString(),
            ciphertext_b64: cipher.ciphertext.base64EncodedString(),
            tag_b64: cipher.tag.base64EncodedString())

        let encryptedPayload = try JSONEncoder().encode(envelope)
        try sendFrame(channel: 0x03, payload: encryptedPayload)
    }

    private func performSecureHandshake(
        connection: NWConnection,
        sessionId: String,
        scanIdentity: ScanIdentityMaterial
    ) async throws {
        let keyPair = EngineSecureChannelCrypto.createEphemeralKeyPair()
        let helloNonce = ULID.generate()
        let createdAtUtc = ISO8601DateFormatter.fractional.string(from: .now)
        let signingPayload = Self.buildSecureHelloSigningPayload(
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
        try sendFrame(channel: 0x01, payload: helloPayload)

        let ackFrame = try await readFrame(connection: connection)
        guard ackFrame.channel == 0x01 else {
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
        let keys = try EngineSecureChannelCrypto.deriveSessionKeys(
            localKeyPair: keyPair,
            peerPublicKeyX963: peerPublicKey,
            salt: salt)

        secureSession = keys
        outboundCounter = 0
        inboundCounter = -1
    }

    private static func buildSecureHelloSigningPayload(
        protocolId: String,
        sessionId: String,
        scanDeviceId: String,
        scanCertFingerprintSha256: String,
        helloNonce: String,
        clientEphemeralPublicKeyB64: String,
        scanSigningPublicKeyB64: String
    ) -> Data {
        let canonical = [
            protocolId,
            sessionId,
            scanDeviceId,
            scanCertFingerprintSha256.lowercased(),
            helloNonce,
            clientEphemeralPublicKeyB64,
            scanSigningPublicKeyB64
        ].joined(separator: "\n")
        return Data(canonical.utf8)
    }

    private func sendFrame(channel: UInt8, payload: Data) throws {
        guard let connection else {
            throw NSError(domain: "QuicTransportClient", code: 2001, userInfo: [NSLocalizedDescriptionKey: "No active QUIC connection"])
        }

        var frame = Data([channel])
        var payloadSize = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &payloadSize) { frame.append(contentsOf: $0) }
        frame.append(payload)

        connection.send(content: frame, completion: .contentProcessed { error in
            if let error {
                NSLog("QUIC send failed: \(error.localizedDescription)")
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

            if buffer.count >= 5 {
                let channel = buffer[0]
                let length = buffer.dropFirst().prefix(4).reduce(0) { ($0 << 8) | UInt32($1) }
                let total = 5 + Int(length)
                if buffer.count >= total {
                    return (channel, buffer.subdata(in: 5..<total))
                }
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
                NSLog("QUIC receive failed: \(error.localizedDescription)")
                break
            }
        }
    }

    private func processBufferedFrames() async throws {
        while true {
            guard receiveBuffer.count >= 5 else {
                return
            }

            let channel = receiveBuffer[0]
            let length = receiveBuffer.dropFirst().prefix(4).reduce(0) { ($0 << 8) | UInt32($1) }
            let total = 5 + Int(length)
            guard receiveBuffer.count >= total else {
                return
            }

            let payload = receiveBuffer.subdata(in: 5..<total)
            receiveBuffer.removeSubrange(0..<total)
            try await handleInboundFrame(channel: channel, payload: payload)
        }
    }

    private func handleInboundFrame(channel: UInt8, payload: Data) async throws {
        if channel == 0x03 {
            try await handleSecureEnvelope(payload: payload)
            return
        }

        if channel == 0x01 {
            try await handleControlPayload(payload)
        }
    }

    private func handleSecureEnvelope(payload: Data) async throws {
        guard let secureSession else {
            return
        }

        let envelope = try JSONDecoder().decode(SecureCipherEnvelope.self, from: payload)
        guard envelope.protocol == RoomContractVersions.secureChannelProtocol else {
            return
        }

        guard envelope.counter > inboundCounter else {
            return
        }

        guard let nonce = Data(base64Encoded: envelope.nonce_b64),
              let ciphertext = Data(base64Encoded: envelope.ciphertext_b64),
              let tag = Data(base64Encoded: envelope.tag_b64)
        else {
            return
        }

        let plaintext = try EngineSecureChannelCrypto.decrypt(
            keys: secureSession,
            nonce: nonce,
            ciphertext: ciphertext,
            tag: tag)
        inboundCounter = envelope.counter

        if envelope.payload_channel == 0x01 {
            try await handleControlPayload(plaintext)
        }
    }

    private func handleControlPayload(_ payload: Data) async throws {
        if let checkpoint = try? JSONDecoder().decode(ResumeCheckpoint.self, from: payload),
           checkpoint.session_id == activeSessionId
        {
            lastAckedSampleSeq = max(lastAckedSampleSeq, checkpoint.last_acked_sample_seq)
            trimReplayBuffer(ackedThrough: lastAckedSampleSeq)

            if checkpoint.stream_id == "desktop-resume" {
                try replayBufferedSamples(after: checkpoint.last_acked_sample_seq)
            }
            return
        }

        if let hint = try? JSONDecoder().decode(BackpressureHint.self, from: payload),
           let backpressureHandler
        {
            await backpressureHandler(hint)
        }
    }

    private func resetReplayBuffer(for sessionId: String) {
        bufferedSampleSessionId = sessionId
        bufferedSampleFrames.removeAll(keepingCapacity: true)
        bufferedSampleOrder.removeAll(keepingCapacity: true)
        lastAckedSampleSeq = -1
    }

    private func bufferSampleFrame(sampleSeq: Int64, frame: Data) {
        if bufferedSampleSessionId != activeSessionId {
            resetReplayBuffer(for: activeSessionId)
        }

        if bufferedSampleFrames[sampleSeq] == nil {
            bufferedSampleOrder.append(sampleSeq)
        }

        bufferedSampleFrames[sampleSeq] = frame
        trimReplayBuffer(ackedThrough: lastAckedSampleSeq)

        while bufferedSampleOrder.count > maxBufferedSampleFrames {
            let oldest = bufferedSampleOrder.removeFirst()
            bufferedSampleFrames.removeValue(forKey: oldest)
        }
    }

    private func trimReplayBuffer(ackedThrough ackedSampleSeq: Int64) {
        guard ackedSampleSeq >= 0 else { return }
        bufferedSampleOrder.removeAll { seq in
            if seq <= ackedSampleSeq {
                bufferedSampleFrames.removeValue(forKey: seq)
                return true
            }

            return false
        }
    }

    private func replayBufferedSamples(after ackedSampleSeq: Int64) throws {
        guard !bufferedSampleOrder.isEmpty else { return }
        let pending = bufferedSampleOrder
            .filter { $0 > ackedSampleSeq }
            .sorted()

        for seq in pending {
            guard let frame = bufferedSampleFrames[seq] else { continue }
            try sendPayload(channel: 0x02, payload: frame)
        }
    }
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
