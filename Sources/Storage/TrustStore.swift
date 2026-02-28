import Foundation
import ProvinodeRoomContracts

actor TrustStore {
    private let fileUrl: URL
    private var recordsByDeviceId: [String: TrustRecord] = [:]

    init(rootDirectory: URL? = nil) throws {
        let root = try rootDirectory ?? Self.defaultRootDirectory()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        fileUrl = root.appendingPathComponent("trust-records.json", conformingTo: .json)
        try load()
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

    private func load() throws {
        guard FileManager.default.fileExists(atPath: fileUrl.path) else {
            return
        }

        let data = try Data(contentsOf: fileUrl)
        recordsByDeviceId = try JSONDecoder().decode([String: TrustRecord].self, from: data)
    }

    private func persist() throws {
        let data = try JSONEncoder.pretty.encode(recordsByDeviceId)
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
