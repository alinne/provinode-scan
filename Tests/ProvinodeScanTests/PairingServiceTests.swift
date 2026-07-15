import Foundation
import ProvinodeRoomContracts
import XCTest
@testable import ProvinodeScan

final class EngineRoomAuthorityClientTests: XCTestCase {
    func testStartPairingUsesEngineAuthorityRoute() async throws {
        let transport = StubPairingTransport { _ in
            PairingTransportResponse(
                data: Data(Self.sessionStatusJson(qrAvailable: true).utf8),
                response: Self.response(
                    path: "/engine/v1/production-space/rooms/default-room/authority/pairing/start",
                    statusCode: 200,
                    contentType: "application/json"))
        }

        let client = EngineRoomAuthorityClient(
            transport: transport,
            traceparentProvider: { Self.traceparent })

        let result = try await client.startPairing(endpoint: Self.endpoint())

        let capturedRequest = await transport.capturedRequest()
        let request = try XCTUnwrap(capturedRequest)
        let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "traceparent"), Self.traceparent)
        XCTAssertEqual(components.path, "/engine/v1/production-space/rooms/default-room/authority/pairing/start")
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "output_mode" })?.value, "safe")
        XCTAssertEqual(result.session?.desktopDeviceId, "desktop-1")
        XCTAssertEqual(result.pairingQrAvailable, true)
    }

    func testGetActivePairingUsesEngineAuthorityRoute() async throws {
        let transport = StubPairingTransport { _ in
            PairingTransportResponse(
                data: Data(Self.sessionStatusJson(qrAvailable: false).utf8),
                response: Self.response(
                    path: "/engine/v1/production-space/rooms/default-room/authority/pairing/active",
                    statusCode: 200,
                    contentType: "application/json"))
        }

        let client = EngineRoomAuthorityClient(
            transport: transport,
            traceparentProvider: { Self.traceparent })

        let result = try await client.getActivePairing(endpoint: Self.endpoint())

        let capturedRequest = await transport.capturedRequest()
        let request = try XCTUnwrap(capturedRequest)
        let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(components.path, "/engine/v1/production-space/rooms/default-room/authority/pairing/active")
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "output_mode" })?.value, "safe")
        XCTAssertNil(result.session)
        XCTAssertEqual(result.pairingQrAvailable, false)
    }

    func testConfirmPairingUsesEngineAuthorityRouteAndRequestBody() async throws {
        let transport = StubPairingTransport { _ in
            let data = try JSONEncoder().encode(
                PairingConfirmResult(
                    trust_record: Self.trustRecord(deviceId: "desktop-1")))
            return PairingTransportResponse(
                data: data,
                response: Self.response(
                    path: "/engine/v1/production-space/rooms/default-room/authority/pairing/confirm",
                    statusCode: 200,
                    contentType: "application/json"))
        }

        let client = EngineRoomAuthorityClient(
            transport: transport,
            traceparentProvider: { Self.traceparent })

        _ = try await client.confirmPairing(
            endpoint: Self.endpoint(),
            requestBody: PairingConfirmRequest(
                pairing_code: "482915",
                pairing_confirm: PairingConfirmPayload(
                    pairing_nonce: "01JNONCEABCDEFGHJKMNPQRSTV",
                    scan_device_id: "scan-1",
                    scan_display_name: "Scanner",
                    scan_cert_fingerprint_sha256: String(repeating: "b", count: 64),
                    desktop_cert_fingerprint_sha256: String(repeating: "c", count: 64),
                    confirmed_at_utc: "2099-02-28T12:00:00Z")))

        let capturedRequest = await transport.capturedRequest()
        let request = try XCTUnwrap(capturedRequest)
        let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(components.path, "/engine/v1/production-space/rooms/default-room/authority/pairing/confirm")

        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["pairing_code"] as? String, "482915")
        let confirm = try XCTUnwrap(json["pairing_confirm"] as? [String: Any])
        XCTAssertEqual(confirm["pairing_nonce"] as? String, "01JNONCEABCDEFGHJKMNPQRSTV")
        XCTAssertEqual(confirm["scan_device_id"] as? String, "scan-1")
    }

    func testImportCapturedRoomAssetUsesEngineAuthorityRoute() async throws {
        let transport = StubPairingTransport { _ in
            PairingTransportResponse(
                data: Data("{\"accepted\":true}".utf8),
                response: Self.response(
                    path: "/engine/v1/production-space/rooms/default-room/authority/captured-assets/import",
                    statusCode: 200,
                    contentType: "application/json"))
        }

        let client = EngineRoomAuthorityClient(
            transport: transport,
            traceparentProvider: { Self.traceparent })

        let result = try await client.importCapturedRoomAsset(
            endpoint: Self.endpoint(),
            contentType: "application/octet-stream",
            payload: Data("roomcapture".utf8))

        let capturedRequest = await transport.capturedRequest()
        let request = try XCTUnwrap(capturedRequest)
        let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/octet-stream")
        XCTAssertEqual(components.path, "/engine/v1/production-space/rooms/default-room/authority/captured-assets/import")
        XCTAssertEqual(result.rawResponse.statusCode, 200)
    }

    private static let traceparent = "00-0123456789abcdef0123456789abcdef-0123456789abcdef-01"
}

final class PairingServiceTests: XCTestCase {
    func testStartPairingSessionDelegatesToAuthorityClientAndCachesResponse() async throws {
        let root = Self.makeRootDirectory(name: "scan-pairing-start-delegate")
        defer { try? FileManager.default.removeItem(at: root) }

        let trustStore = try TrustStore(rootDirectory: root)
        let authorityClient = StubEngineRoomAuthorityClient(
            startResponse: Self.activeSessionStatus(qrAvailable: true))
        let service = PairingService(
            trustStore: trustStore,
            authorityClient: authorityClient,
            activeSessionCacheTtl: 30)

        let started = try await service.startPairingSession(endpoint: Self.endpoint())
        let cached = try await service.getActivePairingSession(endpoint: Self.endpoint())

        XCTAssertEqual(started.session?.desktopDeviceId, "desktop-1")
        XCTAssertEqual(cached.session?.desktopDeviceId, "desktop-1")
        let startCallCount = await authorityClient.startCallCount()
        let activeCallCount = await authorityClient.activeCallCount()
        XCTAssertEqual(startCallCount, 1)
        XCTAssertEqual(activeCallCount, 0)
    }

    func testGetActivePairingSessionReusesShortLivedCache() async throws {
        let root = Self.makeRootDirectory(name: "scan-pairing-active-cache")
        defer { try? FileManager.default.removeItem(at: root) }

        let trustStore = try TrustStore(rootDirectory: root)
        let authorityClient = StubEngineRoomAuthorityClient(
            activeResponse: Self.activeSessionStatus(qrAvailable: true))
        let service = PairingService(
            trustStore: trustStore,
            authorityClient: authorityClient,
            activeSessionCacheTtl: 30)

        _ = try await service.getActivePairingSession(endpoint: Self.endpoint())
        _ = try await service.getActivePairingSession(endpoint: Self.endpoint())

        let activeCallCount = await authorityClient.activeCallCount()
        XCTAssertEqual(activeCallCount, 1)
    }

    func testConfirmPairingDelegatesToAuthorityClientAndPersistsTrustRecord() async throws {
        let root = Self.makeRootDirectory(name: "scan-pairing-confirm-delegate")
        defer { try? FileManager.default.removeItem(at: root) }

        let trustStore = try TrustStore(rootDirectory: root)
        let authorityClient = StubEngineRoomAuthorityClient(
            confirmResponse: PairingConfirmResult(
                trust_record: Self.trustRecord(deviceId: "desktop-1")))
        let service = PairingService(
            trustStore: trustStore,
            authorityClient: authorityClient,
            activeSessionCacheTtl: 30)

        let result = try await service.confirmPairing(
            endpoint: Self.endpoint(),
            pairingNonce: "01JNONCEABCDEFGHJKMNPQRSTV",
            pairingCode: "482915",
            scanDeviceId: "scan-1",
            scanDisplayName: "Scanner",
            scanCertFingerprintSha256: String(repeating: "b", count: 64),
            desktopCertFingerprintSha256: String(repeating: "c", count: 64))

        XCTAssertEqual(result.trust_record.peer_device_id, "desktop-1")
        let confirmCallCount = await authorityClient.confirmCallCount()
        XCTAssertEqual(confirmCallCount, 1)

        let lastConfirmRequestBody = await authorityClient.lastConfirmRequestBody()
        let requestBody = try XCTUnwrap(lastConfirmRequestBody)
        XCTAssertEqual(requestBody.pairing_code, "482915")
        XCTAssertEqual(requestBody.pairing_confirm.scan_device_id, "scan-1")
        XCTAssertEqual(requestBody.pairing_confirm.pairing_nonce, "01JNONCEABCDEFGHJKMNPQRSTV")

        let persisted = await trustStore.trustedPeer(deviceId: "desktop-1")
        XCTAssertEqual(persisted?.peer_display_name, "Room Receiver")
    }

    func testConfirmPairingInvalidatesCachedSessionState() async throws {
        let root = Self.makeRootDirectory(name: "scan-pairing-confirm-invalidates")
        defer { try? FileManager.default.removeItem(at: root) }

        let trustStore = try TrustStore(rootDirectory: root)
        let authorityClient = StubEngineRoomAuthorityClient(
            activeResponse: Self.activeSessionStatus(qrAvailable: true),
            confirmResponse: PairingConfirmResult(
                trust_record: Self.trustRecord(deviceId: "desktop-1")))
        let service = PairingService(
            trustStore: trustStore,
            authorityClient: authorityClient,
            activeSessionCacheTtl: 30)

        _ = try await service.getActivePairingSession(endpoint: Self.endpoint())
        _ = try await service.confirmPairing(
            endpoint: Self.endpoint(),
            pairingNonce: "01JNONCEABCDEFGHJKMNPQRSTV",
            pairingCode: "482915",
            scanDeviceId: "scan-1",
            scanDisplayName: "Scanner",
            scanCertFingerprintSha256: String(repeating: "b", count: 64),
            desktopCertFingerprintSha256: String(repeating: "c", count: 64))
        _ = try await service.getActivePairingSession(endpoint: Self.endpoint())

        let activeCallCount = await authorityClient.activeCallCount()
        let confirmCallCount = await authorityClient.confirmCallCount()
        XCTAssertEqual(activeCallCount, 2)
        XCTAssertEqual(confirmCallCount, 1)
    }

    func testConfirmPairingSurfacesAuthorityUnavailableFromAuthorityClient() async throws {
        let root = Self.makeRootDirectory(name: "scan-pairing-confirm-authority-failure")
        defer { try? FileManager.default.removeItem(at: root) }

        let trustStore = try TrustStore(rootDirectory: root)
        let authorityClient = StubEngineRoomAuthorityClient(
            confirmError: .authorityUnavailable(
                PairingProblemDetails(
                    type: "https://linnaeus.internal/problems/pairing_authority_unavailable",
                    title: "Pairing authority unavailable.",
                    status: 503,
                    detail: "Desktop pairing authority is unavailable.",
                    instance: nil,
                    error: nil,
                    errorCode: "pairing_authority_unavailable",
                    message: nil,
                    recoveryHint: "Retry after the Room host reconnects to engine authority.",
                    retryable: false,
                    inFlight: true,
                    failureBundlePath: nil,
                    failureCorrelationId: nil,
                    lockoutUntilUtc: nil,
                    responseTraceparent: "00-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-bbbbbbbbbbbbbbbb-01")))
        let service = PairingService(trustStore: trustStore, authorityClient: authorityClient)

        do {
            _ = try await service.confirmPairing(
                endpoint: Self.endpoint(),
                pairingNonce: "01JNONCEABCDEFGHJKMNPQRSTV",
                pairingCode: "482915",
                scanDeviceId: "scan-1",
                scanDisplayName: "Scanner",
                scanCertFingerprintSha256: String(repeating: "b", count: 64),
                desktopCertFingerprintSha256: String(repeating: "c", count: 64))
            XCTFail("Expected authority-unavailable error.")
        } catch let error as PairingError {
            guard case let .authorityUnavailable(problem) = error else {
                return XCTFail("Expected authorityUnavailable error, got \(error)")
            }

            XCTAssertEqual(problem?.effectiveErrorCode, "pairing_authority_unavailable")
            XCTAssertTrue(error.inFlight)
            XCTAssertEqual(
                error.localizedDescription,
                "Desktop pairing authority is unavailable. Retry after the Room host reconnects to engine authority.")
        }
    }
}

private extension EngineRoomAuthorityClientTests {
    static func endpoint() -> PairingEndpoint {
        PairingServiceTests.endpoint()
    }

    static func response(
        path: String,
        statusCode: Int,
        contentType: String,
        traceparent: String? = nil
    ) -> HTTPURLResponse {
        PairingServiceTests.response(
            path: path,
            statusCode: statusCode,
            contentType: contentType,
            traceparent: traceparent)
    }

    static func trustRecord(deviceId: String) -> TrustRecord {
        PairingServiceTests.trustRecord(deviceId: deviceId)
    }

    static func sessionStatusJson(qrAvailable: Bool) -> String {
        if qrAvailable {
            return """
            {
              "output_safety_mode": "safe",
              "session": {
                "desktop_device_id": "desktop-1",
                "desktop_display_name": "Room Receiver",
                "expires_at_utc": "2099-02-28T12:00:00Z",
                "protocol_version": "1.1",
                "remaining_attempts": 4,
                "attempt_limit": 5,
                "lockout_until_utc": null
              },
              "lockout_until_utc": null,
              "pairing_qr_available": true,
              "expires_in_seconds": 60
            }
            """
        }

        return """
        {
          "output_safety_mode": "safe",
          "session": null,
          "lockout_until_utc": null,
          "pairing_qr_available": false,
          "expires_in_seconds": 0
        }
        """
    }
}

private extension PairingServiceTests {
    static func endpoint() -> PairingEndpoint {
        PairingEndpoint(
            host: "192.168.1.44",
            port: 7448,
            quicPort: 7447,
            pairingScheme: "https",
            pairingCertFingerprintSha256: String(repeating: "d", count: 64),
            displayName: "Room Receiver",
            desktopDeviceId: "desktop-1")
    }

    static func response(
        path: String,
        statusCode: Int,
        contentType: String,
        traceparent: String? = nil
    ) -> HTTPURLResponse {
        var headers = ["Content-Type": contentType]
        if let traceparent, !traceparent.isEmpty {
            headers["traceparent"] = traceparent
        }

        return HTTPURLResponse(
            url: URL(string: "https://192.168.1.44:7448\(path)")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: headers)!
    }

    static func makeRootDirectory(name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
    }

    static func trustRecord(deviceId: String) -> TrustRecord {
        TrustRecord(
            peer_device_id: deviceId,
            peer_display_name: "Room Receiver",
            peer_cert_fingerprint_sha256: String(repeating: "a", count: 64),
            created_at_utc: iso8601Now(),
            last_seen_at_utc: iso8601Now(),
            status: "trusted",
            previous_cert_fingerprints_sha256: nil)
    }

    static func activeSessionStatus(qrAvailable: Bool) -> PairingSessionStatusResponse {
        PairingSessionStatusResponse(
            outputSafetyMode: "safe",
            session: PairingSessionSummary(
                desktopDeviceId: "desktop-1",
                desktopDisplayName: "Room Receiver",
                expiresAtUtc: "2099-02-28T12:00:00Z",
                protocolVersion: "1.1",
                remainingAttempts: 5,
                attemptLimit: 5,
                lockoutUntilUtc: nil),
            lockoutUntilUtc: nil,
            pairingQrAvailable: qrAvailable,
            expiresInSeconds: 300)
    }

    static func iso8601Now() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: .now)
    }
}

private actor StubPairingTransport: PairingRequestTransport {
    private var lastRequest: URLRequest?
    private let responder: @Sendable (URLRequest) throws -> PairingTransportResponse

    init(responder: @escaping @Sendable (URLRequest) throws -> PairingTransportResponse) {
        self.responder = responder
    }

    func send(_ request: URLRequest, pinnedFingerprintSha256 _: String) async throws -> PairingTransportResponse {
        lastRequest = request
        return try responder(request)
    }

    func capturedRequest() -> URLRequest? {
        lastRequest
    }
}

private actor StubEngineRoomAuthorityClient: EngineRoomAuthorityClientProtocol {
    private let startResponse: PairingSessionStatusResponse?
    private let activeResponse: PairingSessionStatusResponse?
    private let confirmResponse: PairingConfirmResult?
    private let startError: PairingError?
    private let activeError: PairingError?
    private let confirmError: PairingError?

    private var startCalls = 0
    private var activeCalls = 0
    private var confirmCalls = 0
    private var lastConfirmRequest: PairingConfirmRequest?

    init(
        startResponse: PairingSessionStatusResponse? = nil,
        activeResponse: PairingSessionStatusResponse? = nil,
        confirmResponse: PairingConfirmResult? = nil,
        startError: PairingError? = nil,
        activeError: PairingError? = nil,
        confirmError: PairingError? = nil
    ) {
        self.startResponse = startResponse
        self.activeResponse = activeResponse
        self.confirmResponse = confirmResponse
        self.startError = startError
        self.activeError = activeError
        self.confirmError = confirmError
    }

    func startPairing(endpoint _: PairingEndpoint) async throws -> PairingSessionStatusResponse {
        startCalls += 1
        if let startError {
            throw startError
        }

        guard let startResponse else {
            throw NSError(domain: "StubEngineRoomAuthorityClient", code: 1)
        }
        return startResponse
    }

    func getActivePairing(endpoint _: PairingEndpoint) async throws -> PairingSessionStatusResponse {
        activeCalls += 1
        if let activeError {
            throw activeError
        }

        guard let activeResponse else {
            throw NSError(domain: "StubEngineRoomAuthorityClient", code: 2)
        }
        return activeResponse
    }

    func confirmPairing(
        endpoint _: PairingEndpoint,
        requestBody: PairingConfirmRequest
    ) async throws -> PairingConfirmResult {
        confirmCalls += 1
        lastConfirmRequest = requestBody
        if let confirmError {
            throw confirmError
        }

        guard let confirmResponse else {
            throw NSError(domain: "StubEngineRoomAuthorityClient", code: 3)
        }
        return confirmResponse
    }

    func importCapturedRoomAsset(
        endpoint _: PairingEndpoint,
        contentType _: String,
        payload _: Data
    ) async throws -> EngineRoomAuthorityImportResponse {
        throw NSError(domain: "StubEngineRoomAuthorityClient", code: 4)
    }

    func fetchCurrentPhoneAnchorSession(endpoint _: PairingEndpoint) async throws -> PhoneAnchorSessionSnapshot? {
        nil
    }

    func fetchPhoneAnchorBoardImage(endpoint _: PairingEndpoint, anchorId _: String) async throws -> Data {
        throw NSError(domain: "StubEngineRoomAuthorityClient", code: 5)
    }

    func startCallCount() -> Int {
        startCalls
    }

    func activeCallCount() -> Int {
        activeCalls
    }

    func confirmCallCount() -> Int {
        confirmCalls
    }

    func lastConfirmRequestBody() -> PairingConfirmRequest? {
        lastConfirmRequest
    }
}
