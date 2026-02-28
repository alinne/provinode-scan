import CryptoKit
import Foundation
import ProvinodeRoomContracts

enum EngineSecureChannelCrypto {
    static let protocolId = RoomContractVersions.secureChannelProtocol
    private static let info = Data("linnaeus.engine.transport.secure.v1".utf8)

    struct EphemeralKeyPair {
        let privateKey: P256.KeyAgreement.PrivateKey
        var publicKeyX963: Data { privateKey.publicKey.rawRepresentation }
    }

    struct SessionKeys {
        let encryptionKey: SymmetricKey
        let noncePrefix: Data
    }

    struct CipherData {
        let counter: Int64
        let nonce: Data
        let ciphertext: Data
        let tag: Data
    }

    static func createEphemeralKeyPair() -> EphemeralKeyPair {
        EphemeralKeyPair(privateKey: P256.KeyAgreement.PrivateKey())
    }

    static func generateSalt(length: Int = 32) -> Data {
        Data((0..<length).map { _ in UInt8.random(in: .min ... .max) })
    }

    static func deriveSessionKeys(
        localKeyPair: EphemeralKeyPair,
        peerPublicKeyX963: Data,
        salt: Data
    ) throws -> SessionKeys {
        let peerPublicKey = try P256.KeyAgreement.PublicKey(rawRepresentation: peerPublicKeyX963)
        let sharedSecret = try localKeyPair.privateKey.sharedSecretFromKeyAgreement(with: peerPublicKey)
        let derived = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: salt,
            sharedInfo: info,
            outputByteCount: 40)

        let material = derived.withUnsafeBytes { Data($0) }
        let encryptionKey = SymmetricKey(data: material.prefix(32))
        let noncePrefix = material.dropFirst(32).prefix(8)

        return SessionKeys(encryptionKey: encryptionKey, noncePrefix: Data(noncePrefix))
    }

    static func encrypt(keys: SessionKeys, counter: Int64, plaintext: Data) throws -> CipherData {
        let nonce = try makeNonce(prefix: keys.noncePrefix, counter: counter)
        let sealed = try AES.GCM.seal(plaintext, using: keys.encryptionKey, nonce: nonce)

        return CipherData(
            counter: counter,
            nonce: Data(nonce),
            ciphertext: sealed.ciphertext,
            tag: sealed.tag)
    }

    static func decrypt(
        keys: SessionKeys,
        nonce: Data,
        ciphertext: Data,
        tag: Data
    ) throws -> Data {
        let nonceObj = try AES.GCM.Nonce(data: nonce)
        let sealed = try AES.GCM.SealedBox(nonce: nonceObj, ciphertext: ciphertext, tag: tag)
        return try AES.GCM.open(sealed, using: keys.encryptionKey)
    }

    static func signSecureHello(privateKeyRawB64: String, payload: Data) throws -> Data {
        guard let keyData = Data(base64Encoded: privateKeyRawB64) else {
            throw NSError(
                domain: "EngineSecureChannelCrypto",
                code: 3002,
                userInfo: [NSLocalizedDescriptionKey: "Signing key data was invalid base64"])
        }

        let privateKey = try P256.Signing.PrivateKey(rawRepresentation: keyData)
        let signature = try privateKey.signature(for: payload)
        return signature.derRepresentation
    }

    private static func makeNonce(prefix: Data, counter: Int64) throws -> AES.GCM.Nonce {
        guard prefix.count == 8, counter >= 0, counter <= Int64(UInt32.max) else {
            throw NSError(domain: "EngineSecureChannelCrypto", code: 3001, userInfo: [NSLocalizedDescriptionKey: "Invalid nonce input"])
        }

        var data = prefix
        var value = UInt32(counter).bigEndian
        withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        return try AES.GCM.Nonce(data: data)
    }
}
