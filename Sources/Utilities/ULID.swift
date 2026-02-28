import Foundation
import Security

struct ULID {
    private static let crockford = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    static func generate(date: Date = .now) -> String {
        let milliseconds = UInt64(date.timeIntervalSince1970 * 1000.0)
        var timeBytes = withUnsafeBytes(of: milliseconds.bigEndian, Array.init)
        timeBytes.removeFirst(2)

        var randomBytes = [UInt8](repeating: 0, count: 10)
        let status = SecRandomCopyBytes(kSecRandomDefault, randomBytes.count, &randomBytes)
        if status != errSecSuccess {
            randomBytes = (0..<10).map { _ in UInt8.random(in: .min ... .max) }
        }

        let bytes = timeBytes + randomBytes
        return encodeBase32(bytes)
    }

    private static func encodeBase32(_ bytes: [UInt8]) -> String {
        var output = ""
        output.reserveCapacity(26)

        var buffer = 0
        var bitsLeft = 0

        for byte in bytes {
            buffer = (buffer << 8) | Int(byte)
            bitsLeft += 8
            while bitsLeft >= 5 {
                let index = (buffer >> (bitsLeft - 5)) & 0x1F
                output.append(crockford[index])
                bitsLeft -= 5
            }
        }

        if bitsLeft > 0 {
            let index = (buffer << (5 - bitsLeft)) & 0x1F
            output.append(crockford[index])
        }

        return String(output.prefix(26))
    }
}
