import Foundation
import LinnaeusEngineClientSdkApple
import ProvinodeRoomContracts

typealias PairingEndpoint = LinnaeusEngineClientSdkApple.PairingEndpoint
typealias PairingError = LinnaeusEngineClientSdkApple.PairingError
typealias PairingProblemDetails = LinnaeusEngineClientSdkApple.PairingProblemDetails
typealias PairingSessionClient = LinnaeusEngineClientSdkApple.PairingSessionClient
typealias PairingSessionSummary = LinnaeusEngineClientSdkApple.PairingSessionSummary
typealias PairingSessionStatusResponse = LinnaeusEngineClientSdkApple.PairingSessionStatusResponse
typealias PairingTransportResponse = LinnaeusEngineClientSdkApple.PairingTransportResponse
typealias ScanTraceContext = LinnaeusEngineClientSdkApple.ClientTraceContext

protocol PairingRequestTransport: Sendable {
    func send(_ request: URLRequest, pinnedFingerprintSha256: String) async throws -> PairingTransportResponse
}

protocol PhoneAnchorClient: Sendable {
    func fetchCurrentPhoneAnchorSession(endpoint: PairingEndpoint) async throws -> PhoneAnchorSessionSnapshot?
    func fetchPhoneAnchorBoardImage(endpoint: PairingEndpoint, anchorId: String) async throws -> Data
}

struct PairingConfirmRequest: Codable, Equatable, Sendable {
    let pairing_code: String
    let pairing_confirm: PairingConfirmPayload
}

struct PairingConfirmPayload: Codable, Equatable, Sendable {
    let pairing_nonce: String
    let scan_device_id: String
    let scan_display_name: String
    let scan_cert_fingerprint_sha256: String
    let desktop_cert_fingerprint_sha256: String
    let confirmed_at_utc: String
}

actor PairingService {
    private let trustStore: TrustStore
    private let authorityClient: any EngineRoomAuthorityClientProtocol
    private var activeSessionCache: ClientPairingSessionCache

    init(
        trustStore: TrustStore,
        authorityClient: (any EngineRoomAuthorityClientProtocol)? = nil,
        transport: any PairingRequestTransport = URLSessionPairingRequestTransport(),
        traceparentProvider: @escaping @Sendable () -> String = { ScanTraceContext.makeTraceparent() },
        activeSessionCacheTtl: TimeInterval = 5
    ) {
        self.trustStore = trustStore
        self.authorityClient = authorityClient ?? EngineRoomAuthorityClient(
            transport: transport,
            traceparentProvider: traceparentProvider)
        activeSessionCache = ClientPairingSessionCache(ttl: activeSessionCacheTtl)
    }

    func confirmPairing(
        endpoint: PairingEndpoint,
        pairingNonce: String,
        pairingCode: String,
        scanDeviceId: String,
        scanDisplayName: String,
        scanCertFingerprintSha256: String,
        desktopCertFingerprintSha256: String
    ) async throws -> PairingConfirmResult {
        let requestBody = PairingConfirmRequest(
            pairing_code: pairingCode,
            pairing_confirm: PairingConfirmPayload(
                pairing_nonce: pairingNonce,
                scan_device_id: scanDeviceId,
                scan_display_name: scanDisplayName,
                scan_cert_fingerprint_sha256: scanCertFingerprintSha256,
                desktop_cert_fingerprint_sha256: desktopCertFingerprintSha256,
                confirmed_at_utc: ISO8601DateFormatter.fractional.string(from: .now)))

        let result = try await authorityClient.confirmPairing(
            endpoint: endpoint,
            requestBody: requestBody)
        activeSessionCache.invalidate(for: endpoint)
        try await trustStore.upsert(result.trust_record)
        return result
    }

    func startPairingSession(endpoint: PairingEndpoint) async throws -> PairingSessionStatusResponse {
        let response = try await authorityClient.startPairing(endpoint: endpoint)
        activeSessionCache.cache(response, for: endpoint)
        return response
    }

    func getActivePairingSession(endpoint: PairingEndpoint) async throws -> PairingSessionStatusResponse {
        if let cached = activeSessionCache.cachedSessionStatus(for: endpoint) {
            return cached
        }

        let response = try await authorityClient.getActivePairing(endpoint: endpoint)
        activeSessionCache.cache(response, for: endpoint)
        return response
    }

    func fetchCurrentPhoneAnchorSession(endpoint: PairingEndpoint) async throws -> PhoneAnchorSessionSnapshot? {
        try await authorityClient.fetchCurrentPhoneAnchorSession(endpoint: endpoint)
    }

    func fetchPhoneAnchorBoardImage(endpoint: PairingEndpoint, anchorId: String) async throws -> Data {
        try await authorityClient.fetchPhoneAnchorBoardImage(endpoint: endpoint, anchorId: anchorId)
    }
}

extension PairingService: PairingSessionClient {}
extension PairingService: PhoneAnchorClient {}

private extension ISO8601DateFormatter {
    static var fractional: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }
}
