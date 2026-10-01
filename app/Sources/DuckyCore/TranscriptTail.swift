import Foundation

/// Reads the end of a Claude Code transcript (JSON lines). An interrupted turn (Esc) sends no hook; Claude only
/// appends a "[Request interrupted by user…]" user message.
public enum TranscriptTail {
    static let tailSize = 64 * 1024
    private static let marker = "[Request interrupted by user"

    /// When the last exchanged message is an interruption: its time; otherwise nil.
    public static func interruption(in tail: Data) -> Date? {
        let lines = String(decoding: tail, as: UTF8.self).split(separator: "\n")
        for line in lines.reversed() {
            guard let entry = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  let type = entry["type"] as? String, type == "user" || type == "assistant" else { continue }
            guard type == "user", text(of: entry).hasPrefix(marker), let stamp = entry["timestamp"] as? String else { return nil }
            return date(stamp)
        }
        return nil
    }

    /// The last `tailSize` bytes of the file; the first, possibly cut, line simply fails to parse.
    public static func read(path: String) -> Data? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return nil }
        try? handle.seek(toOffset: end > UInt64(tailSize) ? end - UInt64(tailSize) : 0)
        return try? handle.readToEnd()
    }

    private static func text(of entry: [String: Any]) -> String {
        let content = (entry["message"] as? [String: Any])?["content"]
        if let text = content as? String { return text }
        return (content as? [[String: Any]])?.first?["text"] as? String ?? ""
    }

    private static func date(_ stamp: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: stamp) ?? ISO8601DateFormatter().date(from: stamp)
    }
}
