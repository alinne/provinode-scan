import Foundation

enum StructuredLog {
    static func emit(
        event: String,
        level: String = "info",
        fields: [String: String] = [:]
    ) {
        var payload = fields
        payload["event"] = event
        payload["level"] = level
        payload["timestamp_utc"] = ISO8601DateFormatter.fractional.string(from: .now)

        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8)
        {
            NSLog("%@", text)
        } else {
            NSLog("[%@] %@", level, event)
        }
    }
}

private extension ISO8601DateFormatter {
    static var fractional: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }
}
