import CryptoKit
import Foundation

struct ScanIdentityMaterial: Sendable {
    let deviceId: String
    let certFingerprintSha256: String
    let signingPublicKeyB64: String
    let signingPrivateKeyRawB64: String
}

struct ScanClientTlsIdentityMaterial: Sendable {
    let pkcs12Data: Data
    let password: String
    let certFingerprintSha256: String
}

final class ScanIdentityStore {
    private static let clientTlsEncryptionVersion = 1
    private static let clientTlsKeyInfo = Data("provinode-scan-client-tls-at-rest-v1".utf8)

    private struct StoredClientTlsSecret: Codable {
        let pkcs12_b64: String
        let password: String
        let cert_fingerprint_sha256: String
    }

    private struct StoredIdentity: Codable {
        let device_id: String
        let signing_private_key_raw_b64: String
        let client_tls_encrypted_blob_b64: String?
        let client_tls_encryption_version: Int?
        let client_tls_pkcs12_b64: String?
        let client_tls_password: String?
        let client_tls_cert_fingerprint_sha256: String?
    }

    private let fileUrl: URL
    private var storedIdentity: StoredIdentity
    private let materialValue: ScanIdentityMaterial

    init(rootDirectory: URL? = nil) throws {
        let root = try rootDirectory ?? Self.defaultRootDirectory()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fileUrl = root.appendingPathComponent("scan-identity.json", conformingTo: .json)
        self.fileUrl = fileUrl

        let loaded = try Self.loadOrCreate(fileUrl: fileUrl)
        let stored = try Self.migrateLegacyClientTlsIfNeeded(loaded, fileUrl: fileUrl)
        storedIdentity = stored
        materialValue = try Self.material(from: stored)
    }

    func material() -> ScanIdentityMaterial {
        materialValue
    }

    func clientTlsIdentity() -> ScanClientTlsIdentityMaterial? {
        if let encryptedBlobB64 = storedIdentity.client_tls_encrypted_blob_b64 {
            let version = storedIdentity.client_tls_encryption_version ?? Self.clientTlsEncryptionVersion
            guard version == Self.clientTlsEncryptionVersion,
                  let encryptedBlob = Data(base64Encoded: encryptedBlobB64),
                  let encryptionKey = Self.clientTlsEncryptionKey(from: storedIdentity),
                  let sealedBox = try? AES.GCM.SealedBox(combined: encryptedBlob),
                  let decryptedPayload = try? AES.GCM.open(sealedBox, using: encryptionKey),
                  let secret = try? JSONDecoder().decode(StoredClientTlsSecret.self, from: decryptedPayload),
                  let pkcs12Data = Data(base64Encoded: secret.pkcs12_b64)
            else {
                return nil
            }

            return ScanClientTlsIdentityMaterial(
                pkcs12Data: pkcs12Data,
                password: secret.password,
                certFingerprintSha256: secret.cert_fingerprint_sha256.lowercased())
        }

        guard let pkcs12B64 = storedIdentity.client_tls_pkcs12_b64,
              let password = storedIdentity.client_tls_password,
              let certFingerprint = storedIdentity.client_tls_cert_fingerprint_sha256,
              let pkcs12Data = Data(base64Encoded: pkcs12B64)
        else {
            return nil
        }

        return ScanClientTlsIdentityMaterial(
            pkcs12Data: pkcs12Data,
            password: password,
            certFingerprintSha256: certFingerprint)
    }

    func persistClientTlsIdentity(
        pkcs12Data: Data,
        password: String,
        certFingerprintSha256: String
    ) throws {
        let secret = StoredClientTlsSecret(
            pkcs12_b64: pkcs12Data.base64EncodedString(),
            password: password,
            cert_fingerprint_sha256: certFingerprintSha256.lowercased())
        let encryptedBlobB64 = try Self.encryptClientTlsSecret(secret, with: storedIdentity)

        storedIdentity = StoredIdentity(
            device_id: storedIdentity.device_id,
            signing_private_key_raw_b64: storedIdentity.signing_private_key_raw_b64,
            client_tls_encrypted_blob_b64: encryptedBlobB64,
            client_tls_encryption_version: Self.clientTlsEncryptionVersion,
            client_tls_pkcs12_b64: nil,
            client_tls_password: nil,
            client_tls_cert_fingerprint_sha256: nil)
        try persist()
    }

    private static func loadOrCreate(fileUrl: URL) throws -> StoredIdentity {
        if FileManager.default.fileExists(atPath: fileUrl.path) {
            let data = try Data(contentsOf: fileUrl)
            return try JSONDecoder().decode(StoredIdentity.self, from: data)
        }

        let key = P256.Signing.PrivateKey()
        let stored = StoredIdentity(
            device_id: ULID.generate(),
            signing_private_key_raw_b64: key.rawRepresentation.base64EncodedString(),
            client_tls_encrypted_blob_b64: nil,
            client_tls_encryption_version: nil,
            client_tls_pkcs12_b64: nil,
            client_tls_password: nil,
            client_tls_cert_fingerprint_sha256: nil)

        try writeStoredIdentity(stored, to: fileUrl)
        return stored
    }

    private static func material(from stored: StoredIdentity) throws -> ScanIdentityMaterial {
        guard let privateKeyBytes = Data(base64Encoded: stored.signing_private_key_raw_b64) else {
            throw NSError(
                domain: "ScanIdentityStore",
                code: 4001,
                userInfo: [NSLocalizedDescriptionKey: "Stored scan identity key was invalid base64."])
        }

        let privateKey = try P256.Signing.PrivateKey(rawRepresentation: privateKeyBytes)
        // Engine secure-hello verification expects uncompressed ANSI X9.63 key bytes (0x04 || X || Y).
        let publicKey = privateKey.publicKey.x963Representation
        return ScanIdentityMaterial(
            deviceId: stored.device_id,
            certFingerprintSha256: Sha256.hex(of: publicKey),
            signingPublicKeyB64: publicKey.base64EncodedString(),
            signingPrivateKeyRawB64: privateKey.rawRepresentation.base64EncodedString())
    }

    private static func migrateLegacyClientTlsIfNeeded(_ stored: StoredIdentity, fileUrl: URL) throws -> StoredIdentity {
        if stored.client_tls_encrypted_blob_b64 != nil {
            return stored
        }

        let legacyValues = (
            pkcs12: stored.client_tls_pkcs12_b64,
            password: stored.client_tls_password,
            fingerprint: stored.client_tls_cert_fingerprint_sha256)

        guard legacyValues.pkcs12 != nil || legacyValues.password != nil || legacyValues.fingerprint != nil else {
            return stored
        }

        guard let pkcs12 = legacyValues.pkcs12,
              let password = legacyValues.password,
              let fingerprint = legacyValues.fingerprint
        else {
            throw NSError(
                domain: "ScanIdentityStore",
                code: 4002,
                userInfo: [NSLocalizedDescriptionKey: "Stored scan identity had incomplete legacy client TLS fields."])
        }

        let secret = StoredClientTlsSecret(
            pkcs12_b64: pkcs12,
            password: password,
            cert_fingerprint_sha256: fingerprint.lowercased())
        let encryptedBlobB64 = try encryptClientTlsSecret(secret, with: stored)

        let migrated = StoredIdentity(
            device_id: stored.device_id,
            signing_private_key_raw_b64: stored.signing_private_key_raw_b64,
            client_tls_encrypted_blob_b64: encryptedBlobB64,
            client_tls_encryption_version: clientTlsEncryptionVersion,
            client_tls_pkcs12_b64: nil,
            client_tls_password: nil,
            client_tls_cert_fingerprint_sha256: nil)

        try writeStoredIdentity(migrated, to: fileUrl)
        return migrated
    }

    private static func encryptClientTlsSecret(_ secret: StoredClientTlsSecret, with stored: StoredIdentity) throws -> String {
        guard let key = clientTlsEncryptionKey(from: stored) else {
            throw NSError(
                domain: "ScanIdentityStore",
                code: 4003,
                userInfo: [NSLocalizedDescriptionKey: "Could not derive client TLS encryption key from scan identity."])
        }

        let payload = try JSONEncoder().encode(secret)
        let sealedBox = try AES.GCM.seal(payload, using: key)
        guard let combined = sealedBox.combined else {
            throw NSError(
                domain: "ScanIdentityStore",
                code: 4004,
                userInfo: [NSLocalizedDescriptionKey: "Failed to build encrypted client TLS payload."])
        }

        return combined.base64EncodedString()
    }

    private static func clientTlsEncryptionKey(from stored: StoredIdentity) -> SymmetricKey? {
        guard let signingPrivateKeyRaw = Data(base64Encoded: stored.signing_private_key_raw_b64) else {
            return nil
        }

        let salt = Data("scan-device:\(stored.device_id)".utf8)
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: signingPrivateKeyRaw),
            salt: salt,
            info: clientTlsKeyInfo,
            outputByteCount: 32)
    }

    private func persist() throws {
        try Self.writeStoredIdentity(storedIdentity, to: fileUrl)
    }

    private static func writeStoredIdentity(_ stored: StoredIdentity, to fileUrl: URL) throws {
        let data = try JSONEncoder.pretty.encode(stored)
        try data.write(to: fileUrl, options: .atomic)

        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var mutableUrl = fileUrl
        try? mutableUrl.setResourceValues(resourceValues)
    }

    private static func defaultRootDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true)
        return base.appendingPathComponent("ProvinodeScan", isDirectory: true)
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
