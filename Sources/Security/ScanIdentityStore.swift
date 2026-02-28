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
    private struct StoredIdentity: Codable {
        let device_id: String
        let signing_private_key_raw_b64: String
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

        let stored = try Self.loadOrCreate(fileUrl: fileUrl)
        storedIdentity = stored
        materialValue = try Self.material(from: stored)
    }

    func material() -> ScanIdentityMaterial {
        materialValue
    }

    func clientTlsIdentity() -> ScanClientTlsIdentityMaterial? {
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
        storedIdentity = StoredIdentity(
            device_id: storedIdentity.device_id,
            signing_private_key_raw_b64: storedIdentity.signing_private_key_raw_b64,
            client_tls_pkcs12_b64: pkcs12Data.base64EncodedString(),
            client_tls_password: password,
            client_tls_cert_fingerprint_sha256: certFingerprintSha256.lowercased())
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
            client_tls_pkcs12_b64: nil,
            client_tls_password: nil,
            client_tls_cert_fingerprint_sha256: nil)

        let data = try JSONEncoder.pretty.encode(stored)
        try data.write(to: fileUrl, options: .atomic)
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
        let publicKey = privateKey.publicKey.rawRepresentation
        return ScanIdentityMaterial(
            deviceId: stored.device_id,
            certFingerprintSha256: Sha256.hex(of: publicKey),
            signingPublicKeyB64: publicKey.base64EncodedString(),
            signingPrivateKeyRawB64: privateKey.rawRepresentation.base64EncodedString())
    }

    private func persist() throws {
        let data = try JSONEncoder.pretty.encode(storedIdentity)
        try data.write(to: fileUrl, options: .atomic)
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
