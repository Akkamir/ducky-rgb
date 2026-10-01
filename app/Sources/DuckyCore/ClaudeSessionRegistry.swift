import Darwin
import Foundation

/// Claude Code's own registry of running sessions: `~/.claude/sessions/<pid>.json`, one file per Claude process
/// (undocumented; every field is optional here and a missing directory means no entries).
public struct ClaudeSessionRegistry: Sendable {
    public struct Entry: Decodable, Equatable, Sendable {
        public var pid: Int32
        public var sessionId: String
        public var cwd: String?
        /// Milliseconds since 1970.
        public var startedAt: Double?
        public var name: String?
        /// "derived" names (folder plus counter) are not titles; "auto" and user names are.
        public var nameSource: String?
        /// "busy" or "idle".
        public var status: String?
        /// "interactive" or "bg" (background job, viewed with `claude attach <jobId>`).
        public var kind: String?
        public var jobId: String?

        public var title: String? {
            guard let name, !name.isEmpty, nameSource != "derived" else { return nil }
            return name
        }
    }

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public static func standard() -> ClaudeSessionRegistry {
        ClaudeSessionRegistry(directory: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/sessions"))
    }

    public func entries() -> [Entry] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder().decode(Entry.self, from: Data(contentsOf: $0)) }
    }
}

/// Process details from the kernel.
public enum ProcessDetails {
    /// Parent pid and controlling terminal name (e.g. "ttys003", nil without one).
    public static func info(_ pid: Int32) -> (parent: Int32, tty: String?)? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let device = info.kp_eproc.e_tdev
        var tty: String?
        if device != -1, let name = devname(device, S_IFCHR) { tty = String(cString: name) } // -1: no terminal
        return (info.kp_eproc.e_ppid, tty)
    }

    public static func tty(of pid: Int32) -> String? { info(pid)?.tty }

    /// Job id -> tty of each process running `claude attach <job>` (how background sessions are viewed).
    public static func attachedTabs() -> [String: String] {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-axo", "tty=,command="]
        let pipe = Pipe()
        ps.standardOutput = pipe
        ps.standardError = FileHandle.nullDevice
        guard (try? ps.run()) != nil else { return [:] }
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        ps.waitUntilExit()
        return attachedTabs(fromPS: String(decoding: output, as: UTF8.self))
    }

    static func attachedTabs(fromPS output: String) -> [String: String] {
        var tabs: [String: String] = [:]
        for line in output.split(separator: "\n") {
            let words = line.split(separator: " ")
            guard words.count >= 4, words[0].hasPrefix("tty"),
                  let attach = words.firstIndex(of: "attach"), attach > 1, attach + 1 < words.count,
                  words[attach - 1].hasSuffix("claude") else { continue }
            tabs[String(words[attach + 1])] = String(words[0])
        }
        return tabs
    }

    public static func path(of pid: Int32) -> String {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return "" }
        return String(cString: buffer)
    }
}
