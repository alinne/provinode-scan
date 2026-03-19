import Foundation
import ProvinodeRoomContracts
import XCTest
@testable import ProvinodeScan

final class PairingServiceTests: XCTestCase {
    func testStartPairingSessionSendsTraceparentAndDecodesSafeSession() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("scan-pairing-start-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let trustStore = try TrustStore(rootDirectory: root)
        let transport = StubPairingTransport { _ in
            let body = """
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

            return PairingTransportResponse(
                data: Data(body.utf8),
                response: Self.response(
                    statusCode: 200,
                    contentType: "application/json",
                    traceparent: "00-11111111111111111111111111111111-2222222222222222-01"))
        }

        let traceparent = "00-0123456789abcdef0123456789abcdef-0123456789abcdef-01"
        let service = PairingService(
            trustStore: trustStore,
            transport: transport,
            traceparentProvider: { traceparent })

        let result = try await service.startPairingSession(endpoint: Self.endpoint())

        let capturedRequest = await transport.capturedRequest()
        let request = try XCTUnwrap(capturedRequest)
        let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json, application/problem+json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "traceparent"), traceparent)
        XCTAssertEqual(components.path, "/pairing/start")
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "output_mode" })?.value, "safe")
        XCTAssertEqual(result.outputSafetyMode, "safe")
        XCTAssertEqual(result.session?.desktopDeviceId, "desktop-1")
        XCTAssertEqual(result.session?.remainingAttempts, 4)
        XCTAssertEqual(result.pairingQrAvailable, true)
        XCTAssertEqual(
            result.responseTraceparent,
            "00-11111111111111111111111111111111-2222222222222222-01")
    }

    func testGetActivePairingSessionSendsTraceparentAndDecodesInactiveState() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("scan-pairing-active-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let trustStore = try TrustStore(rootDirectory: root)
        let transport = StubPairingTransport { _ in
            let body = """
            {
              "output_safety_mode": "safe",
              "session": null,
              "lockout_until_utc": null,
              "pairing_qr_available": false,
              "expires_in_seconds": 0
            }
            """

            return PairingTransportResponse(
                data: Data(body.utf8),
                response: Self.response(statusCode: 200, contentType: "application/json"))
        }

        let traceparent = "00-fedcba9876543210fedcba9876543210-0123456789abcdef-01"
        let service = PairingService(
            trustStore: trustStore,
            transport: transport,
            traceparentProvider: { traceparent })

        let result = try await service.getActivePairingSession(endpoint: Self.endpoint())

        let capturedRequest = await transport.capturedRequest()
        let request = try XCTUnwrap(capturedRequest)
        let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "traceparent"), traceparent)
        XCTAssertEqual(components.path, "/pairing/active")
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "output_mode" })?.value, "safe")
        XCTAssertNil(result.session)
        XCTAssertEqual(result.pairingQrAvailable, false)
        XCTAssertEqual(result.expiresInSeconds, 0)
    }

    func testStartPairingSessionMapsAuthorityUnavailableProblemDetails() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("scan-pairing-start-authority-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let trustStore = try TrustStore(rootDirectory: root)
        let transport = StubPairingTransport { _ in
            let body = """
            {
              "type": "https://linnaeus.internal/problems/pairing_authority_unavailable",
              "title": "Pairing authority unavailable.",
              "status": 503,
              "detail": "Room pairing authority is unavailable.",
              "error_code": "pairing_authority_unavailable",
              "recovery_hint": "Retry after the Room host reconnects to engine authority.",
              "retryable": false,
              "in_flight": true
            }
            """

            return PairingTransportResponse(
                data: Data(body.utf8),
                response: Self.response(statusCode: 503, contentType: "application/problem+json"))
        }

        let service = PairingService(trustStore: trustStore, transport: transport)

        do {
            _ = try await service.startPairingSession(endpoint: Self.endpoint())
            XCTFail("Expected start pairing to fail with an authority-unavailable problem.")
        } catch let error as PairingError {
            guard case let .authorityUnavailable(problem) = error else {
                return XCTFail("Expected authorityUnavailable error, got \(error)")
            }

            XCTAssertEqual(problem?.effectiveErrorCode, "pairing_authority_unavailable")
            XCTAssertTrue(error.inFlight)
            XCTAssertEqual(
                error.localizedDescription,
                "Room pairing authority is unavailable. Retry after the Room host reconnects to engine authority.")
        }
    }

    func testGetActivePairingSessionMapsLockedOutProblemDetails() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("scan-pairing-active-locked-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let trustStore = try TrustStore(rootDirectory: root)
        let transport = StubPairingTransport { _ in
            let body = """
            {
              "type": "https://linnaeus.internal/problems/pairing_locked",
              "title": "Pairing is temporarily locked.",
              "status": 429,
              "detail": "Repeated invalid confirmation attempts temporarily locked pairing.",
              "error_code": "pairing_locked",
              "retryable": true,
              "lockout_until_utc": "2099-02-28T12:00:00Z"
            }
            """

            return PairingTransportResponse(
                data: Data(body.utf8),
                response: Self.response(statusCode: 429, contentType: "application/problem+json"))
        }

        let service = PairingService(trustStore: trustStore, transport: transport)

        do {
            _ = try await service.getActivePairingSession(endpoint: Self.endpoint())
            XCTFail("Expected active pairing session query to fail with a lockout problem.")
        } catch let error as PairingError {
            guard case let .lockedOut(problem) = error else {
                return XCTFail("Expected lockedOut error, got \(error)")
            }

            XCTAssertEqual(problem?.effectiveErrorCode, "pairing_locked")
            XCTAssertEqual(problem?.lockoutUntilUtc, "2099-02-28T12:00:00Z")
            XCTAssertTrue(error.retryable)
        }
    }

    func testGetActivePairingSessionReusesShortLivedCache() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("scan-pairing-active-cache-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let trustStore = try TrustStore(rootDirectory: root)
        let transport = StubPairingTransport { _ in
            let body = """
            {
              "output_safety_mode": "safe",
              "session": {
                "desktop_device_id": "desktop-1",
                "desktop_display_name": "Room Receiver",
                "expires_at_utc": "2099-02-28T12:00:00Z",
                "protocol_version": "1.1",
                "remaining_attempts": 5,
                "attempt_limit": 5,
                "lockout_until_utc": null
              },
              "lockout_until_utc": null,
              "pairing_qr_available": true,
              "expires_in_seconds": 300
            }
            """

            return PairingTransportResponse(
                data: Data(body.utf8),
                response: Self.response(statusCode: 200, contentType: "application/json"))
        }

        let service = PairingService(trustStore: trustStore, transport: transport, activeSessionCacheTtl: 30)

        _ = try await service.getActivePairingSession(endpoint: Self.endpoint())
        _ = try await service.getActivePairingSession(endpoint: Self.endpoint())
        let sendCount = await transport.sendCount()

        XCTAssertEqual(sendCount, 1)
    }

    func testConfirmPairingInvalidatesCachedSessionState() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("scan-pairing-active-invalidate-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let trustStore = try TrustStore(rootDirectory: root)
        let activeBody = """
        {
          "output_safety_mode": "safe",
          "session": {
            "desktop_device_id": "desktop-1",
            "desktop_display_name": "Room Receiver",
            "expires_at_utc": "2099-02-28T12:00:00Z",
            "protocol_version": "1.1",
            "remaining_attempts": 5,
            "attempt_limit": 5,
            "lockout_until_utc": null
          },
          "lockout_until_utc": null,
          "pairing_qr_available": true,
          "expires_in_seconds": 300
        }
        """
        let transport = StubPairingTransport { request in
            switch request.url?.path {
            case "/pairing/active":
                return PairingTransportResponse(
                    data: Data(activeBody.utf8),
                    response: Self.response(statusCode: 200, contentType: "application/json"))
            case "/pairing/confirm":
                let record = TrustRecord(
                    peer_device_id: "desktop-1",
                    peer_display_name: "Room Receiver",
                    peer_cert_fingerprint_sha256: String(repeating: "a", count: 64),
                    created_at_utc: Self.iso8601Now(),
                    last_seen_at_utc: Self.iso8601Now(),
                    status: "trusted",
                    previous_cert_fingerprints_sha256: nil)
                let data = try JSONEncoder().encode(PairingConfirmResult(trust_record: record))
                return PairingTransportResponse(
                    data: data,
                    response: Self.response(statusCode: 200, contentType: "application/json"))
            default:
                throw PairingError.serverRejected(nil)
            }
        }

        let service = PairingService(trustStore: trustStore, transport: transport, activeSessionCacheTtl: 30)

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
        let sendCount = await transport.sendCount()

        XCTAssertEqual(sendCount, 3)
    }

    func testConfirmPairingSendsTraceparentAndPersistsTrustRecord() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("scan-pairing-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let trustStore = try TrustStore(rootDirectory: root)
        let transport = StubPairingTransport { _ in
            let record = TrustRecord(
                peer_device_id: "desktop-1",
                peer_display_name: "Room Receiver",
                peer_cert_fingerprint_sha256: String(repeating: "a", count: 64),
                created_at_utc: Self.iso8601Now(),
                last_seen_at_utc: Self.iso8601Now(),
                status: "trusted",
                previous_cert_fingerprints_sha256: nil)
            let data = try JSONEncoder().encode(PairingConfirmResult(trust_record: record))
            return PairingTransportResponse(
                data: data,
                response: Self.response(statusCode: 200, contentType: "application/json"))
        }

        let traceparent = "00-0123456789abcdef0123456789abcdef-0123456789abcdef-01"
        let service = PairingService(
            trustStore: trustStore,
            transport: transport,
            traceparentProvider: { traceparent })

        let result = try await service.confirmPairing(
            endpoint: Self.endpoint(),
            pairingNonce: "01JNONCEABCDEFGHJKMNPQRSTV",
            pairingCode: "482915",
            scanDeviceId: "scan-1",
            scanDisplayName: "Scanner",
            scanCertFingerprintSha256: String(repeating: "b", count: 64),
            desktopCertFingerprintSha256: String(repeating: "c", count: 64))

        let capturedRequest = await transport.capturedRequest()
        let request = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(request.value(forHTTPHeaderField: "traceparent"), traceparent)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json, application/problem+json")
        XCTAssertEqual(result.trust_record.peer_device_id, "desktop-1")

        let persisted = await trustStore.trustedPeer(deviceId: "desktop-1")
        XCTAssertEqual(persisted?.peer_display_name, "Room Receiver")
    }

    func testConfirmPairingDecodesProblemDetailsAndMapsLockedOutFailure() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("scan-pairing-locked-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let trustStore = try TrustStore(rootDirectory: root)
        let transport = StubPairingTransport { _ in
            let body = """
            {
              "type": "https://linnaeus.internal/problems/pairing_locked",
              "title": "Pairing is temporarily locked.",
              "status": 429,
              "detail": "Repeated invalid confirmation attempts temporarily locked pairing.",
              "error": "pairing_locked",
              "error_code": "pairing_locked",
              "retryable": true,
              "lockout_until_utc": "2099-02-28T12:00:00Z"
            }
            """

            return PairingTransportResponse(
                data: Data(body.utf8),
                response: Self.response(statusCode: 429, contentType: "application/problem+json"))
        }

        let service = PairingService(trustStore: trustStore, transport: transport)

        do {
            _ = try await service.confirmPairing(
                endpoint: Self.endpoint(),
                pairingNonce: "01JNONCEABCDEFGHJKMNPQRSTV",
                pairingCode: "482915",
                scanDeviceId: "scan-1",
                scanDisplayName: "Scanner",
                scanCertFingerprintSha256: String(repeating: "b", count: 64),
                desktopCertFingerprintSha256: String(repeating: "c", count: 64))
            XCTFail("Expected pairing to fail with a lockout problem.")
        } catch let error as PairingError {
            guard case let .lockedOut(problem) = error else {
                return XCTFail("Expected lockedOut error, got \(error)")
            }

            XCTAssertEqual(problem?.effectiveErrorCode, "pairing_locked")
            XCTAssertEqual(problem?.retryable, true)
            XCTAssertEqual(problem?.lockoutUntilUtc, "2099-02-28T12:00:00Z")
            XCTAssertEqual(
                error.localizedDescription,
                "Repeated invalid confirmation attempts temporarily locked pairing. Retry after 2099-02-28T12:00:00Z.")
        }
    }

    func testConfirmPairingMapsMissingSessionToFailClosedError() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("scan-pairing-missing-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let trustStore = try TrustStore(rootDirectory: root)
        let transport = StubPairingTransport { _ in
            let body = """
            {
              "type": "https://linnaeus.internal/problems/pairing_session_not_found",
              "title": "No active pairing session.",
              "status": 404,
              "detail": "The pairing session is missing or already completed.",
              "error_code": "pairing_session_not_found"
            }
            """

            return PairingTransportResponse(
                data: Data(body.utf8),
                response: Self.response(statusCode: 404, contentType: "application/problem+json"))
        }

        let service = PairingService(trustStore: trustStore, transport: transport)

        do {
            _ = try await service.confirmPairing(
                endpoint: Self.endpoint(),
                pairingNonce: "01JNONCEABCDEFGHJKMNPQRSTV",
                pairingCode: "482915",
                scanDeviceId: "scan-1",
                scanDisplayName: "Scanner",
                scanCertFingerprintSha256: String(repeating: "b", count: 64),
                desktopCertFingerprintSha256: String(repeating: "c", count: 64))
            XCTFail("Expected pairing to fail with a missing-session problem.")
        } catch let error as PairingError {
            guard case let .sessionUnavailable(problem) = error else {
                return XCTFail("Expected sessionUnavailable error, got \(error)")
            }

            XCTAssertEqual(problem?.effectiveErrorCode, "pairing_session_not_found")
            XCTAssertEqual(error.localizedDescription, "The pairing session is missing or already completed.")
        }
    }

    func testConfirmPairingMapsAuthorityUnavailableAndPreservesRecoveryMetadata() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("scan-pairing-authority-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let trustStore = try TrustStore(rootDirectory: root)
        let transport = StubPairingTransport { _ in
            let body = """
            {
              "type": "https://linnaeus.internal/problems/pairing_authority_unavailable",
              "title": "Pairing authority unavailable.",
              "status": 503,
              "detail": "Desktop pairing authority is unavailable.",
              "error_code": "pairing_authority_unavailable",
              "recovery_hint": "Retry after the Room host reconnects to engine authority.",
              "retryable": false,
              "in_flight": true
            }
            """

            return PairingTransportResponse(
                data: Data(body.utf8),
                response: Self.response(
                    statusCode: 503,
                    contentType: "application/problem+json",
                    traceparent: "00-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-bbbbbbbbbbbbbbbb-01"))
        }

        let service = PairingService(trustStore: trustStore, transport: transport)

        do {
            _ = try await service.confirmPairing(
                endpoint: Self.endpoint(),
                pairingNonce: "01JNONCEABCDEFGHJKMNPQRSTV",
                pairingCode: "482915",
                scanDeviceId: "scan-1",
                scanDisplayName: "Scanner",
                scanCertFingerprintSha256: String(repeating: "b", count: 64),
                desktopCertFingerprintSha256: String(repeating: "c", count: 64))
            XCTFail("Expected pairing to fail with an authority-unavailable problem.")
        } catch let error as PairingError {
            guard case let .authorityUnavailable(problem) = error else {
                return XCTFail("Expected authorityUnavailable error, got \(error)")
            }

            XCTAssertEqual(problem?.effectiveErrorCode, "pairing_authority_unavailable")
            XCTAssertEqual(problem?.recoveryHint, "Retry after the Room host reconnects to engine authority.")
            XCTAssertEqual(problem?.inFlight, true)
            XCTAssertEqual(
                problem?.responseTraceparent,
                "00-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-bbbbbbbbbbbbbbbb-01")
            XCTAssertFalse(error.retryable)
            XCTAssertTrue(error.inFlight)
            XCTAssertEqual(error.recoveryHint, "Retry after the Room host reconnects to engine authority.")
            XCTAssertEqual(
                error.diagnosticReference,
                "trace 00-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-bbbbbbbbbbbbbbbb-01")
            XCTAssertEqual(
                error.localizedDescription,
                "Desktop pairing authority is unavailable. Retry after the Room host reconnects to engine authority.")
        }
    }

    func testConfirmPairingMapsAttemptLimitReachedSeparatelyFromLockout() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("scan-pairing-attempt-limit-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let trustStore = try TrustStore(rootDirectory: root)
        let transport = StubPairingTransport { _ in
            let body = """
            {
              "type": "https://linnaeus.internal/problems/pairing_attempt_limit_reached",
              "title": "Pairing attempt limit reached.",
              "status": 429,
              "detail": "Too many invalid pairing attempts were submitted for the active session.",
              "error_code": "pairing_attempt_limit_reached",
              "recovery_hint": "Wait for the lockout window to expire or start a fresh pairing session.",
              "retryable": true,
              "lockout_until_utc": "2099-03-01T12:00:00Z"
            }
            """

            return PairingTransportResponse(
                data: Data(body.utf8),
                response: Self.response(statusCode: 429, contentType: "application/problem+json"))
        }

        let service = PairingService(trustStore: trustStore, transport: transport)

        do {
            _ = try await service.confirmPairing(
                endpoint: Self.endpoint(),
                pairingNonce: "01JNONCEABCDEFGHJKMNPQRSTV",
                pairingCode: "482915",
                scanDeviceId: "scan-1",
                scanDisplayName: "Scanner",
                scanCertFingerprintSha256: String(repeating: "b", count: 64),
                desktopCertFingerprintSha256: String(repeating: "c", count: 64))
            XCTFail("Expected pairing to fail with an attempt-limit problem.")
        } catch let error as PairingError {
            guard case let .attemptLimitReached(problem) = error else {
                return XCTFail("Expected attemptLimitReached error, got \(error)")
            }

            XCTAssertEqual(problem?.effectiveErrorCode, "pairing_attempt_limit_reached")
            XCTAssertEqual(problem?.retryable, true)
            XCTAssertEqual(problem?.lockoutUntilUtc, "2099-03-01T12:00:00Z")
            XCTAssertEqual(
                error.localizedDescription,
                "Too many invalid pairing attempts were submitted for the active session. Wait for the lockout window to expire or start a fresh pairing session.")
        }
    }

    private static func endpoint() -> PairingEndpoint {
        PairingEndpoint(
            host: "192.168.1.44",
            port: 7448,
            quicPort: 7447,
            pairingScheme: "https",
            pairingCertFingerprintSha256: String(repeating: "d", count: 64),
            displayName: "Room Receiver",
            desktopDeviceId: "desktop-1")
    }

    private static func response(
        statusCode: Int,
        contentType: String,
        traceparent: String? = nil
    ) -> HTTPURLResponse {
        var headers = ["Content-Type": contentType]
        if let traceparent, !traceparent.isEmpty {
            headers["traceparent"] = traceparent
        }

        return HTTPURLResponse(
            url: URL(string: "https://192.168.1.44:7448/pairing/confirm")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: headers)!
    }

    private static func iso8601Now() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: .now)
    }
}

private actor StubPairingTransport: PairingRequestTransport {
    private var lastRequest: URLRequest?
    private var requestCount = 0
    private let responder: @Sendable (URLRequest) throws -> PairingTransportResponse

    init(responder: @escaping @Sendable (URLRequest) throws -> PairingTransportResponse) {
        self.responder = responder
    }

    func send(_ request: URLRequest, pinnedFingerprintSha256 _: String) async throws -> PairingTransportResponse {
        lastRequest = request
        requestCount += 1
        return try responder(request)
    }

    func capturedRequest() -> URLRequest? {
        lastRequest
    }

    func sendCount() -> Int {
        requestCount
    }
}
