import CryptoKit
import XCTest
@testable import ProvinodeScan

final class EngineSecureChannelCryptoTests: XCTestCase {
    func testSignSecureHelloUsesRawEcdsaSignatureFormat() throws {
        let privateKey = P256.Signing.PrivateKey()
        let payload = Data("secure-hello-signature-test".utf8)

        let signature = try EngineSecureChannelCrypto.signSecureHello(
            privateKeyRawB64: privateKey.rawRepresentation.base64EncodedString(),
            payload: payload)

        XCTAssertEqual(signature.count, 64)
        let parsed = try P256.Signing.ECDSASignature(rawRepresentation: signature)
        XCTAssertTrue(privateKey.publicKey.isValidSignature(parsed, for: payload))
    }

    func testEphemeralKeysUseX963AndDeriveMatchingSessionKeys() throws {
        let local = EngineSecureChannelCrypto.createEphemeralKeyPair()
        let peer = EngineSecureChannelCrypto.createEphemeralKeyPair()
        let salt = EngineSecureChannelCrypto.generateSalt()

        XCTAssertEqual(local.publicKeyX963.count, 65)
        XCTAssertEqual(peer.publicKeyX963.count, 65)

        let localKeys = try EngineSecureChannelCrypto.deriveSessionKeys(
            localKeyPair: local,
            peerPublicKeyX963: peer.publicKeyX963,
            salt: salt)
        let peerKeys = try EngineSecureChannelCrypto.deriveSessionKeys(
            localKeyPair: peer,
            peerPublicKeyX963: local.publicKeyX963,
            salt: salt)

        let localMaterial = localKeys.encryptionKey.withUnsafeBytes { Data($0) }
        let peerMaterial = peerKeys.encryptionKey.withUnsafeBytes { Data($0) }
        XCTAssertEqual(localMaterial, peerMaterial)
        XCTAssertEqual(localKeys.noncePrefix, peerKeys.noncePrefix)
    }
}
