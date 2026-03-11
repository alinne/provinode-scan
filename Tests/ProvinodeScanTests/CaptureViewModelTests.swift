import XCTest
import ProvinodeRoomContracts
@testable import ProvinodeScan

@MainActor
final class CaptureViewModelTests: XCTestCase {
    func testInitImportsQrPayloadFromEnvironmentJson() async {
        let viewModel = CaptureViewModel(
            environment: [
            "PROVINODE_SCAN_QR_PAYLOAD_JSON": validPayloadJson()
        ],
            qrVerifier: MockQrVerifier(result: .success(Self.verifiedPayload())))
        await viewModel.waitForInitialImports()

        XCTAssertEqual(viewModel.status, "QR payload verified")
        XCTAssertEqual(viewModel.pairingCode, "482915")
        XCTAssertEqual(viewModel.pairingNonce, "01JNONCEABCDEFGHJKMNPQRSTV")
        XCTAssertEqual(viewModel.manualHost, "192.168.1.44")
    }

    func testInitImportsQrPayloadFromEnvironmentPath() async throws {
        let payloadPath = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")
        try validPayloadJson().write(to: payloadPath, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: payloadPath) }

        let viewModel = CaptureViewModel(
            environment: [
            "PROVINODE_SCAN_QR_PAYLOAD_PATH": payloadPath.path
        ],
            qrVerifier: MockQrVerifier(result: .success(Self.verifiedPayload())))
        await viewModel.waitForInitialImports()

        XCTAssertEqual(viewModel.status, "QR payload verified")
        XCTAssertEqual(viewModel.pairingCode, "482915")
        XCTAssertEqual(viewModel.manualHost, "192.168.1.44")
    }

    func testApplyPairingQrPayloadImportsValues() async {
        let viewModel = CaptureViewModel(qrVerifier: MockQrVerifier(result: .success(Self.verifiedPayload())))

        await viewModel.applyPairingQrPayload(validPayloadJson())

        XCTAssertEqual(viewModel.manualHost, "192.168.1.44")
        XCTAssertEqual(viewModel.manualPort, "7448")
        XCTAssertEqual(viewModel.manualQuicPort, "7447")
        XCTAssertEqual(viewModel.pairingCode, "482915")
        XCTAssertEqual(viewModel.pairingNonce, "01JNONCEABCDEFGHJKMNPQRSTV")
        XCTAssertEqual(viewModel.manualPairingFingerprintSha256, "abcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcd")
        XCTAssertNil(viewModel.selectedEndpoint)
        XCTAssertEqual(viewModel.status, "QR payload verified")
    }

    func testApplyPairingQrPayloadPreservesDistinctPairingAndQuicHosts() async {
        let payload = PairingQrPayload(
            pairing_token: "01JTQRPAIRTOKENABCDEFGHJK",
            pairing_code: "482915",
            pairing_nonce: "01JNONCEABCDEFGHJKMNPQRSTV",
            desktop_device_id: "01JDESKTOPABCDEFGHJKMNPQRS",
            desktop_display_name: "Room Receiver",
            pairing_endpoint: "https://desktop-pair.local:7448/pairing/confirm",
            quic_endpoint: "desktop-stream.local:7447",
            expires_at_utc: "2099-02-28T12:00:00Z",
            desktop_cert_fingerprint_sha256: "ABCDEFABCDEFABCDEFABCDEFABCDEFABCDEFABCDEFABCDEFABCDEFABCDEFABCD",
            protocol_version: "1.8",
            signature_alg: "rsa-pkcs1-sha256",
            signature_b64: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
            candidate_pairing_endpoints: nil,
            candidate_quic_endpoints: nil)
        let verified = VerifiedPairingQrPayload(
            payload: payload,
            pairingHost: "desktop-pair.local",
            pairingPort: 7448,
            quicHost: "desktop-stream.local",
            quicPort: 7447)
        let viewModel = CaptureViewModel(qrVerifier: MockQrVerifier(result: .success(verified)))

        await viewModel.applyPairingQrPayload(validPayloadJson())

        XCTAssertEqual(viewModel.manualHost, "desktop-pair.local")
        XCTAssertEqual(viewModel.manualQuicHost, "desktop-stream.local")
        XCTAssertEqual(viewModel.manualPort, "7448")
        XCTAssertEqual(viewModel.manualQuicPort, "7447")
    }

    func testApplyPairingQrPayloadMalformedStatusIsUsed() async {
        let viewModel = CaptureViewModel(qrVerifier: MockQrVerifier(result: .failure(.malformedQr)))

        await viewModel.applyPairingQrPayload("{")

        XCTAssertEqual(viewModel.status, "QR payload is malformed")
    }

    func testApplyPairingQrPayloadRejectsExpiredToken() async {
        let viewModel = CaptureViewModel(qrVerifier: MockQrVerifier(result: .failure(.expired)))

        await viewModel.applyPairingQrPayload(validPayloadJson())

        XCTAssertEqual(viewModel.status, "QR payload has expired. Start a new pairing session.")
    }

    func testApplyPairingQrPayloadRejectsNonHttpsEndpoint() async {
        let viewModel = CaptureViewModel(qrVerifier: MockQrVerifier(result: .failure(.invalidPairingEndpoint)))

        await viewModel.applyPairingQrPayload(validPayloadJson())

        XCTAssertEqual(viewModel.status, "QR payload pairing endpoint is invalid")
    }

    func testApplyPairingQrPayloadRejectsUnsupportedProtocolVersion() async {
        let viewModel = CaptureViewModel(qrVerifier: MockQrVerifier(result: .failure(.unsupportedProtocol)))

        await viewModel.applyPairingQrPayload(validPayloadJson())

        XCTAssertEqual(viewModel.status, "QR payload protocol version is unsupported")
    }

    func testApplyPairingQrPayloadRejectsInvalidFingerprintFormat() async {
        let viewModel = CaptureViewModel(qrVerifier: MockQrVerifier(result: .failure(.invalidFingerprint)))

        await viewModel.applyPairingQrPayload(validPayloadJson())

        XCTAssertEqual(viewModel.status, "QR payload desktop certificate fingerprint is invalid")
    }

    func testApplyPairingQrPayloadRejectsInvalidSignaturePayload() async {
        let viewModel = CaptureViewModel(qrVerifier: MockQrVerifier(result: .failure(.invalidSignatureEncoding)))

        await viewModel.applyPairingQrPayload(validPayloadJson())

        XCTAssertEqual(viewModel.status, "QR payload signature is missing or invalid")
    }

    func testApplyPairingQrPayloadRejectsShortSignaturePayload() async {
        let viewModel = CaptureViewModel(qrVerifier: MockQrVerifier(result: .failure(.invalidSignatureEncoding)))

        await viewModel.applyPairingQrPayload(validPayloadJson())

        XCTAssertEqual(viewModel.status, "QR payload signature is missing or invalid")
    }

    func testApplyPairingQrPayloadRejectsInvalidQuicEndpoint() async {
        let viewModel = CaptureViewModel(qrVerifier: MockQrVerifier(result: .failure(.invalidQuicEndpoint)))

        await viewModel.applyPairingQrPayload(validPayloadJson())

        XCTAssertEqual(viewModel.status, "QR payload QUIC endpoint is invalid")
    }

    func testCaptureCoachingCallsOutMeshCoverageAndTwinQuality() {
        let viewModel = CaptureViewModel()
        viewModel.status = "Capturing"
        viewModel.isCapturing = true
        viewModel.metrics = ScanSessionMetrics(
            emittedSamples: 80,
            droppedSamples: 0,
            keyframeCount: 24,
            depthCount: 80,
            meshCount: 2,
            avgKeyframeFps: 4.2,
            captureDurationSeconds: 24,
            poseConfidence: 0.88)

        viewModel.recomputeCaptureHealthForTesting()

        XCTAssertFalse(viewModel.safeToStop)
        XCTAssertTrue(viewModel.captureCoaching.contains("mesh_coverage"))
        XCTAssertTrue(viewModel.captureCoaching.contains("trace wall-floor corners"))
        XCTAssertTrue(viewModel.captureCoaching.contains("Twin quality"))
    }

    func testCaptureCoachingCallsOutStructuralCoverageAndViewportReadiness() {
        let viewModel = CaptureViewModel()
        viewModel.status = "Capturing"
        viewModel.isCapturing = true
        viewModel.metrics = ScanSessionMetrics(
            emittedSamples: 72,
            droppedSamples: 0,
            keyframeCount: 20,
            depthCount: 45,
            meshCount: 2,
            avgKeyframeFps: 2.5,
            captureDurationSeconds: 22,
            poseConfidence: 0.80)

        viewModel.recomputeCaptureHealthForTesting()

        XCTAssertFalse(viewModel.safeToStop)
        XCTAssertTrue(viewModel.captureCoaching.contains("fixture_span"))
        XCTAssertTrue(viewModel.captureCoaching.contains("perimeter_pass"))
        XCTAssertTrue(viewModel.captureCoaching.contains("viewport_match_readiness"))
        XCTAssertTrue(viewModel.captureCoaching.contains("Camera-match readiness"))
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
          "protocol_version": "1.8",
          "signature_alg": "rsa-pkcs1-sha256",
          "signature_b64": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
        }
        """
    }

    private static func verifiedPayload() -> VerifiedPairingQrPayload {
        let payload = PairingQrPayload(
            pairing_token: "01JTQRPAIRTOKENABCDEFGHJK",
            pairing_code: "482915",
            pairing_nonce: "01JNONCEABCDEFGHJKMNPQRSTV",
            desktop_device_id: "01JDESKTOPABCDEFGHJKMNPQRS",
            desktop_display_name: "Room Receiver",
            pairing_endpoint: "https://192.168.1.44:7448/pairing/confirm",
            quic_endpoint: "192.168.1.44:7447",
            expires_at_utc: "2099-02-28T12:00:00Z",
            desktop_cert_fingerprint_sha256: "ABCDEFABCDEFABCDEFABCDEFABCDEFABCDEFABCDEFABCDEFABCDEFABCDEFABCD",
            protocol_version: "1.8",
            signature_alg: "rsa-pkcs1-sha256",
            signature_b64: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
            candidate_pairing_endpoints: nil,
            candidate_quic_endpoints: nil)
        return VerifiedPairingQrPayload(
            payload: payload,
            pairingHost: "192.168.1.44",
            pairingPort: 7448,
            quicHost: "192.168.1.44",
            quicPort: 7447)
    }
}

private struct MockQrVerifier: PairingQrVerifying {
    let result: Result<VerifiedPairingQrPayload, PairingQrVerificationError>

    func verify(rawPayload: String) async throws -> VerifiedPairingQrPayload {
        switch result {
        case .success(let payload):
            return payload
        case .failure(let error):
            throw error
        }
    }
}
