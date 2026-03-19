import XCTest
import ProvinodeRoomContracts
@testable import ProvinodeScan

@MainActor
final class CaptureViewModelTests: XCTestCase {
    func testMakeSessionMetadataIncludesSharedSessionAndTraceKeys() {
        let metadata = CaptureViewModel.makeSessionMetadata(
            sessionId: "01JSESSIONABCDEFGHJKMNPQRS",
            traceparent: "00-0123456789abcdef0123456789abcdef-0123456789abcdef-01")

        XCTAssertEqual(metadata[RoomMetadataKeys.roomSessionId], "01JSESSIONABCDEFGHJKMNPQRS")
        XCTAssertEqual(
            metadata[RoomMetadataKeys.roomTraceparent],
            "00-0123456789abcdef0123456789abcdef-0123456789abcdef-01")
    }

    func testMakeSessionMetadataIncludesTrustedPeerKeysWhenAvailable() {
        let trustedPeer = TrustRecord(
            peer_device_id: "desktop-1",
            peer_display_name: "Room Receiver",
            peer_cert_fingerprint_sha256: String(repeating: "f", count: 64),
            created_at_utc: "2026-03-18T12:00:00Z",
            last_seen_at_utc: "2026-03-18T12:00:00Z",
            status: "trusted",
            previous_cert_fingerprints_sha256: nil)

        let metadata = CaptureViewModel.makeSessionMetadata(
            sessionId: "01JSESSIONABCDEFGHJKMNPQRS",
            traceparent: "00-0123456789abcdef0123456789abcdef-0123456789abcdef-01",
            trustedPeer: trustedPeer)

        XCTAssertEqual(metadata[RoomMetadataKeys.pairedPeerDeviceId], "desktop-1")
        XCTAssertEqual(
            metadata[RoomMetadataKeys.pairedPeerCertFingerprintSha256],
            String(repeating: "f", count: 64))
    }

    func testDescribePairingFailureFormatsAuthorityUnavailableInFlight() {
        let problem = PairingProblemDetails(
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
            responseTraceparent: "00-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-bbbbbbbbbbbbbbbb-01")

        let status = CaptureViewModel.describePairingFailure(PairingError.authorityUnavailable(problem))

        XCTAssertEqual(
            status,
            "Pairing waiting on authority: Desktop pairing authority is unavailable. Retry after the Room host reconnects to engine authority. See trace 00-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-bbbbbbbbbbbbbbbb-01.")
    }

    func testDescribePairingFailureFormatsMissingSession() {
        let problem = PairingProblemDetails(
            type: "https://linnaeus.internal/problems/pairing_session_not_found",
            title: "No active pairing session.",
            status: 404,
            detail: "The pairing session is missing or already completed.",
            instance: nil,
            error: nil,
            errorCode: "pairing_session_not_found",
            message: nil,
            recoveryHint: nil,
            retryable: false,
            inFlight: false,
            failureBundlePath: nil,
            failureCorrelationId: nil,
            lockoutUntilUtc: nil)

        let status = CaptureViewModel.describePairingFailure(PairingError.sessionUnavailable(problem))

        XCTAssertEqual(
            status,
            "Pairing session unavailable: The pairing session is missing or already completed.")
    }

    func testDescribePairingFailureFormatsAttemptLimitReached() {
        let problem = PairingProblemDetails(
            type: "https://linnaeus.internal/problems/pairing_attempt_limit_reached",
            title: "Pairing attempt limit reached.",
            status: 429,
            detail: "Too many invalid pairing attempts were submitted for the active session.",
            instance: nil,
            error: nil,
            errorCode: "pairing_attempt_limit_reached",
            message: nil,
            recoveryHint: "Wait for the lockout window to expire or start a fresh pairing session.",
            retryable: true,
            inFlight: false,
            failureBundlePath: nil,
            failureCorrelationId: nil,
            lockoutUntilUtc: "2099-03-01T12:00:00Z")

        let status = CaptureViewModel.describePairingFailure(PairingError.attemptLimitReached(problem))

        XCTAssertEqual(
            status,
            "Pairing attempts exhausted: Too many invalid pairing attempts were submitted for the active session. Wait for the lockout window to expire or start a fresh pairing session.")
    }

    func testDescribePairingFailureFormatsServerRejectedWithFailureReference() {
        let problem = PairingProblemDetails(
            type: "https://linnaeus.internal/problems/desktop_fingerprint_mismatch",
            title: "Desktop TLS fingerprint mismatch.",
            status: 401,
            detail: "Pairing confirm desktop fingerprint did not match local TLS identity.",
            instance: nil,
            error: nil,
            errorCode: "desktop_fingerprint_mismatch",
            message: nil,
            recoveryHint: "Start a new pairing session and confirm against the current QR payload.",
            retryable: false,
            inFlight: false,
            failureBundlePath: "/tmp/pairing-failure.json",
            failureCorrelationId: "bundle-123",
            lockoutUntilUtc: nil)

        let status = CaptureViewModel.describePairingFailure(PairingError.serverRejected(problem))

        XCTAssertEqual(
            status,
            "Pairing failed: Pairing confirm desktop fingerprint did not match local TLS identity. Start a new pairing session and confirm against the current QR payload. See reference bundle-123.")
    }

    func testPairStartsAuthoritySessionBeforePromptingForQrPayload() async {
        let pairingClient = StubPairingSessionClient(
            activeSessionResponse: PairingSessionStatusResponse(
                outputSafetyMode: "safe",
                session: nil,
                lockoutUntilUtc: nil,
                pairingQrAvailable: false,
                expiresInSeconds: 0),
            startSessionResponse: PairingSessionStatusResponse(
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
                pairingQrAvailable: true,
                expiresInSeconds: 300),
            confirmResult: nil)
        let viewModel = CaptureViewModel(pairingService: pairingClient)
        viewModel.manualHost = "192.168.1.44"
        viewModel.manualPairingFingerprintSha256 = String(repeating: "d", count: 64)

        await viewModel.pair()

        XCTAssertEqual(
            viewModel.status,
            "Pairing session started. Import the current QR payload, then confirm pairing.")
        let calls = await pairingClient.calls()
        XCTAssertEqual(calls, ["active", "start"])
    }

    func testPairUsesActiveAuthoritySessionBeforeConfirming() async {
        let pairingClient = StubPairingSessionClient(
            activeSessionResponse: PairingSessionStatusResponse(
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
                pairingQrAvailable: true,
                expiresInSeconds: 300),
            startSessionResponse: nil,
            confirmResult: PairingConfirmResult(
                trust_record: TrustRecord(
                    peer_device_id: "desktop-1",
                    peer_display_name: "Room Receiver",
                    peer_cert_fingerprint_sha256: String(repeating: "c", count: 64),
                    created_at_utc: "2026-03-18T12:00:00Z",
                    last_seen_at_utc: "2026-03-18T12:00:00Z",
                    status: "trusted",
                    previous_cert_fingerprints_sha256: nil),
                scan_client_mtls: nil))
        let viewModel = CaptureViewModel(pairingService: pairingClient)
        viewModel.manualHost = "192.168.1.44"
        viewModel.manualPairingFingerprintSha256 = String(repeating: "d", count: 64)
        viewModel.pairingCode = "482915"
        viewModel.pairingNonce = "01JNONCEABCDEFGHJKMNPQRSTV"

        await viewModel.pair()

        XCTAssertEqual(viewModel.status, "Paired with Room Receiver")
        let calls = await pairingClient.calls()
        XCTAssertEqual(calls, ["active", "confirm"])
    }

    func testInitImportsQrPayloadFromEnvironmentJson() {
        let viewModel = CaptureViewModel(environment: [
            "PROVINODE_SCAN_QR_PAYLOAD_JSON": validPayloadJson()
        ])

        XCTAssertEqual(viewModel.status, "QR payload imported")
        XCTAssertEqual(viewModel.pairingCode, "482915")
        XCTAssertEqual(viewModel.pairingNonce, "01JNONCEABCDEFGHJKMNPQRSTV")
        XCTAssertEqual(viewModel.manualHost, "192.168.1.44")
    }

    func testInitImportsQrPayloadFromEnvironmentPath() throws {
        let payloadPath = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")
        try validPayloadJson().write(to: payloadPath, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: payloadPath) }

        let viewModel = CaptureViewModel(environment: [
            "PROVINODE_SCAN_QR_PAYLOAD_PATH": payloadPath.path
        ])

        XCTAssertEqual(viewModel.status, "QR payload imported")
        XCTAssertEqual(viewModel.pairingCode, "482915")
        XCTAssertEqual(viewModel.manualHost, "192.168.1.44")
    }

    func testApplyPairingQrPayloadImportsValues() {
        let viewModel = CaptureViewModel()

        let payload = """
        {
          "pairing_token": "01JTQRPAIRTOKENABCDEFGHJK",
          "pairing_code": "482915",
          "pairing_nonce": "01JNONCEABCDEFGHJKMNPQRSTV",
          "desktop_device_id": "01JDESKTOPABCDEFGHJKMNPQRS",
          "desktop_display_name": "Room Receiver",
          "pairing_endpoint": "https://192.168.1.44:7448/pairing/confirm",
          "quic_endpoint": "192.168.1.44:7447",
          "expires_at_utc": "2099-02-28T12:00:00Z",
          "desktop_cert_fingerprint_sha256": "ABCDEFABCDEFABCDEFABCDEFABCDEFABCDEFABCDEFABCDEFABCDEFABCDEFABCD",
          "protocol_version": "1.1",
          "signature_alg": "rsa-pkcs1-sha256",
          "signature_b64": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
        }
        """

        viewModel.applyPairingQrPayload(payload)

        XCTAssertEqual(viewModel.manualHost, "192.168.1.44")
        XCTAssertEqual(viewModel.manualPort, "7448")
        XCTAssertEqual(viewModel.manualQuicPort, "7447")
        XCTAssertEqual(viewModel.pairingCode, "482915")
        XCTAssertEqual(viewModel.pairingNonce, "01JNONCEABCDEFGHJKMNPQRSTV")
        XCTAssertEqual(viewModel.manualPairingFingerprintSha256, "abcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcd")
        XCTAssertNil(viewModel.selectedEndpoint)
        XCTAssertEqual(viewModel.status, "QR payload imported")
    }

    func testApplyPairingQrPayloadParseFailureStatusInterpolatesError() {
        let viewModel = CaptureViewModel()

        viewModel.applyPairingQrPayload("{")

        XCTAssertTrue(viewModel.status.hasPrefix("QR payload parse failed: "))
        XCTAssertFalse(viewModel.status.contains("\\(error.localizedDescription)"))
    }

    func testApplyPairingQrPayloadRejectsExpiredToken() {
        let viewModel = CaptureViewModel()

        let payload = """
        {
          "pairing_token": "01JTQRPAIRTOKENABCDEFGHJK",
          "pairing_code": "482915",
          "pairing_nonce": "01JNONCEABCDEFGHJKMNPQRSTV",
          "desktop_device_id": "01JDESKTOPABCDEFGHJKMNPQRS",
          "desktop_display_name": "Room Receiver",
          "pairing_endpoint": "https://192.168.1.44:7448/pairing/confirm",
          "quic_endpoint": "192.168.1.44:7447",
          "expires_at_utc": "2000-02-28T12:00:00Z",
          "desktop_cert_fingerprint_sha256": "ABCDEFABCDEFABCDEFABCDEFABCDEFABCDEFABCDEFABCDEFABCDEFABCDEFABCD",
          "protocol_version": "1.1",
          "signature_alg": "rsa-pkcs1-sha256",
          "signature_b64": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
        }
        """

        viewModel.applyPairingQrPayload(payload)

        XCTAssertEqual(viewModel.status, "QR payload has expired. Start a new pairing session.")
    }

    func testApplyPairingQrPayloadRejectsNonHttpsEndpoint() {
        let viewModel = CaptureViewModel()

        let payload = """
        {
          "pairing_token": "01JTQRPAIRTOKENABCDEFGHJK",
          "pairing_code": "482915",
          "pairing_nonce": "01JNONCEABCDEFGHJKMNPQRSTV",
          "desktop_device_id": "01JDESKTOPABCDEFGHJKMNPQRS",
          "desktop_display_name": "Room Receiver",
          "pairing_endpoint": "http://192.168.1.44:7448/pairing/confirm",
          "quic_endpoint": "192.168.1.44:7447",
          "expires_at_utc": "2099-02-28T12:00:00Z",
          "desktop_cert_fingerprint_sha256": "ABCDEFABCDEFABCDEFABCDEFABCDEFABCDEFABCDEFABCDEFABCDEFABCDEFABCD",
          "protocol_version": "1.1",
          "signature_alg": "rsa-pkcs1-sha256",
          "signature_b64": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
        }
        """

        viewModel.applyPairingQrPayload(payload)

        XCTAssertEqual(viewModel.status, "QR payload pairing endpoint must use https")
    }

    func testApplyPairingQrPayloadRejectsUnsupportedProtocolVersion() {
        let viewModel = CaptureViewModel()

        let payload = """
        {
          "pairing_token": "01JTQRPAIRTOKENABCDEFGHJK",
          "pairing_code": "482915",
          "pairing_nonce": "01JNONCEABCDEFGHJKMNPQRSTV",
          "desktop_device_id": "01JDESKTOPABCDEFGHJKMNPQRS",
          "desktop_display_name": "Room Receiver",
          "pairing_endpoint": "https://192.168.1.44:7448/pairing/confirm",
          "quic_endpoint": "192.168.1.44:7447",
          "expires_at_utc": "2099-02-28T12:00:00Z",
          "desktop_cert_fingerprint_sha256": "ABCDEFABCDEFABCDEFABCDEFABCDEFABCDEFABCDEFABCDEFABCDEFABCDEFABCD",
          "protocol_version": "2.0",
          "signature_alg": "rsa-pkcs1-sha256",
          "signature_b64": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
        }
        """

        viewModel.applyPairingQrPayload(payload)

        XCTAssertEqual(viewModel.status, "QR payload protocol version is unsupported")
    }

    func testApplyPairingQrPayloadRejectsInvalidFingerprintFormat() {
        let viewModel = CaptureViewModel()

        let payload = """
        {
          "pairing_token": "01JTQRPAIRTOKENABCDEFGHJK",
          "pairing_code": "482915",
          "pairing_nonce": "01JNONCEABCDEFGHJKMNPQRSTV",
          "desktop_device_id": "01JDESKTOPABCDEFGHJKMNPQRS",
          "desktop_display_name": "Room Receiver",
          "pairing_endpoint": "https://192.168.1.44:7448/pairing/confirm",
          "quic_endpoint": "192.168.1.44:7447",
          "expires_at_utc": "2099-02-28T12:00:00Z",
          "desktop_cert_fingerprint_sha256": "not-a-sha256",
          "protocol_version": "1.1",
          "signature_alg": "rsa-pkcs1-sha256",
          "signature_b64": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
        }
        """

        viewModel.applyPairingQrPayload(payload)

        XCTAssertEqual(viewModel.status, "QR payload desktop certificate fingerprint is invalid")
    }

    func testApplyPairingQrPayloadRejectsInvalidSignaturePayload() {
        let viewModel = CaptureViewModel()

        let payload = """
        {
          "pairing_token": "01JTQRPAIRTOKENABCDEFGHJK",
          "pairing_code": "482915",
          "pairing_nonce": "01JNONCEABCDEFGHJKMNPQRSTV",
          "desktop_device_id": "01JDESKTOPABCDEFGHJKMNPQRS",
          "desktop_display_name": "Room Receiver",
          "pairing_endpoint": "https://192.168.1.44:7448/pairing/confirm",
          "quic_endpoint": "192.168.1.44:7447",
          "expires_at_utc": "2099-02-28T12:00:00Z",
          "desktop_cert_fingerprint_sha256": "ABCDEFABCDEFABCDEFABCDEFABCDEFABCDEFABCDEFABCDEFABCDEFABCDEFABCD",
          "protocol_version": "1.1",
          "signature_alg": "rsa-pkcs1-sha256",
          "signature_b64": "$$$"
        }
        """

        viewModel.applyPairingQrPayload(payload)

        XCTAssertEqual(viewModel.status, "QR payload signature is missing or invalid")
    }

    func testApplyPairingQrPayloadRejectsShortSignaturePayload() {
        let viewModel = CaptureViewModel()

        let payload = """
        {
          "pairing_token": "01JTQRPAIRTOKENABCDEFGHJK",
          "pairing_code": "482915",
          "pairing_nonce": "01JNONCEABCDEFGHJKMNPQRSTV",
          "desktop_device_id": "01JDESKTOPABCDEFGHJKMNPQRS",
          "desktop_display_name": "Room Receiver",
          "pairing_endpoint": "https://192.168.1.44:7448/pairing/confirm",
          "quic_endpoint": "192.168.1.44:7447",
          "expires_at_utc": "2099-02-28T12:00:00Z",
          "desktop_cert_fingerprint_sha256": "ABCDEFABCDEFABCDEFABCDEFABCDEFABCDEFABCDEFABCDEFABCDEFABCDEFABCD",
          "protocol_version": "1.1",
          "signature_alg": "rsa-pkcs1-sha256",
          "signature_b64": "c2lnbmF0dXJl"
        }
        """

        viewModel.applyPairingQrPayload(payload)

        XCTAssertEqual(viewModel.status, "QR payload signature is missing or invalid")
    }

    func testApplyPairingQrPayloadRejectsInvalidQuicEndpoint() {
        let viewModel = CaptureViewModel()

        let payload = """
        {
          "pairing_token": "01JTQRPAIRTOKENABCDEFGHJK",
          "pairing_code": "482915",
          "pairing_nonce": "01JNONCEABCDEFGHJKMNPQRSTV",
          "desktop_device_id": "01JDESKTOPABCDEFGHJKMNPQRS",
          "desktop_display_name": "Room Receiver",
          "pairing_endpoint": "https://192.168.1.44:7448/pairing/confirm",
          "quic_endpoint": "invalid-endpoint-format",
          "expires_at_utc": "2099-02-28T12:00:00Z",
          "desktop_cert_fingerprint_sha256": "ABCDEFABCDEFABCDEFABCDEFABCDEFABCDEFABCDEFABCDEFABCDEFABCDEFABCD",
          "protocol_version": "1.1",
          "signature_alg": "rsa-pkcs1-sha256",
          "signature_b64": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
        }
        """

        viewModel.applyPairingQrPayload(payload)

        XCTAssertEqual(viewModel.status, "QR payload QUIC endpoint is invalid")
    }

    private func validPayloadJson() -> String {
        """
        {
          "pairing_token": "01JTQRPAIRTOKENABCDEFGHJK",
          "pairing_code": "482915",
          "pairing_nonce": "01JNONCEABCDEFGHJKMNPQRSTV",
          "desktop_device_id": "01JDESKTOPABCDEFGHJKMNPQRS",
          "desktop_display_name": "Room Receiver",
          "pairing_endpoint": "https://192.168.1.44:7448/pairing/confirm",
          "quic_endpoint": "192.168.1.44:7447",
          "expires_at_utc": "2099-02-28T12:00:00Z",
          "desktop_cert_fingerprint_sha256": "ABCDEFABCDEFABCDEFABCDEFABCDEFABCDEFABCDEFABCDEFABCDEFABCDEFABCD",
          "protocol_version": "1.1",
          "signature_alg": "rsa-pkcs1-sha256",
          "signature_b64": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
        }
        """
    }
}

private actor StubPairingSessionClient: PairingSessionClient {
    private let activeSessionResponse: PairingSessionStatusResponse?
    private let startSessionResponse: PairingSessionStatusResponse?
    private let confirmResult: PairingConfirmResult?
    private var recordedCalls: [String] = []

    init(
        activeSessionResponse: PairingSessionStatusResponse?,
        startSessionResponse: PairingSessionStatusResponse?,
        confirmResult: PairingConfirmResult?
    ) {
        self.activeSessionResponse = activeSessionResponse
        self.startSessionResponse = startSessionResponse
        self.confirmResult = confirmResult
    }

    func confirmPairing(
        endpoint _: PairingEndpoint,
        pairingNonce _: String,
        pairingCode _: String,
        scanDeviceId _: String,
        scanDisplayName _: String,
        scanCertFingerprintSha256 _: String,
        desktopCertFingerprintSha256 _: String
    ) async throws -> PairingConfirmResult {
        recordedCalls.append("confirm")
        guard let confirmResult else {
            throw PairingError.serverRejected(nil)
        }

        return confirmResult
    }

    func startPairingSession(endpoint _: PairingEndpoint) async throws -> PairingSessionStatusResponse {
        recordedCalls.append("start")
        guard let startSessionResponse else {
            throw PairingError.serverRejected(nil)
        }

        return startSessionResponse
    }

    func getActivePairingSession(endpoint _: PairingEndpoint) async throws -> PairingSessionStatusResponse {
        recordedCalls.append("active")
        guard let activeSessionResponse else {
            throw PairingError.serverRejected(nil)
        }

        return activeSessionResponse
    }

    func calls() -> [String] {
        recordedCalls
    }
}
