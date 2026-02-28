import CryptoKit
import Foundation
import ProvinodeRoomContracts
import Security

struct PairingEndpoint: Codable, Hashable {
    let host: String
    let port: Int
    let quicPort: Int
    let pairingScheme: String
    let pairingCertFingerprintSha256: String?
    let displayName: String
    let desktopDeviceId: String
}

enum PairingError: Error {
    case untrustedEndpoint
    case invalidCode
    case expired
    case lockedOut
    case serverRejected
}

actor PairingService {
    private let trustStore: TrustStore

    init(trustStore: TrustStore) {
        self.trustStore = trustStore
    }

    func confirmPairing(
        endpoint: PairingEndpoint,
        pairingNonce: String,
        pairingCode: String,
        scanDeviceId: String,
        scanDisplayName: String,
        scanCertFingerprintSha256: String,
        desktopCertFingerprintSha256: String
    ) async throws -> TrustRecord {
        guard let pinnedFingerprint = endpoint.pairingCertFingerprintSha256,
              Self.isValidSha256Hex(pinnedFingerprint)
        else {
            throw PairingError.untrustedEndpoint
        }

        let confirmPayload = PairingConfirmPayload(
            pairing_nonce: pairingNonce,
            scan_device_id: scanDeviceId,
            scan_display_name: scanDisplayName,
            scan_cert_fingerprint_sha256: scanCertFingerprintSha256,
            desktop_cert_fingerprint_sha256: desktopCertFingerprintSha256,
            confirmed_at_utc: ISO8601DateFormatter.fractional.string(from: .now))

        let requestBody = try JSONEncoder().encode(PairingConfirmRequest(
            pairing_code: pairingCode,
            pairing_confirm: confirmPayload))

        let baseHost = endpoint.host.trimmingCharacters(in: .whitespacesAndNewlines)
        let hostWithScheme: String
        if baseHost.hasPrefix("http://") || baseHost.hasPrefix("https://") {
            hostWithScheme = baseHost
        } else {
            hostWithScheme = "\(endpoint.pairingScheme)://\(baseHost)"
        }

        guard var components = URLComponents(string: hostWithScheme) else {
            throw PairingError.serverRejected
        }
        components.port = endpoint.port
        components.path = "/pairing/confirm"

        guard let url = components.url else {
            throw PairingError.serverRejected
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = requestBody

        let session = URLSession(
            configuration: .ephemeral,
            delegate: PinnedTlsDelegate(expectedFingerprintSha256: pinnedFingerprint),
            delegateQueue: nil)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw PairingError.serverRejected
        }

        switch httpResponse.statusCode {
        case 200:
            let record = try JSONDecoder().decode(TrustRecord.self, from: data)
            try await trustStore.upsert(record)
            return record
        case 401:
            throw PairingError.invalidCode
        case 410:
            throw PairingError.expired
        case 429:
            throw PairingError.lockedOut
        default:
            throw PairingError.serverRejected
        }
    }
}

extension PairingError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .untrustedEndpoint:
            return "Receiver endpoint is missing a trusted pairing certificate fingerprint."
        case .invalidCode:
            return "Pairing code or nonce is invalid."
        case .expired:
            return "Pairing session has expired."
        case .lockedOut:
            return "Pairing is temporarily locked due to repeated invalid attempts."
        case .serverRejected:
            return "Desktop receiver rejected pairing request."
        }
    }
}

private extension PairingService {
    static func isValidSha256Hex(_ value: String) -> Bool {
        guard value.count == 64 else { return false }
        return value.allSatisfy { char in
            char.isHexDigit
        }
    }
}

private final class PinnedTlsDelegate: NSObject, URLSessionDelegate {
    private let expectedFingerprintSha256: String

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

        completionHandler(.useCredential, URLCredential(trust: serverTrust))
    }
}

private struct PairingConfirmRequest: Encodable {
    let pairing_code: String
    let pairing_confirm: PairingConfirmPayload
}

private struct PairingConfirmPayload: Encodable {
    let pairing_nonce: String
    let scan_device_id: String
    let scan_display_name: String
    let scan_cert_fingerprint_sha256: String
    let desktop_cert_fingerprint_sha256: String
    let confirmed_at_utc: String
}

private extension ISO8601DateFormatter {
    static var fractional: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }
}
