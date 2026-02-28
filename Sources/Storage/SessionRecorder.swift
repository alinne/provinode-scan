import Foundation
import ProvinodeRoomContracts

actor SessionRecorder {
    private let sessionId: String
    private let sourceDeviceId: String
    private let producerVersion: String
    private let sessionRoot: URL
    private let blobsRoot: URL
    private let samplesLogUrl: URL
    private let manifestUrl: URL
    private let integrityUrl: URL

    private var sampleCount: Int64 = 0
    private var blobCount: Int64 = 0
    private var startedAtUtc: Date
    private var endedAtUtc: Date
    private var blobHashes: [String: String] = [:]

    init(sessionId: String, sourceDeviceId: String, producerVersion: String, rootDirectory: URL? = nil) throws {
        self.sessionId = sessionId
        self.sourceDeviceId = sourceDeviceId
        self.producerVersion = producerVersion

        let root = try rootDirectory ?? Self.defaultSessionsDirectory()
        sessionRoot = root.appendingPathComponent(sessionId, isDirectory: true)
        blobsRoot = sessionRoot.appending(path: "blobs/sha256", directoryHint: .isDirectory)
        samplesLogUrl = sessionRoot.appendingPathComponent("samples.log", conformingTo: .text)
        manifestUrl = sessionRoot.appendingPathComponent("session.manifest.json", conformingTo: .json)
        integrityUrl = sessionRoot.appendingPathComponent("integrity.json", conformingTo: .json)

        startedAtUtc = .now
        endedAtUtc = startedAtUtc

        try prepareDirectories()
    }

    func record(envelope: CaptureSampleEnvelope, payload: Data) throws {
        let hash = Sha256.hex(of: payload)
        guard hash == envelope.hash_sha256 else {
            throw NSError(domain: "SessionRecorder", code: 1001, userInfo: [NSLocalizedDescriptionKey: "Payload hash mismatch"])
        }

        let blobUrl = blobsRoot.appendingPathComponent(hash)
        if !FileManager.default.fileExists(atPath: blobUrl.path) {
            try payload.write(to: blobUrl, options: .atomic)
            blobCount += 1
        }
        blobHashes["blobs/sha256/\(hash)"] = hash

        let entry = RoomCaptureSampleIndexEntry(
            sample_seq: envelope.sample_seq,
            sample_kind: envelope.sample_kind,
            capture_time_ns: envelope.capture_time_ns,
            hash_sha256: hash,
            blob_path: "blobs/sha256/\(hash)",
            byte_size: Int64(payload.count))

        let lineData = try JSONEncoder.stable.encode(entry)
        try appendLogLine(lineData)

        sampleCount += 1
        endedAtUtc = Date()
    }

    func finalize(extraMetadata: [String: String] = [:]) throws -> URL {
        let metadata = [
            "room.session_id": sessionId,
            "room.schema_version": RoomContractVersions.roomCaptureSessionManifest,
            "source_device_id": sourceDeviceId,
            "capture_started_at_utc": ISO8601DateFormatter.fractional.string(from: startedAtUtc)
        ].merging(extraMetadata, uniquingKeysWith: { _, new in new })

        let manifest = RoomCaptureSessionManifest(
            schema_version: RoomContractVersions.roomCaptureSessionManifest,
            session_id: sessionId,
            source_device_id: sourceDeviceId,
            capture_started_at_utc: ISO8601DateFormatter.fractional.string(from: startedAtUtc),
            capture_ended_at_utc: ISO8601DateFormatter.fractional.string(from: endedAtUtc),
            sample_count: sampleCount,
            blob_count: blobCount,
            samples_log_path: "samples.log",
            integrity_path: "integrity.json",
            producer_app_version: producerVersion,
            metadata: metadata)

        let manifestData = try JSONEncoder.pretty.encode(manifest)
        try manifestData.write(to: manifestUrl, options: .atomic)

        let samplesData = try Data(contentsOf: samplesLogUrl)
        let integrity = SessionIntegrityManifest(
            manifest_sha256: Sha256.hex(of: manifestData),
            samples_log_sha256: Sha256.hex(of: samplesData),
            blob_hashes: blobHashes,
            provenance_digest: Sha256.hex(of: "\(sessionId):\(sampleCount):\(blobCount)"))

        let integrityData = try JSONEncoder.pretty.encode(integrity)
        try integrityData.write(to: integrityUrl, options: .atomic)

        return sessionRoot
    }

    func export(to destinationDirectory: URL) throws -> URL {
        let destination = destinationDirectory.appendingPathComponent("\(sessionId).roomcapture", isDirectory: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: sessionRoot, to: destination)
        return destination
    }

    private func prepareDirectories() throws {
        try FileManager.default.createDirectory(at: blobsRoot, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: samplesLogUrl.path) {
            FileManager.default.createFile(atPath: samplesLogUrl.path, contents: nil)
        }
    }

    private func appendLogLine(_ json: Data) throws {
        guard let handle = try? FileHandle(forWritingTo: samplesLogUrl) else {
            throw NSError(domain: "SessionRecorder", code: 1002, userInfo: [NSLocalizedDescriptionKey: "Unable to open samples.log"])
        }
        defer { try? handle.close() }

        try handle.seekToEnd()
        handle.write(json)
        handle.write(Data([0x0A]))
    }

    private static func defaultSessionsDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true)
        return base.appending(path: "ProvinodeScan/Sessions", directoryHint: .isDirectory)
    }
}

private extension JSONEncoder {
    static var stable: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

private extension ISO8601DateFormatter {
    static var fractional: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }
}
