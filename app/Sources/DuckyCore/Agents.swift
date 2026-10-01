import Foundation

/// What an agent session is doing, as shown on its indicator key.
public enum AgentState: String, Codable, CaseIterable, Sendable {
    case idle, unread, thinking, waiting, error

    public var color: RGB {
        switch self {
        case .idle: return RGB(255, 255, 255)
        case .unread: return RGB(0, 255, 40)
        case .thinking: return RGB(0, 90, 255)
        case .waiting: return RGB(255, 110, 0)
        case .error: return RGB(255, 0, 0)
        }
    }

    /// Thinking and waiting breathe on the keyboard, the others are steady.
    public var breathing: Bool { self == .thinking || self == .waiting }

    public var label: String {
        switch self {
        case .idle: return "Au repos"
        case .unread: return "Réponse non lue"
        case .thinking: return "Réfléchit"
        case .waiting: return "Attend ta validation"
        case .error: return "Erreur"
        }
    }
}

/// One agent session, as written by `ducky-agent-hook` (one JSON file per session).
public struct AgentSession: Codable, Equatable, Identifiable, Sendable {
    public var source: String
    public var sessionID: String
    public var state: AgentState
    public var cwd: String
    public var title: String?
    public var firstPrompt: String?
    /// Terminal device of the session's process, e.g. "ttys003"; nil without a terminal.
    public var tty: String?
    /// The agent's process: the session is gone when it dies. 0 when unknown.
    public var pid: Int32
    /// While waiting: the tool call (id, else tool name) whose permission or answer is pending.
    public var waitingFor: String?
    /// The session's transcript, read to notice interrupted turns.
    public var transcriptPath: String?
    /// Background job id: such a session is viewed from a Terminal tab running `claude attach <job>`.
    public var jobID: String?
    public var startedAt: Date
    public var updatedAt: Date

    public init(source: String = "claude", sessionID: String, state: AgentState, cwd: String, title: String? = nil,
                firstPrompt: String? = nil, tty: String? = nil, pid: Int32, startedAt: Date, updatedAt: Date? = nil) {
        self.source = source
        self.sessionID = sessionID
        self.state = state
        self.cwd = cwd
        self.title = title
        self.firstPrompt = firstPrompt
        self.tty = tty
        self.pid = pid
        self.startedAt = startedAt
        self.updatedAt = updatedAt ?? startedAt
    }

    /// Stable key and file name; only safe characters of the session id are kept.
    public var id: String { Self.id(source: source, sessionID: sessionID) }

    public static func id(source: String = "claude", sessionID: String) -> String {
        let safe = sessionID.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" }
        return "\(source)-\(String(String.UnicodeScalarView(safe)))"
    }

    /// The session title, else the folder name and the start of the first message.
    public var displayName: String {
        if let title, !title.isEmpty { return title }
        let folder = URL(fileURLWithPath: cwd).lastPathComponent
        guard let firstPrompt, !firstPrompt.isEmpty else { return folder }
        return "\(folder) · \(firstPrompt)"
    }
}

/// The fields of a Claude Code hook input that the indicators use.
public struct HookEvent: Decodable, Sendable {
    public var sessionID: String
    public var name: String
    public var cwd: String?
    public var toolName: String?
    public var notificationType: String?
    public var prompt: String?
    public var sessionTitle: String?
    public var toolUseID: String?
    /// Set when the event comes from a subagent.
    public var agentID: String?
    /// SessionStart: startup, resume, clear, compact.
    public var source: String?
    public var transcriptPath: String?

    public init(sessionID: String, name: String, cwd: String? = nil, toolName: String? = nil, notificationType: String? = nil,
                prompt: String? = nil, sessionTitle: String? = nil, toolUseID: String? = nil, agentID: String? = nil,
                source: String? = nil) {
        self.sessionID = sessionID
        self.name = name
        self.cwd = cwd
        self.toolName = toolName
        self.notificationType = notificationType
        self.prompt = prompt
        self.sessionTitle = sessionTitle
        self.toolUseID = toolUseID
        self.agentID = agentID
        self.source = source
    }

    /// Identifies a tool call: its id, else its tool name.
    var toolKey: String? { toolUseID ?? toolName }

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id", name = "hook_event_name", cwd, toolName = "tool_name"
        case notificationType = "notification_type", prompt, sessionTitle = "session_title"
        case toolUseID = "tool_use_id", agentID = "agent_id", source, transcriptPath = "transcript_path"
    }
}

/// Hook event -> session state (spec section 2).
public enum AgentTransition {
    public enum Outcome: Sendable {
        case write(AgentSession)
        case delete
        case ignore
    }

    static let promptPreviewLength = 40

    public static func apply(_ event: HookEvent, to existing: AgentSession?, pid: Int32, tty: String?, now: Date) -> Outcome {
        if event.name == "SessionEnd" { return .delete }
        let change = existing.map { stateChange(for: event, from: $0) } ?? .to(.idle)
        guard case .to(let state) = change else { return .ignore }
        var session = existing ?? AgentSession(sessionID: event.sessionID, state: .idle, cwd: event.cwd ?? "", pid: pid, startedAt: now)
        if state == .waiting {
            session.waitingFor = event.toolKey ?? session.waitingFor
        } else {
            session.waitingFor = nil
        }
        session.state = state
        session.updatedAt = now
        if pid != 0 { session.pid = pid } // keeps a known pid when this event could not find the process
        if let tty { session.tty = tty }
        if let cwd = event.cwd, !cwd.isEmpty { session.cwd = cwd }
        if let path = event.transcriptPath, !path.isEmpty { session.transcriptPath = path }
        if let title = event.sessionTitle, !title.isEmpty { session.title = title }
        if session.firstPrompt == nil, let prompt = event.prompt.map(preview), !prompt.isEmpty { session.firstPrompt = prompt }
        return .write(session)
    }

    private enum Change {
        case to(AgentState)
        case keep
    }

    private static func stateChange(for event: HookEvent, from session: AgentSession) -> Change {
        let toolEvents: Set<String> = ["PreToolUse", "PostToolUse", "PostToolUseFailure", "PermissionRequest"]
        // Background subagents keep using tools after the turn ended: they do not reopen it.
        if event.agentID != nil, toolEvents.contains(event.name), [.unread, .idle, .error].contains(session.state) { return .keep }
        switch event.name {
        case "SessionStart":
            return event.source == "compact" ? .keep : .to(.idle) // compaction happens mid-turn
        case "UserPromptSubmit":
            return .to(.thinking)
        case "PreToolUse":
            if event.toolName == "AskUserQuestion" { return .to(.waiting) }
            return session.state == .waiting ? .keep : .to(.thinking)
        case "PostToolUse", "PostToolUseFailure":
            // Only the pending call itself ends a wait; other (parallel) tools do not.
            if session.state == .waiting, let pending = session.waitingFor, pending != event.toolUseID, pending != event.toolName {
                return .keep
            }
            return .to(.thinking)
        case "PermissionRequest":
            return .to(.waiting)
        case "Notification":
            switch event.notificationType {
            case "permission_prompt", "elicitation_dialog": return .to(.waiting)
            // Claude waits for input: a turn interrupted with Esc never sends Stop.
            case "idle_prompt": return [.thinking, .waiting].contains(session.state) ? .to(.idle) : .keep
            default: return .keep
            }
        case "Stop":
            return .to(.unread)
        case "StopFailure":
            return .to(.error)
        default:
            return .keep
        }
    }

    private static func preview(_ prompt: String) -> String {
        let words = prompt.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return words.count > promptPreviewLength ? String(words.prefix(promptPreviewLength)) + "…" : words
    }
}

/// The session files: one JSON per session in a directory, written atomically under a lock shared by the hook
/// and the app.
public struct AgentStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public static func standard() -> AgentStore {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return AgentStore(directory: support.appendingPathComponent("Ducky RGB/agents"))
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private func url(for id: String) -> URL { directory.appendingPathComponent("\(id).json") }

    /// Every readable session; unreadable files are skipped.
    public func load() -> [AgentSession] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? Self.decoder.decode(AgentSession.self, from: Data(contentsOf: $0)) }
            .sorted { ($0.startedAt, $0.id) < ($1.startedAt, $1.id) }
    }

    public func write(_ session: AgentSession) throws {
        try withLock { try save(session) }
    }

    public func delete(id: String) throws {
        try withLock { try? FileManager.default.removeItem(at: url(for: id)) }
    }

    /// Reads, changes and writes one session under the lock.
    public func update(id: String, _ change: (AgentSession?) -> AgentTransition.Outcome) throws {
        try withLock {
            let existing = try? Self.decoder.decode(AgentSession.self, from: Data(contentsOf: url(for: id)))
            switch change(existing) {
            case .write(let session): try save(session)
            case .delete: try? FileManager.default.removeItem(at: url(for: id))
            case .ignore: break
            }
        }
    }

    private func save(_ session: AgentSession) throws {
        try Self.encoder.encode(session).write(to: url(for: session.id), options: .atomic)
    }

    private func withLock<T>(_ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fd = open(directory.appendingPathComponent(".lock").path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        defer { close(fd) }
        flock(fd, LOCK_EX)
        defer { flock(fd, LOCK_UN) }
        return try body()
    }
}
