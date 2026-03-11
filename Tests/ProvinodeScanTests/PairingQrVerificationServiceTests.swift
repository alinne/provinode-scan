import XCTest
import Security
import CryptoKit
import ProvinodeRoomContracts
@testable import ProvinodeScan

final class PairingQrVerificationServiceTests: XCTestCase {
    func testVerifyAcceptsValidSignedQr() async throws {
        let signer = try TestSigner()
        let payload = try signedPayload(using: signer)
        let service = PairingQrVerificationService { advertised in
            XCTAssertEqual(advertised.desktop_cert_fingerprint_sha256.lowercased(), signer.fingerprint.lowercased())
            return PairingQrSignerIdentity(fingerprintSha256: signer.fingerprint, publicKey: signer.publicKey)
        }

        let verified = try await service.verify(rawPayload: try encode(payload))

        XCTAssertEqual(verified.pairingHost, "192.168.1.44")
        XCTAssertEqual(verified.pairingPort, 7448)
        XCTAssertEqual(verified.quicHost, "192.168.1.44")
        XCTAssertEqual(verified.quicPort, 7447)
    }

    func testVerifyRejectsTamperedPayload() async throws {
        let signer = try TestSigner()
        let payload = try signedPayload(using: signer)
        let tampered = payloadWith(
            payload,
            pairingCode: "000000",
            signature: payload.signature_b64)
        let service = PairingQrVerificationService { _ in
            PairingQrSignerIdentity(fingerprintSha256: signer.fingerprint, publicKey: signer.publicKey)
        }

        await XCTAssertThrowsErrorAsync(try await service.verify(rawPayload: try self.encode(tampered))) { error in
            XCTAssertEqual(error as? PairingQrVerificationError, .invalidSignature)
        }
    }

    func testVerifyRejectsWrongSigner() async throws {
        let signer = try TestSigner()
        let wrongSigner = try TestSigner()
        let payload = try signedPayload(using: signer)
        let service = PairingQrVerificationService { _ in
            PairingQrSignerIdentity(fingerprintSha256: signer.fingerprint, publicKey: wrongSigner.publicKey)
        }

        await XCTAssertThrowsErrorAsync(try await service.verify(rawPayload: try self.encode(payload))) { error in
            XCTAssertEqual(error as? PairingQrVerificationError, .invalidSignature)
        }
    }

    func testVerifyRejectsExpiredPayload() async throws {
        let signer = try TestSigner()
        let payload = payloadWith(
            try signedPayload(using: signer),
            expiresAtUtc: "2000-01-01T00:00:00Z",
            signature: "")
        let service = PairingQrVerificationService { _ in
            PairingQrSignerIdentity(fingerprintSha256: signer.fingerprint, publicKey: signer.publicKey)
        }

        await XCTAssertThrowsErrorAsync(try await service.verify(rawPayload: try self.encode(payload))) { error in
            XCTAssertEqual(error as? PairingQrVerificationError, .expired)
        }
    }

    func testVerifyRejectsMismatchedFingerprint() async throws {
        let signer = try TestSigner()
        let payload = try signedPayload(using: signer)
        let service = PairingQrVerificationService { _ in
            PairingQrSignerIdentity(
                fingerprintSha256: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
                publicKey: signer.publicKey)
        }

        await XCTAssertThrowsErrorAsync(try await service.verify(rawPayload: try self.encode(payload))) { error in
            XCTAssertEqual(error as? PairingQrVerificationError, .signerUntrusted)
        }
    }

    func testVerifyRejectsMalformedSignatureEncoding() async throws {
        let signer = try TestSigner()
        let payload = payloadWith(
            makeUnsignedPayload(fingerprint: signer.fingerprint),
            signature: "$$$")
        let service = PairingQrVerificationService { _ in
            PairingQrSignerIdentity(fingerprintSha256: signer.fingerprint, publicKey: signer.publicKey)
        }

        await XCTAssertThrowsErrorAsync(try await service.verify(rawPayload: try self.encode(payload))) { error in
            XCTAssertEqual(error as? PairingQrVerificationError, .invalidSignatureEncoding)
        }
    }

    func testVerifyFailsClosedWhenSignerVerificationIsUnreachable() async throws {
        let signer = try TestSigner()
        let payload = try signedPayload(using: signer)
        let service = PairingQrVerificationService { _ in
            throw PairingQrVerificationError.signerVerificationUnreachable
        }

        await XCTAssertThrowsErrorAsync(try await service.verify(rawPayload: try self.encode(payload))) { error in
            XCTAssertEqual(error as? PairingQrVerificationError, .signerVerificationUnreachable)
        }
    }

    private func signedPayload(using signer: TestSigner) throws -> PairingQrPayload {
        let payload = makeUnsignedPayload(fingerprint: signer.fingerprint)
        let canonical = PairingQrVerificationService.canonicalize(payload: payload, blankSignature: true)
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            signer.privateKey,
            .rsaSignatureMessagePKCS1v15SHA256,
            Data(canonical.utf8) as CFData,
            &error) as Data? else {
            throw error!.takeRetainedValue() as Error
        }
        return payloadWith(payload, signature: signature.base64EncodedString())
    }

    private func makeUnsignedPayload(fingerprint: String) -> PairingQrPayload {
        PairingQrPayload(
            pairing_token: "01JTQRPAIRTOKENABCDEFGHJK",
            pairing_code: "482915",
            pairing_nonce: "01JNONCEABCDEFGHJKMNPQRSTV",
            desktop_device_id: "01JDESKTOPABCDEFGHJKMNPQRS",
            desktop_display_name: "Room Receiver",
            pairing_endpoint: "https://192.168.1.44:7448/pairing/confirm",
            quic_endpoint: "192.168.1.44:7447",
            expires_at_utc: "2099-02-28T12:00:00Z",
            desktop_cert_fingerprint_sha256: fingerprint,
            protocol_version: "1.8",
            signature_alg: "rsa-pkcs1-sha256",
            signature_b64: "",
            candidate_pairing_endpoints: nil,
            candidate_quic_endpoints: nil)
    }

    private func encode(_ payload: PairingQrPayload) throws -> String {
        let data = try JSONEncoder().encode(payload)
        return String(decoding: data, as: UTF8.self)
    }

    private func payloadWith(
        _ payload: PairingQrPayload,
        pairingCode: String? = nil,
        expiresAtUtc: String? = nil,
        signature: String? = nil
    ) -> PairingQrPayload {
        PairingQrPayload(
            pairing_token: payload.pairing_token,
            pairing_code: pairingCode ?? payload.pairing_code,
            pairing_nonce: payload.pairing_nonce,
            desktop_device_id: payload.desktop_device_id,
            desktop_display_name: payload.desktop_display_name,
            pairing_endpoint: payload.pairing_endpoint,
            quic_endpoint: payload.quic_endpoint,
            expires_at_utc: expiresAtUtc ?? payload.expires_at_utc,
            desktop_cert_fingerprint_sha256: payload.desktop_cert_fingerprint_sha256,
            protocol_version: payload.protocol_version,
            signature_alg: payload.signature_alg,
            signature_b64: signature ?? payload.signature_b64,
            candidate_pairing_endpoints: payload.candidate_pairing_endpoints,
            candidate_quic_endpoints: payload.candidate_quic_endpoints)
    }
}

private struct TestSigner {
    let privateKey: SecKey
    let publicKey: SecKey
    let fingerprint: String

    init() throws {
        var error: Unmanaged<CFError>?
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048
        ]
        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw error!.takeRetainedValue() as Error
        }

        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            throw NSError(domain: "PairingQrVerificationServiceTests", code: 1, userInfo: nil)
        }

        var exportError: Unmanaged<CFError>?
        guard let publicKeyData = SecKeyCopyExternalRepresentation(publicKey, &exportError) as Data? else {
            throw exportError!.takeRetainedValue() as Error
        }

        self.privateKey = privateKey
        self.publicKey = publicKey
        self.fingerprint = Self.sha256Hex(publicKeyData)
    }

    private static func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure @escaping () async throws -> T,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line,
    _ errorHandler: (Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail(message(), file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
