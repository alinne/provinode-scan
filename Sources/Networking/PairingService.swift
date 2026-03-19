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

struct PairingProblemDetails: Codable, Equatable, Sendable {
    let type: String?
    let title: String?
    let status: Int?
    let detail: String?
    let instance: String?
    let error: String?
    let errorCode: String?
    let message: String?
    let recoveryHint: String?
    let retryable: Bool?
    let inFlight: Bool?
    let failureBundlePath: String?
    let failureCorrelationId: String?
    let lockoutUntilUtc: String?
    var responseTraceparent: String? = nil

    enum CodingKeys: String, CodingKey {
        case type
        case title
        case status
        case detail
        case instance
        case error
        case errorCode = "error_code"
        case message
        case recoveryHint = "recovery_hint"
        case retryable
        case inFlight = "in_flight"
        case failureBundlePath = "failure_bundle_path"
        case failureCorrelationId = "failure_correlation_id"
        case lockoutUntilUtc = "lockout_until_utc"
    }

    init(
        type: String?,
        title: String?,
        status: Int?,
        detail: String?,
        instance: String?,
        error: String?,
        errorCode: String?,
        message: String?,
        recoveryHint: String?,
        retryable: Bool?,
        inFlight: Bool?,
        failureBundlePath: String?,
        failureCorrelationId: String?,
        lockoutUntilUtc: String?,
        responseTraceparent: String? = nil
    ) {
        self.type = type
        self.title = title
        self.status = status
        self.detail = detail
        self.instance = instance
        self.error = error
        self.errorCode = errorCode
        self.message = message
        self.recoveryHint = recoveryHint
        self.retryable = retryable
        self.inFlight = inFlight
        self.failureBundlePath = failureBundlePath
        self.failureCorrelationId = failureCorrelationId
        self.lockoutUntilUtc = lockoutUntilUtc
        self.responseTraceparent = responseTraceparent
    }

    var effectiveErrorCode: String? {
        if let errorCode, !errorCode.isEmpty {
            return errorCode
        }

        if let error, !error.isEmpty {
            return error
        }

        return nil
    }

    var preferredDescription: String? {
        if let detail, !detail.isEmpty {
            return detail
        }

        if let title, !title.isEmpty {
            return title
        }

        if let message, !message.isEmpty {
            return message
        }

        return nil
    }

    var preferredRecoveryHint: String? {
        guard let recoveryHint, !recoveryHint.isEmpty else {
            return nil
        }

        return recoveryHint
    }

    var diagnosticReference: String? {
        if let failureCorrelationId, !failureCorrelationId.isEmpty {
            return "reference \(failureCorrelationId)"
        }

        guard let responseTraceparent, !responseTraceparent.isEmpty else {
            return nil
        }

        return "trace \(responseTraceparent)"
    }

    func withResponseTraceparent(_ value: String?) -> PairingProblemDetails {
        PairingProblemDetails(
            type: type,
            title: title,
            status: status,
            detail: detail,
            instance: instance,
            error: error,
            errorCode: errorCode,
            message: message,
            recoveryHint: recoveryHint,
            retryable: retryable,
            inFlight: inFlight,
            failureBundlePath: failureBundlePath,
            failureCorrelationId: failureCorrelationId,
            lockoutUntilUtc: lockoutUntilUtc,
            responseTraceparent: value)
    }
}

enum PairingError: Error {
    case untrustedEndpoint
    case invalidCode(PairingProblemDetails?)
    case expired(PairingProblemDetails?)
    case attemptLimitReached(PairingProblemDetails?)
    case lockedOut(PairingProblemDetails?)
    case sessionUnavailable(PairingProblemDetails?)
    case authorityUnavailable(PairingProblemDetails?)
    case serverRejected(PairingProblemDetails?)

    var problemDetails: PairingProblemDetails? {
        switch self {
        case .untrustedEndpoint:
            return nil
        case let .invalidCode(problem),
             let .expired(problem),
             let .attemptLimitReached(problem),
             let .lockedOut(problem),
             let .sessionUnavailable(problem),
             let .authorityUnavailable(problem),
             let .serverRejected(problem):
            return problem
        }
    }

    var retryable: Bool {
        problemDetails?.retryable ?? false
    }

    var inFlight: Bool {
        problemDetails?.inFlight ?? false
    }

    var recoveryHint: String? {
        problemDetails?.preferredRecoveryHint
    }

    var diagnosticReference: String? {
        problemDetails?.diagnosticReference
    }
}

protocol PairingSessionClient: Sendable {
    func confirmPairing(
        endpoint: PairingEndpoint,
        pairingNonce: String,
        pairingCode: String,
        scanDeviceId: String,
        scanDisplayName: String,
        scanCertFingerprintSha256: String,
        desktopCertFingerprintSha256: String
    ) async throws -> PairingConfirmResult

    func startPairingSession(endpoint: PairingEndpoint) async throws -> PairingSessionStatusResponse

    func getActivePairingSession(endpoint: PairingEndpoint) async throws -> PairingSessionStatusResponse
}

protocol PairingRequestTransport: Sendable {
    func send(_ request: URLRequest, pinnedFingerprintSha256: String) async throws -> PairingTransportResponse
}

struct PairingTransportResponse: Sendable {
    let data: Data
    let response: HTTPURLResponse
}

struct PairingSessionSummary: Codable, Equatable, Sendable {
    let desktopDeviceId: String
    let desktopDisplayName: String
    let expiresAtUtc: String
    let protocolVersion: String
    let remainingAttempts: Int
    let attemptLimit: Int
    let lockoutUntilUtc: String?

    enum CodingKeys: String, CodingKey {
        case desktopDeviceId = "desktop_device_id"
        case desktopDisplayName = "desktop_display_name"
        case expiresAtUtc = "expires_at_utc"
        case protocolVersion = "protocol_version"
        case remainingAttempts = "remaining_attempts"
        case attemptLimit = "attempt_limit"
        case lockoutUntilUtc = "lockout_until_utc"
    }
}

struct PairingSessionStatusResponse: Codable, Equatable, Sendable {
    let outputSafetyMode: String?
    let session: PairingSessionSummary?
    let lockoutUntilUtc: String?
    let pairingQrAvailable: Bool?
    let expiresInSeconds: Int?
    var responseTraceparent: String? = nil

    enum CodingKeys: String, CodingKey {
        case outputSafetyMode = "output_safety_mode"
        case session
        case lockoutUntilUtc = "lockout_until_utc"
        case pairingQrAvailable = "pairing_qr_available"
        case expiresInSeconds = "expires_in_seconds"
    }

    func withResponseTraceparent(_ value: String?) -> PairingSessionStatusResponse {
        PairingSessionStatusResponse(
            outputSafetyMode: outputSafetyMode,
            session: session,
            lockoutUntilUtc: lockoutUntilUtc,
            pairingQrAvailable: pairingQrAvailable,
            expiresInSeconds: expiresInSeconds,
            responseTraceparent: value)
    }
}

actor PairingService {
    private struct CachedSessionStatus: Sendable {
        let response: PairingSessionStatusResponse
        let expiresAt: Date
    }

    private let trustStore: TrustStore
    private let transport: any PairingRequestTransport
    private let traceparentProvider: @Sendable () -> String
    private let activeSessionCacheTtl: TimeInterval
    private var activeSessionCache: [String: CachedSessionStatus] = [:]

    init(
        trustStore: TrustStore,
        transport: any PairingRequestTransport = URLSessionPairingRequestTransport(),
        traceparentProvider: @escaping @Sendable () -> String = { ScanTraceContext.makeTraceparent() },
        activeSessionCacheTtl: TimeInterval = 5
    ) {
        self.trustStore = trustStore
        self.transport = transport
        self.traceparentProvider = traceparentProvider
        self.activeSessionCacheTtl = max(0, activeSessionCacheTtl)
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
        let pinnedFingerprint = try validatedPinnedFingerprint(from: endpoint)

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

        var request = try makeRequest(
            endpoint: endpoint,
            method: "POST",
            path: "/pairing/confirm")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = requestBody

        let transportResponse = try await transport.send(request, pinnedFingerprintSha256: pinnedFingerprint)
        let data = transportResponse.data
        let httpResponse = transportResponse.response
        let problemDetails = Self.decodeProblemDetails(from: data, response: httpResponse)

        switch httpResponse.statusCode {
        case 200:
            if let result = try? JSONDecoder().decode(PairingConfirmResult.self, from: data) {
                invalidateCachedSessionStatus(for: endpoint)
                try await trustStore.upsert(result.trust_record)
                return result
            }

            // Backward-compatible decode path for receivers that still return bare TrustRecord.
            let record = try JSONDecoder().decode(TrustRecord.self, from: data)
            invalidateCachedSessionStatus(for: endpoint)
            try await trustStore.upsert(record)
            return PairingConfirmResult(trust_record: record, scan_client_mtls: nil)
        case 401, 404, 410, 429, 502, 503:
            throw Self.mapFailure(statusCode: httpResponse.statusCode, problemDetails: problemDetails)
        default:
            throw PairingError.serverRejected(problemDetails)
        }
    }

    func startPairingSession(endpoint: PairingEndpoint) async throws -> PairingSessionStatusResponse {
        let transportResponse = try await sendSessionRequest(
            endpoint: endpoint,
            method: "POST",
            path: "/pairing/start",
            outputSafetyMode: "safe")
        let response = try decodeSessionStatusResponse(from: transportResponse)
        cacheSessionStatus(response, for: endpoint)
        return response
    }

    func getActivePairingSession(endpoint: PairingEndpoint) async throws -> PairingSessionStatusResponse {
        if let cached = cachedSessionStatus(for: endpoint) {
            return cached
        }

        let transportResponse = try await sendSessionRequest(
            endpoint: endpoint,
            method: "GET",
            path: "/pairing/active",
            outputSafetyMode: "safe")
        let response = try decodeSessionStatusResponse(from: transportResponse)
        cacheSessionStatus(response, for: endpoint)
        return response
    }
}

extension PairingService: PairingSessionClient {}

extension PairingError: LocalizedError {
    var errorDescription: String? {
        if let preferred = problemDetails?.preferredDescription {
            let withRecoveryHint: (String) -> String = { base in
                guard let recoveryHint = problemDetails?.preferredRecoveryHint,
                      !recoveryHint.isEmpty,
                      !base.localizedCaseInsensitiveContains(recoveryHint)
                else {
                    return base
                }

                return "\(base) \(recoveryHint)"
            }

            if case let .lockedOut(problem) = self,
               let lockoutUntil = problem?.lockoutUntilUtc,
               !lockoutUntil.isEmpty
            {
                return withRecoveryHint("\(preferred) Retry after \(lockoutUntil).")
            }

            return withRecoveryHint(preferred)
        }

        switch self {
        case .untrustedEndpoint:
            return "Receiver endpoint is missing a trusted pairing certificate fingerprint."
        case .invalidCode:
            return "Pairing code or nonce is invalid."
        case .expired:
            return "Pairing session has expired."
        case .attemptLimitReached:
            return "Pairing attempt limit has been reached."
        case .lockedOut:
            return "Pairing is temporarily locked due to repeated invalid attempts."
        case .sessionUnavailable:
            return "No active pairing session is available."
        case .authorityUnavailable:
            return "Room pairing authority is unavailable right now."
        case .serverRejected:
            return "Desktop receiver rejected pairing request."
        }
    }
}

private extension PairingService {
    func cacheSessionStatus(_ response: PairingSessionStatusResponse, for endpoint: PairingEndpoint) {
        guard activeSessionCacheTtl > 0 else {
            return
        }

        activeSessionCache[cacheKey(for: endpoint)] = CachedSessionStatus(
            response: response,
            expiresAt: Date().addingTimeInterval(activeSessionCacheTtl))
    }

    func cachedSessionStatus(for endpoint: PairingEndpoint) -> PairingSessionStatusResponse? {
        let key = cacheKey(for: endpoint)
        guard let cached = activeSessionCache[key] else {
            return nil
        }

        guard cached.expiresAt > Date() else {
            activeSessionCache.removeValue(forKey: key)
            return nil
        }

        return cached.response
    }

    func invalidateCachedSessionStatus(for endpoint: PairingEndpoint) {
        activeSessionCache.removeValue(forKey: cacheKey(for: endpoint))
    }

    func cacheKey(for endpoint: PairingEndpoint) -> String {
        [
            endpoint.pairingScheme.lowercased(),
            endpoint.host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            String(endpoint.port),
            endpoint.pairingCertFingerprintSha256?.lowercased() ?? ""
        ].joined(separator: "|")
    }

    func sendSessionRequest(
        endpoint: PairingEndpoint,
        method: String,
        path: String,
        outputSafetyMode: String
    ) async throws -> PairingTransportResponse {
        let request = try makeRequest(
            endpoint: endpoint,
            method: method,
            path: path,
            outputSafetyMode: outputSafetyMode)
        return try await transport.send(request, pinnedFingerprintSha256: validatedPinnedFingerprint(from: endpoint))
    }

    func makeRequest(
        endpoint: PairingEndpoint,
        method: String,
        path: String,
        outputSafetyMode: String? = nil
    ) throws -> URLRequest {
        let url = try buildURL(endpoint: endpoint, path: path, outputSafetyMode: outputSafetyMode)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json, application/problem+json", forHTTPHeaderField: "Accept")
        request.setValue(traceparentProvider(), forHTTPHeaderField: "traceparent")
        return request
    }

    func buildURL(
        endpoint: PairingEndpoint,
        path: String,
        outputSafetyMode: String? = nil
    ) throws -> URL {
        let baseHost = endpoint.host.trimmingCharacters(in: .whitespacesAndNewlines)
        let hostWithScheme: String
        if baseHost.hasPrefix("http://") || baseHost.hasPrefix("https://") {
            hostWithScheme = baseHost
        } else {
            hostWithScheme = "\(endpoint.pairingScheme)://\(baseHost)"
        }

        guard var components = URLComponents(string: hostWithScheme) else {
            throw PairingError.serverRejected(nil)
        }

        components.port = endpoint.port
        components.path = path
        if let outputSafetyMode, !outputSafetyMode.isEmpty {
            components.queryItems = [
                URLQueryItem(name: "output_mode", value: outputSafetyMode)
            ]
        }

        guard let url = components.url else {
            throw PairingError.serverRejected(nil)
        }

        return url
    }

    func validatedPinnedFingerprint(from endpoint: PairingEndpoint) throws -> String {
        guard let pinnedFingerprint = endpoint.pairingCertFingerprintSha256,
              Self.isValidSha256Hex(pinnedFingerprint)
        else {
            throw PairingError.untrustedEndpoint
        }

        return pinnedFingerprint
    }

    func decodeSessionStatusResponse(from transportResponse: PairingTransportResponse) throws -> PairingSessionStatusResponse {
        let data = transportResponse.data
        let httpResponse = transportResponse.response
        let problemDetails = Self.decodeProblemDetails(from: data, response: httpResponse)

        switch httpResponse.statusCode {
        case 200:
            guard let payload = try? JSONDecoder().decode(PairingSessionStatusResponse.self, from: data) else {
                throw PairingError.serverRejected(problemDetails)
            }

            let responseTraceparent = httpResponse.value(forHTTPHeaderField: "traceparent")?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return payload.withResponseTraceparent(responseTraceparent)
        case 401, 404, 409, 410, 429, 502, 503:
            throw Self.mapFailure(statusCode: httpResponse.statusCode, problemDetails: problemDetails)
        default:
            throw PairingError.serverRejected(problemDetails)
        }
    }

    static func isValidSha256Hex(_ value: String) -> Bool {
        guard value.count == 64 else { return false }
        return value.allSatisfy { char in
            char.isHexDigit
        }
    }

    static func decodeProblemDetails(from data: Data, response: HTTPURLResponse) -> PairingProblemDetails? {
        guard !data.isEmpty else {
            return nil
        }

        let contentType = response.value(forHTTPHeaderField: "Content-Type")?
            .lowercased() ?? ""
        guard contentType.contains("application/problem+json") || contentType.contains("application/json") else {
            return nil
        }

        guard let problem = try? JSONDecoder().decode(PairingProblemDetails.self, from: data) else {
            return nil
        }

        let responseTraceparent = response.value(forHTTPHeaderField: "traceparent")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return problem.withResponseTraceparent(responseTraceparent)
    }

    static func mapFailure(statusCode: Int, problemDetails: PairingProblemDetails?) -> PairingError {
        let errorCode = problemDetails?.effectiveErrorCode?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        switch statusCode {
        case 401:
            if errorCode == "desktop_fingerprint_mismatch" {
                return .serverRejected(problemDetails)
            }

            return .invalidCode(problemDetails)
        case 404:
            return .sessionUnavailable(problemDetails)
        case 410:
            return .expired(problemDetails)
        case 429:
            if errorCode == "pairing_attempt_limit_reached" {
                return .attemptLimitReached(problemDetails)
            }

            return .lockedOut(problemDetails)
        case 502, 503:
            return .authorityUnavailable(problemDetails)
        default:
            return .serverRejected(problemDetails)
        }
    }
}

private final class URLSessionPairingRequestTransport: PairingRequestTransport {
    func send(_ request: URLRequest, pinnedFingerprintSha256: String) async throws -> PairingTransportResponse {
        let session = URLSession(
            configuration: .ephemeral,
            delegate: PinnedTlsDelegate(expectedFingerprintSha256: pinnedFingerprintSha256),
            delegateQueue: nil)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw PairingError.serverRejected(nil)
        }

        return PairingTransportResponse(data: data, response: httpResponse)
    }
}

enum ScanTraceContext {
    static func makeTraceparent() -> String {
        let traceId = randomHex(byteCount: 16)
        let spanId = randomHex(byteCount: 8)
        return "00-\(traceId)-\(spanId)-01"
    }

    private static func randomHex(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            for index in bytes.indices {
                bytes[index] = UInt8.random(in: .min ... .max)
            }
        }

        return bytes.map { String(format: "%02x", $0) }.joined()
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
