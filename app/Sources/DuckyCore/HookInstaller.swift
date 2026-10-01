import Foundation

/// Adds or removes the agent indicator hooks in Claude Code's settings (`~/.claude/settings.json`), leaving every
/// other setting and hook as it is. Our entries are recognised by `ducky-agent-hook` in their command.
public enum HookInstaller {
    public enum Failure: Error, Equatable {
        case invalidSettings
    }

    static let marker = "ducky-agent-hook"
    public static let events = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure",
                                "PermissionRequest", "Notification", "Stop", "StopFailure", "SessionEnd"]

    public static func standardSettingsURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
    }

    static func command(for hookPath: String) -> String {
        "'\(hookPath.replacingOccurrences(of: "'", with: "'\\''"))' claude"
    }

    /// The settings with our hooks (replacing older ones); `settings` nil means no file yet.
    public static func installing(into settings: Data?, hookPath: String) throws -> Data {
        var root = try removingHooks(from: parse(settings))
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        // Synchronous: Claude Code runs them in event order, which the states rely on. The hook is quick and
        // never fails, so it never holds Claude up.
        let entry: [String: Any] = ["hooks": [["type": "command", "command": command(for: hookPath), "timeout": 5]]]
        for event in events {
            hooks[event] = (hooks[event] as? [Any] ?? []) + [entry]
        }
        root["hooks"] = hooks
        return try serialize(root)
    }

    public static func removing(from settings: Data) throws -> Data {
        try serialize(removingHooks(from: parse(settings)))
    }

    /// Every event runs our hook at `hookPath`.
    public static func isInstalled(_ settings: Data?, hookPath: String) -> Bool {
        guard let root = try? parse(settings), let hooks = root["hooks"] as? [String: Any] else { return false }
        let expected = command(for: hookPath)
        return events.allSatisfy { event in
            commands(in: hooks[event]).contains(expected)
        }
    }

    public static func install(settingsURL: URL, hookPath: String) throws {
        let current = try? Data(contentsOf: settingsURL)
        let updated = try installing(into: current, hookPath: hookPath)
        try write(updated, to: settingsURL, backingUp: current)
    }

    public static func uninstall(settingsURL: URL) throws {
        let current = try Data(contentsOf: settingsURL)
        try write(try removing(from: current), to: settingsURL, backingUp: current)
    }

    private static func write(_ data: Data, to url: URL, backingUp previous: Data?) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Keeps the settings as they were before Ducky RGB ever touched them.
        let backup = url.appendingPathExtension("ducky-backup")
        if let previous, !FileManager.default.fileExists(atPath: backup.path) {
            try previous.write(to: backup, options: .atomic)
        }
        try data.write(to: url, options: .atomic)
    }

    private static func parse(_ data: Data?) throws -> [String: Any] {
        guard let data, !data.isEmpty else { return [:] }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw Failure.invalidSettings }
        if let hooks = root["hooks"], !(hooks is [String: Any]) { throw Failure.invalidSettings }
        return root
    }

    private static func serialize(_ root: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    private static func commands(in groups: Any?) -> [String] {
        (groups as? [[String: Any]] ?? []).flatMap { ($0["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String } }
    }

    private static func removingHooks(from root: [String: Any]) -> [String: Any] {
        guard var hooks = root["hooks"] as? [String: Any] else { return root }
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            let kept: [[String: Any]] = groups.compactMap { group in
                guard let handlers = group["hooks"] as? [[String: Any]] else { return group }
                let others = handlers.filter { ($0["command"] as? String)?.contains(marker) != true }
                if others.isEmpty { return nil }
                var copy = group
                copy["hooks"] = others
                return copy
            }
            hooks[event] = kept.isEmpty ? nil : kept
        }
        var copy = root
        copy["hooks"] = hooks
        return copy
    }
}
