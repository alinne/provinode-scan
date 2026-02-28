import CryptoKit
import Foundation
import ProvinodeRoomContracts

actor TrustStore {
    private static let encryptedDocumentFormat = "provinode.scan.trust.v1"
    private static let encryptionInfo = Data("provinode.scan.trust.records.aes-gcm.v1".utf8)

    private struct EncryptedTrustStoreDocument: Codable {
        let format: String
        let nonce_b64: String
        let ciphertext_b64: String
        let tag_b64: String
    }

    private let fileUrl: URL
    private let keyFileUrl: URL
    private let encryptionKey: SymmetricKey
    private var recordsByDeviceId: [String: TrustRecord] = [:]

    init(rootDirectory: URL? = nil) throws {
        let root = try rootDirectory ?? Self.defaultRootDirectory()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        fileUrl = root.appendingPathComponent("trust-records.json", conformingTo: .json)
        keyFileUrl = root.appendingPathComponent("trust-records.key", conformingTo: .data)
        encryptionKey = try Self.loadOrCreateEncryptionKey(keyFileUrl: keyFileUrl)
        recordsByDeviceId = try Self.load(fileUrl: fileUrl, using: encryptionKey)
    }

    func upsert(_ record: TrustRecord) throws {
        recordsByDeviceId[record.peer_device_id] = record
        try persist()
    }

    func trustedPeer(deviceId: String) -> TrustRecord? {
        recordsByDeviceId[deviceId]
    }

    func all() -> [TrustRecord] {
        recordsByDeviceId.values.sorted { $0.peer_device_id < $1.peer_device_id }
    }

    private static func load(fileUrl: URL, using key: SymmetricKey) throws -> [String: TrustRecord] {
        guard FileManager.default.fileExists(atPath: fileUrl.path) else {
            return [:]
        }

        let data = try Data(contentsOf: fileUrl)
        guard !data.isEmpty else {
            return [:]
        }

        if let encrypted = try decodeEncryptedDocument(data) {
            let plaintext = try decrypt(encrypted: encrypted, using: key)
            return try JSONDecoder().decode([String: TrustRecord].self, from: plaintext)
        }

        // Legacy plaintext support for migration compatibility.
        return try JSONDecoder().decode([String: TrustRecord].self, from: data)
    }

    private func persist() throws {
        let plaintext = try JSONEncoder.pretty.encode(recordsByDeviceId)
        let encrypted = try Self.encrypt(plaintext: plaintext, using: encryptionKey)
        let data = try JSONEncoder.pretty.encode(encrypted)
        try data.write(to: fileUrl, options: .atomic)
        try? Self.applyProtectedFileAttributes(to: fileUrl)
    }

    private static func loadOrCreateEncryptionKey(keyFileUrl: URL) throws -> SymmetricKey {
        if FileManager.default.fileExists(atPath: keyFileUrl.path) {
            let data = try Data(contentsOf: keyFileUrl)
            guard let base64 = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  let keyData = Data(base64Encoded: base64),
                  keyData.count == 32
            else {
                throw NSError(
                    domain: "TrustStore",
                    code: 5001,
                    userInfo: [NSLocalizedDescriptionKey: "Stored trust store key was invalid."])
            }
            return SymmetricKey(data: keyData)
        }

        let keyData = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
        guard let encoded = keyData.base64EncodedString().data(using: .utf8) else {
            throw NSError(
                domain: "TrustStore",
                code: 5004,
                userInfo: [NSLocalizedDescriptionKey: "Failed to encode trust store key material."])
        }
        try encoded.write(to: keyFileUrl, options: .atomic)
        try? applyProtectedFileAttributes(to: keyFileUrl)
        return SymmetricKey(data: keyData)
    }

    private static func decodeEncryptedDocument(_ data: Data) throws -> EncryptedTrustStoreDocument? {
        let json = try JSONSerialization.jsonObject(with: data)
        guard let object = json as? [String: Any],
              let format = object["format"] as? String,
              format == encryptedDocumentFormat
        else {
            return nil
        }

        return try JSONDecoder().decode(EncryptedTrustStoreDocument.self, from: data)
    }

    private static func encrypt(plaintext: Data, using key: SymmetricKey) throws -> EncryptedTrustStoreDocument {
        let sealedBox = try AES.GCM.seal(plaintext, using: key, authenticating: encryptionInfo)
        let nonceData = sealedBox.nonce.withUnsafeBytes { Data($0) }
        guard nonceData.count == 12 else {
            throw NSError(
                domain: "TrustStore",
                code: 5002,
                userInfo: [NSLocalizedDescriptionKey: "Failed to generate trust store encryption nonce."])
        }

        return EncryptedTrustStoreDocument(
            format: encryptedDocumentFormat,
            nonce_b64: nonceData.base64EncodedString(),
            ciphertext_b64: sealedBox.ciphertext.base64EncodedString(),
            tag_b64: sealedBox.tag.base64EncodedString())
    }

    private static func decrypt(encrypted: EncryptedTrustStoreDocument, using key: SymmetricKey) throws -> Data {
        guard let nonceData = Data(base64Encoded: encrypted.nonce_b64),
              let ciphertext = Data(base64Encoded: encrypted.ciphertext_b64),
              let tag = Data(base64Encoded: encrypted.tag_b64)
        else {
            throw NSError(
                domain: "TrustStore",
                code: 5003,
                userInfo: [NSLocalizedDescriptionKey: "Encrypted trust store payload was invalid base64."])
        }

        let nonce = try AES.GCM.Nonce(data: nonceData)
        let sealedBox = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
        return try AES.GCM.open(sealedBox, using: key, authenticating: encryptionInfo)
    }

    private static func applyProtectedFileAttributes(to url: URL) throws {
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path)

        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableUrl = url
        try? mutableUrl.setResourceValues(values)
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
