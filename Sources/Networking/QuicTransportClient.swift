import CryptoKit
import Foundation
import Network
import ProvinodeRoomContracts
import Security

actor QuicTransportClient {
    private var connection: NWConnection?
    private var receiveTask: Task<Void, Never>?
    private var secureSession: EngineSecureChannelCrypto.SessionKeys?
    private var outboundCounter: Int64 = 0

    func connect(host: String, port: Int, pinnedFingerprintSha256: String?, sessionId: String) async throws {
        let quicOptions = NWProtocolQUIC.Options(alpn: ["provinode-room-v1"])
        sec_protocol_options_set_verify_block(quicOptions.securityProtocolOptions, { _, secTrust, complete in
            let trustRef = sec_trust_copy_ref(secTrust).takeRetainedValue()

            var error: CFError?
            guard SecTrustEvaluateWithError(trustRef, &error) else {
                complete(false)
                return
            }

            guard let pinnedFingerprintSha256 else {
                complete(true)
                return
            }

            guard let chain = SecTrustCopyCertificateChain(trustRef) as? [SecCertificate],
                  let leaf = chain.first
            else {
                complete(false)
                return
            }

            let certificateData = SecCertificateCopyData(leaf) as Data
            let digest = SHA256.hash(data: certificateData).map { String(format: "%02x", $0) }.joined()
            complete(digest.caseInsensitiveCompare(pinnedFingerprintSha256) == .orderedSame)
        }, DispatchQueue.global(qos: .userInitiated))

        let parameters = NWParameters(quic: quicOptions)
        parameters.allowLocalEndpointReuse = true

        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            throw NSError(domain: "QuicTransportClient", code: 2000, userInfo: [NSLocalizedDescriptionKey: "Invalid port"])
        }

        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: nwPort)
        let connection = NWConnection(to: endpoint, using: parameters)

        try await waitUntilReadyAndStart(connection)

        self.connection = connection
        try await performSecureHandshake(connection: connection, sessionId: sessionId)
        startReceiveLoop(connection: connection)
    }

    func disconnect() {
        receiveTask?.cancel()
        receiveTask = nil
        connection?.cancel()
        connection = nil
        secureSession = nil
        outboundCounter = 0
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

    private func performSecureHandshake(connection: NWConnection, sessionId: String) async throws {
        let keyPair = EngineSecureChannelCrypto.createEphemeralKeyPair()
        let hello = SecureChannelHello(
            protocol: RoomContractVersions.secureChannelProtocol,
            session_id: sessionId,
            hello_nonce: ULID.generate(),
            client_ephemeral_public_key_b64: keyPair.publicKeyX963.base64EncodedString(),
            created_at_utc: ISO8601DateFormatter.fractional.string(from: .now))

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

        let salt = Data(base64Encoded: ack.ack_salt_b64) ?? Data()
        let peerPublicKey = Data(base64Encoded: ack.server_ephemeral_public_key_b64) ?? Data()
        let keys = try EngineSecureChannelCrypto.deriveSessionKeys(
            localKeyPair: keyPair,
            peerPublicKeyX963: peerPublicKey,
            salt: salt)

        secureSession = keys
        outboundCounter = 0
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
            var resumed = false
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard !resumed else { return }
                    resumed = true
                    continuation.resume()
                case .failed(let error):
                    guard !resumed else { return }
                    resumed = true
                    continuation.resume(throwing: error)
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
                    continuation.resume(throwing: NSError(domain: "QuicTransportClient", code: 2004, userInfo: [NSLocalizedDescriptionKey: "Connection closed during handshake"]))
                    return
                }

                continuation.resume(returning: data)
            }
        }
    }

    private func startReceiveLoop(connection: NWConnection) {
        receiveTask = Task.detached(priority: .utility) {
            while !Task.isCancelled {
                await withCheckedContinuation { continuation in
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { _, _, _, error in
                        if let error {
                            NSLog("QUIC receive failed: \(error.localizedDescription)")
                        }
                        continuation.resume()
                    }
                }
            }
        }
    }
}

private extension ISO8601DateFormatter {
    static var fractional: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }
}
