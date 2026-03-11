import Foundation
import ProvinodeRoomContracts

struct RecordedSessionSummary: Identifiable, Equatable {
    let id: String
    let sessionId: String
    let sourceDeviceId: String
    let captureStartedAtUtc: String
    let captureEndedAtUtc: String
    let sampleCount: Int64
    let blobCount: Int64
    let exported: Bool
    let integrityStatus: String
    let sessionDirectory: URL
    let exportPath: URL?

    var durationSummary: String {
        guard let started = ISO8601DateFormatter.recordedSessionFractional.date(from: captureStartedAtUtc),
              let ended = ISO8601DateFormatter.recordedSessionFractional.date(from: captureEndedAtUtc)
        else {
            return "-"
        }

        return String(format: "%.1fs", max(0, ended.timeIntervalSince(started)))
    }
}

enum RecordedSessionLibrary {
    static func sessionsDirectory(rootDirectory: URL? = nil) throws -> URL {
        if let rootDirectory {
            try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
            return rootDirectory
        }

        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true)
        return base.appending(path: "ProvinodeScan/Sessions", directoryHint: .isDirectory)
    }

    static func exportDirectory() -> URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return documents.appendingPathComponent("RoomCaptureExports", isDirectory: true)
    }

    static func list(rootDirectory: URL? = nil) throws -> [RecordedSessionSummary] {
        let root = try sessionsDirectory(rootDirectory: rootDirectory)
        guard FileManager.default.fileExists(atPath: root.path) else {
            return []
        }

        return try FileManager.default
            .contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .compactMap(readSummary(at:))
            .sorted { $0.captureStartedAtUtc > $1.captureStartedAtUtc }
    }

    static func exportSummary(for sessionDirectory: URL) -> URL? {
        let path = exportDirectory()
            .appendingPathComponent("\(sessionDirectory.lastPathComponent).roomcapture", isDirectory: true)
        return FileManager.default.fileExists(atPath: path.path) ? path : nil
    }

    private static func readSummary(at sessionDirectory: URL) -> RecordedSessionSummary? {
        let manifestUrl = sessionDirectory.appendingPathComponent("session.manifest.json", conformingTo: .json)
        let integrityUrl = sessionDirectory.appendingPathComponent("integrity.json", conformingTo: .json)
        guard let manifestData = try? Data(contentsOf: manifestUrl),
              let manifest = try? JSONDecoder().decode(RoomCaptureSessionManifest.self, from: manifestData)
        else {
            return nil
        }

        let integrityStatus: String
        if let integrityData = try? Data(contentsOf: integrityUrl),
           let integrity = try? JSONDecoder().decode(SessionIntegrityManifest.self, from: integrityData)
        {
            integrityStatus = integrity.manifest_sha256 == Sha256.hex(of: manifestData) ? "verified" : "hash_mismatch"
        } else {
            integrityStatus = "missing"
        }

        let exportPath = exportSummary(for: sessionDirectory)
        return RecordedSessionSummary(
            id: manifest.session_id,
            sessionId: manifest.session_id,
            sourceDeviceId: manifest.source_device_id,
            captureStartedAtUtc: manifest.capture_started_at_utc,
            captureEndedAtUtc: manifest.capture_ended_at_utc,
            sampleCount: manifest.sample_count,
            blobCount: manifest.blob_count,
            exported: exportPath != nil,
            integrityStatus: integrityStatus,
            sessionDirectory: sessionDirectory,
            exportPath: exportPath)
    }
}

private extension ISO8601DateFormatter {
    static var recordedSessionFractional: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }
}
