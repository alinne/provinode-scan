import Foundation
import ProvinodeRoomContracts

struct PairingEndpoint: Codable, Hashable {
    let host: String
    let port: Int
    let displayName: String
    let desktopDeviceId: String
}

enum PairingError: Error {
    case invalidCode
    case expired
    case lockedOut
    case serverRejected
}

actor PairingService {
    private let trustStore: TrustStore
    private let session: URLSession

    init(trustStore: TrustStore, session: URLSession = .shared) {
        self.trustStore = trustStore
        self.session = session
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

        var request = URLRequest(url: URL(string: "https://\(endpoint.host):\(endpoint.port)/pairing/confirm")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = requestBody

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
