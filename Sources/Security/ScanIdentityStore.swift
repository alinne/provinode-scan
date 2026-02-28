import CryptoKit
import Foundation

struct ScanIdentityMaterial: Sendable {
    let deviceId: String
    let certFingerprintSha256: String
    let signingPublicKeyB64: String
    let signingPrivateKeyRawB64: String
}

final class ScanIdentityStore {
    private struct StoredIdentity: Codable {
        let device_id: String
        let signing_private_key_raw_b64: String
    }

    private let materialValue: ScanIdentityMaterial

    init(rootDirectory: URL? = nil) throws {
        let root = try rootDirectory ?? Self.defaultRootDirectory()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fileUrl = root.appendingPathComponent("scan-identity.json", conformingTo: .json)
        materialValue = try Self.loadOrCreate(fileUrl: fileUrl)
    }

    func material() -> ScanIdentityMaterial {
        materialValue
    }

    private static func loadOrCreate(fileUrl: URL) throws -> ScanIdentityMaterial {
        if FileManager.default.fileExists(atPath: fileUrl.path) {
            let data = try Data(contentsOf: fileUrl)
            let stored = try JSONDecoder().decode(StoredIdentity.self, from: data)
            return try material(from: stored)
        }

        let key = P256.Signing.PrivateKey()
        let stored = StoredIdentity(
            device_id: ULID.generate(),
            signing_private_key_raw_b64: key.rawRepresentation.base64EncodedString())

        let data = try JSONEncoder.pretty.encode(stored)
        try data.write(to: fileUrl, options: .atomic)
        return try material(from: stored)
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
