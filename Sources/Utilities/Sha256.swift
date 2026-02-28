import CryptoKit
import Foundation

enum Sha256 {
    static func hex(of data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func hex(of string: String) -> String {
        hex(of: Data(string.utf8))
    }
}
