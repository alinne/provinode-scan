import CryptoKit
import Foundation
import ProvinodeRoomContracts
import Security

enum PairingQrVerificationError: LocalizedError, Equatable {
    case emptyPayload
    case nonUtf8
    case malformedQr
    case invalidPairingEndpoint
    case unsupportedProtocol
    case expired
    case invalidFingerprint
    case invalidSignatureEncoding
    case invalidQuicEndpoint
    case signerVerificationUnreachable
    case signerUntrusted
    case invalidSignature

    var errorDescription: String? {
        switch self {
        case .emptyPayload:
            return "QR payload is empty"
        case .nonUtf8:
            return "QR payload is not UTF-8"
        case .malformedQr:
            return "QR payload is malformed"
        case .invalidPairingEndpoint:
            return "QR payload pairing endpoint is invalid"
        case .unsupportedProtocol:
            return "QR payload protocol version is unsupported"
        case .expired:
            return "QR payload has expired. Start a new pairing session."
        case .invalidFingerprint:
            return "QR payload desktop certificate fingerprint is invalid"
        case .invalidSignatureEncoding:
            return "QR payload signature is missing or invalid"
        case .invalidQuicEndpoint:
            return "QR payload QUIC endpoint is invalid"
        case .signerVerificationUnreachable:
            return "QR signer could not be verified from the desktop endpoint"
        case .signerUntrusted:
            return "QR signer is untrusted or did not match the advertised desktop identity"
        case .invalidSignature:
            return "QR payload signature is invalid"
        }
    }
}

struct VerifiedPairingQrPayload: Sendable {
    let payload: PairingQrPayload
    let pairingHost: String
    let pairingPort: Int
    let quicHost: String
    let quicPort: Int
}

protocol PairingQrVerifying: Sendable {
    func verify(rawPayload: String) async throws -> VerifiedPairingQrPayload
}

struct PairingQrSignerIdentity: Sendable {
    let fingerprintSha256: String
    let publicKey: SecKey
}

struct PairingQrVerificationService: PairingQrVerifying {
    private let signerResolver: @Sendable (PairingQrPayload) async throws -> PairingQrSignerIdentity

    init(signerResolver: @escaping @Sendable (PairingQrPayload) async throws -> PairingQrSignerIdentity = Self.resolveSignerIdentity) {
        self.signerResolver = signerResolver
    }

    func verify(rawPayload: String) async throws -> VerifiedPairingQrPayload {
        let trimmed = rawPayload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw PairingQrVerificationError.emptyPayload
        }

        guard let data = trimmed.data(using: .utf8) else {
            throw PairingQrVerificationError.nonUtf8
        }

        let payload: PairingQrPayload
        do {
            payload = try JSONDecoder().decode(PairingQrPayload.self, from: data)
        } catch {
            throw PairingQrVerificationError.malformedQr
        }

        guard let pairingUrl = URL(string: payload.pairing_endpoint),
              let pairingHost = pairingUrl.host,
              !pairingHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              pairingUrl.scheme?.lowercased() == "https"
        else {
            throw PairingQrVerificationError.invalidPairingEndpoint
        }

        guard payload.protocol_version == RoomContractVersions.pairingQrPayloadVersion else {
            throw PairingQrVerificationError.unsupportedProtocol
        }

        guard !isExpired(payload.expires_at_utc) else {
            throw PairingQrVerificationError.expired
        }

        guard isValidSha256Hex(payload.desktop_cert_fingerprint_sha256) else {
            throw PairingQrVerificationError.invalidFingerprint
        }

        guard payload.signature_alg == "rsa-pkcs1-sha256",
              let signatureData = Data(base64Encoded: payload.signature_b64),
              signatureData.count >= 32
        else {
            throw PairingQrVerificationError.invalidSignatureEncoding
        }

        guard let quicHostPort = parseHostAndPort(payload.quic_endpoint),
              isValidPort(quicHostPort.port)
        else {
            throw PairingQrVerificationError.invalidQuicEndpoint
        }

        let signerIdentity = try await signerResolver(payload)
        guard signerIdentity.fingerprintSha256.caseInsensitiveCompare(payload.desktop_cert_fingerprint_sha256) == .orderedSame else {
            throw PairingQrVerificationError.signerUntrusted
        }

        let canonical = Self.canonicalize(payload: payload, blankSignature: true)
        var error: Unmanaged<CFError>?
        let isValid = SecKeyVerifySignature(
            signerIdentity.publicKey,
            .rsaSignatureMessagePKCS1v15SHA256,
            Data(canonical.utf8) as CFData,
            signatureData as CFData,
            &error)
        guard isValid else {
            throw PairingQrVerificationError.invalidSignature
        }

        return VerifiedPairingQrPayload(
            payload: payload,
            pairingHost: pairingHost,
            pairingPort: pairingUrl.port ?? 7448,
            quicHost: quicHostPort.host,
            quicPort: quicHostPort.port)
    }

    static func canonicalize(payload: PairingQrPayload, blankSignature: Bool) -> String {
        [
            payload.pairing_token,
            payload.pairing_code,
            payload.pairing_nonce,
            payload.desktop_device_id,
            payload.desktop_display_name,
            payload.pairing_endpoint,
            payload.quic_endpoint,
            (payload.candidate_pairing_endpoints ?? []).joined(separator: ","),
            (payload.candidate_quic_endpoints ?? []).joined(separator: ","),
            payload.expires_at_utc,
            payload.desktop_cert_fingerprint_sha256,
            payload.protocol_version,
            payload.signature_alg,
            blankSignature ? "" : payload.signature_b64
        ].joined(separator: "\n")
    }

    private func isExpired(_ value: String) -> Bool {
        guard let date = ISO8601DateFormatter.fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value) else {
            return true
        }

        return date <= Date()
    }

    private func isValidSha256Hex(_ value: String) -> Bool {
        guard value.count == 64 else { return false }
        return value.allSatisfy(\.isHexDigit)
    }

    private func parseHostAndPort(_ value: String) -> (host: String, port: Int)? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let port = Int(parts[1])
        else {
            return nil
        }
        let host = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return nil }
        return (host, port)
    }

    private func isValidPort(_ port: Int) -> Bool {
        (1...65535).contains(port)
    }

    private static func resolveSignerIdentity(payload: PairingQrPayload) async throws -> PairingQrSignerIdentity {
        guard let pairingUrl = URL(string: payload.pairing_endpoint) else {
            throw PairingQrVerificationError.invalidPairingEndpoint
        }

        let verifier = PinnedQrVerifier(expectedFingerprintSha256: payload.desktop_cert_fingerprint_sha256)
        let session = URLSession(configuration: .ephemeral, delegate: verifier, delegateQueue: nil)
        var request = URLRequest(url: pairingUrl.deletingLastPathComponent().appending(path: "identity"))
        request.httpMethod = "GET"
        request.timeoutInterval = 3

        let responseData: Data
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw PairingQrVerificationError.signerVerificationUnreachable
            }
            responseData = data
        } catch let error as PairingQrVerificationError {
            throw error
        } catch {
            throw PairingQrVerificationError.signerVerificationUnreachable
        }

        let identity: PairingIdentityResponse
        do {
            identity = try JSONDecoder().decode(PairingIdentityResponse.self, from: responseData)
        } catch {
            throw PairingQrVerificationError.signerVerificationUnreachable
        }

        guard let publicKey = verifier.leafPublicKey else {
            throw PairingQrVerificationError.signerVerificationUnreachable
        }

        return PairingQrSignerIdentity(
            fingerprintSha256: identity.cert_fingerprint_sha256,
            publicKey: publicKey)
    }
}

private struct PairingIdentityResponse: Codable {
    let signature_alg: String
    let cert_fingerprint_sha256: String
    let subject: String
    let not_before_utc: String
    let not_after_utc: String
}

private final class PinnedQrVerifier: NSObject, URLSessionDelegate {
    let expectedFingerprintSha256: String
    private(set) var leafPublicKey: SecKey?

    init(expectedFingerprintSha256: String) {
        self.expectedFingerprintSha256 = expectedFingerprintSha256
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust,
              let chain = SecTrustCopyCertificateChain(serverTrust) as? [SecCertificate],
              let leaf = chain.first
        else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        let certData = SecCertificateCopyData(leaf) as Data
        let digest = SHA256.hash(data: certData).map { String(format: "%02x", $0) }.joined()
        guard digest.caseInsensitiveCompare(expectedFingerprintSha256) == .orderedSame else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        leafPublicKey = SecTrustCopyKey(serverTrust)
        completionHandler(.useCredential, URLCredential(trust: serverTrust))
    }
}

private extension ISO8601DateFormatter {
    static var fractional: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }
}
