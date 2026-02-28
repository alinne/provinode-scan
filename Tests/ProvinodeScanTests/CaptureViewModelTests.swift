import XCTest
@testable import ProvinodeScan

@MainActor
final class CaptureViewModelTests: XCTestCase {
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
          "signature_b64": "c2lnbmF0dXJl"
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
          "signature_b64": "c2lnbmF0dXJl"
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
          "signature_b64": "c2lnbmF0dXJl"
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
          "signature_b64": "c2lnbmF0dXJl"
        }
        """

        viewModel.applyPairingQrPayload(payload)

        XCTAssertEqual(viewModel.status, "QR payload protocol version is unsupported")
    }
}
