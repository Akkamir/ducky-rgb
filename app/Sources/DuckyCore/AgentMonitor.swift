import Foundation
import Observation

/// Terminal.app access: which tab is in front, and bringing a tab to the front.
/// Both may block (Apple events, a permission prompt): they run off the main thread.
public protocol TerminalControlling: AnyObject, Sendable {
    /// The tty (e.g. "ttys003") of the selected tab of Terminal's front window while Terminal is the active app; nil
    /// otherwise, and nil without asking for permission when access was never granted.
    func frontmostTTY() async -> String?
    /// Brings the tab using this tty to the front (may ask for permission).
    func focus(tty: String) async -> TerminalFocusResult
    /// Asks for the Automation permission (shows the system prompt the first time).
    func requestAccess() async -> TerminalFocusResult
}

public enum TerminalFocusResult: Equatable, Sendable {
    case shown
    case terminalNotRunning
    case tabNotFound
    case accessDenied
    /// Any other Apple Event error code.
    case failed(Int32)

    public var message: String? {
        switch self {
        case .shown: return nil
        case .terminalNotRunning: return "Terminal n'est pas ouvert."
        case .tabNotFound: return "Onglet Terminal introuvable pour cette session."
        case .accessDenied:
            return "Accès à Terminal refusé : active Ducky RGB > Terminal dans Réglages Système > Confidentialité et sécurité > "
                + "Automatisation (ou clique sur « Autoriser Terminal »)."
        case .failed(let code): return "Impossible de piloter Terminal (erreur \(code))."
        }
    }
}

/// Agent sessions from the hook's files, their indicator keys, and what Fn + an agent key does.
@MainActor
@Observable
public final class AgentMonitor {
    private enum Keys {
        static let enabled = "agents.enabled"
        static let brightness = "agents.brightness"
    }

    /// Delete, Page Up, Page Down.
    public static let keyNames = ["delete", "pageup", "pagedown"]
    public static let keyLabels = ["Suppr", "PgUp", "PgDn"]
    private static let leds: [UInt8] = keyNames.map { UInt8(KeyboardLayout.index(named: $0)!) }

    /// Sessions by arrival.
    public private(set) var sessions: [AgentSession] = []
    public private(set) var assignment = SlotAssignment()
    /// Set when Terminal could not be driven (access refused, tab not found).
    public private(set) var terminalProblem: String?
    /// Result of the last "Autoriser Terminal" request.
    public private(set) var terminalAccessGranted: Bool?

    public var isEnabled: Bool {
        didSet {
            defaults.set(isEnabled, forKey: Keys.enabled)
            pushIndicators()
        }
    }

    /// Indicator brightness, 0.1...1.
    public var brightness: Double {
        didSet {
            defaults.set(brightness, forKey: Keys.brightness)
            pushIndicators()
        }
    }

    private let store: AgentStore
    private let controller: LightingController
    private let terminal: TerminalControlling
    private let defaults: UserDefaults
    private let isAlive: (Int32) -> Bool
    private let registry: ClaudeSessionRegistry?
    private let ttyOf: (Int32) -> String?
    private let attachedTabs: () -> [String: String]
    private var loop: Task<Void, Never>?
    private var watcher: DispatchSourceFileSystemObject?
    private var checkingFront = false
    /// A session whose process could not be found (pid 0) is dropped after this long without events.
    static let unknownPidLifetime: TimeInterval = 12 * 3600

    public init(store: AgentStore, controller: LightingController, terminal: TerminalControlling, defaults: UserDefaults = .standard,
                registry: ClaudeSessionRegistry? = .standard(), ttyOf: @escaping (Int32) -> String? = ProcessDetails.tty(of:),
                attachedTabs: @escaping () -> [String: String] = ProcessDetails.attachedTabs,
                isAlive: @escaping (Int32) -> Bool = AgentMonitor.processIsAlive, autoRefresh: Bool = true) {
        self.store = store
        self.controller = controller
        self.terminal = terminal
        self.defaults = defaults
        self.isAlive = isAlive
        self.registry = registry
        self.ttyOf = ttyOf
        self.attachedTabs = attachedTabs
        isEnabled = defaults.object(forKey: Keys.enabled) as? Bool ?? true
        brightness = defaults.object(forKey: Keys.brightness) as? Double ?? 0.6
        controller.onAgentKey = { [weak self] slot in self?.activate(slot: slot) }
        if autoRefresh { start() }
    }

    public nonisolated static func processIsAlive(_ pid: Int32) -> Bool {
        pid > 0 && (kill(pid, 0) == 0 || errno == EPERM)
    }

    /// Re-reads the sessions every second, and at once when a session file changes.
    private func start() {
        try? FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        let fd = open(store.directory.path, O_EVTONLY)
        if fd >= 0 {
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
            source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.refresh() } }
            source.setCancelHandler { close(fd) }
            source.resume()
            watcher = source
        }
        loop = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.refresh()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    public func refresh(now: Date = Date()) {
        syncWithRegistry(now: now)
        var loaded = store.load()
        let gone = loaded.filter { isGone($0, now: now) }
        for session in gone {
            // The agent died without ending its session; checked again under the lock, as a resumed session may
            // have just written a new process.
            try? store.update(id: session.id) { existing in
                guard let existing, existing.pid == session.pid, isGone(existing, now: now) else { return .ignore }
                return .delete
            }
        }
        loaded.removeAll { session in gone.contains { $0.id == session.id } }
        sessions = loaded
        for session in sessions where session.state == .thinking || session.state == .waiting {
            // Esc sends no hook: the transcript tells when the turn was interrupted after the last event.
            guard let path = session.transcriptPath, let tail = TranscriptTail.read(path: path),
                  let interrupted = TranscriptTail.interruption(in: tail), interrupted > session.updatedAt else { continue }
            markInterrupted(session.id, since: session.updatedAt)
        }
        assignment.update(sessions: sessions)
        pushIndicators()
        checkFrontTab()
    }

    /// Running Claude sessions show up even before their first hook event; a session replaced in its process
    /// (/clear, /resume) goes away; Claude's own session names become titles.
    private func syncWithRegistry(now: Date) {
        guard let registry else { return }
        let entries = registry.entries().filter { isAlive($0.pid) }
        guard !entries.isEmpty else { return }
        let byPid = Dictionary(entries.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        for session in store.load() where session.pid > 0 {
            guard let entry = byPid[session.pid], entry.sessionId != session.sessionID else { continue }
            try? store.update(id: session.id) { existing in
                guard let existing, existing.pid == session.pid, existing.sessionID != entry.sessionId else { return .ignore }
                return .delete
            }
        }
        for entry in entries {
            try? store.update(id: AgentSession.id(sessionID: entry.sessionId)) { existing in
                let jobID = entry.kind == "bg" ? entry.jobId : nil
                if var session = existing {
                    let title = entry.title ?? session.title
                    guard session.title != title || session.jobID != jobID else { return .ignore }
                    session.title = title
                    session.jobID = jobID
                    return .write(session)
                }
                let started = entry.startedAt.map { Date(timeIntervalSince1970: $0 / 1000) } ?? now
                var session = AgentSession(sessionID: entry.sessionId, state: entry.status == "busy" ? .thinking : .idle,
                                           cwd: entry.cwd ?? "", title: entry.title, tty: ttyOf(entry.pid), pid: entry.pid,
                                           startedAt: started)
                session.jobID = jobID
                return .write(session)
            }
        }
    }

    private func isGone(_ session: AgentSession, now: Date) -> Bool {
        session.pid == 0 ? now.timeIntervalSince(session.updatedAt) > Self.unknownPidLifetime : !isAlive(session.pid)
    }

    /// An unread answer whose Terminal tab is in front has been seen.
    private func checkFrontTab() {
        let unread = sessions.filter { $0.state == .unread }
        guard !checkingFront, !unread.isEmpty else { return }
        let tabs = unread.contains { $0.jobID != nil } ? attachedTabs() : [:]
        let views = Dictionary(uniqueKeysWithValues: unread.map { ($0.id, viewTTYs($0, attached: tabs)) })
        guard views.values.contains(where: { !$0.isEmpty }) else { return }
        checkingFront = true
        Task { @MainActor [weak self, terminal] in
            let front = await terminal.frontmostTTY()
            guard let self else { return }
            self.checkingFront = false
            guard let front else { return }
            for (id, ttys) in views where ttys.contains(front) {
                self.markRead(id)
            }
            self.pushIndicators()
        }
    }

    /// Terminal tabs showing a session: the `claude attach` tab of a background job first, then its own terminal.
    private func viewTTYs(_ session: AgentSession, attached: [String: String]) -> [String] {
        var ttys: [String] = []
        if let job = session.jobID, let tab = attached[job] { ttys.append(tab) }
        if let tty = session.tty, session.jobID == nil { ttys.append(tty) } // a job's own pty is not a tab
        return ttys
    }

    public func slot(of id: String) -> Int? { assignment.slots[id] }

    public func choose(_ choice: SlotAssignment.Choice, for id: String) {
        assignment.choose(choice, for: id, sessions: sessions)
        pushIndicators()
    }

    /// Fn + agent key: brings the session's Terminal tab to the front and marks its answer as read.
    public func activate(slot: Int) {
        guard let id = assignment.session(inSlot: slot), let session = sessions.first(where: { $0.id == id }) else { return }
        let tabs = session.jobID != nil ? attachedTabs() : [:]
        guard let tty = viewTTYs(session, attached: tabs).first else {
            terminalProblem = session.jobID != nil
                ? "« \(session.displayName) » tourne en arrière-plan : ouvre-la avec claude attach \(session.jobID ?? "") dans Terminal."
                : "« \(session.displayName) » n'a pas d'onglet Terminal."
            return
        }
        Task { @MainActor [weak self, terminal] in
            let result = await terminal.focus(tty: tty)
            guard let self else { return }
            guard result == .shown else {
                self.terminalProblem = result.message
                return
            }
            self.terminalProblem = nil
            self.markRead(id)
            self.pushIndicators()
        }
    }

    /// The "Autoriser Terminal" button.
    public func requestTerminalAccess() {
        Task { @MainActor [weak self, terminal] in
            let result = await terminal.requestAccess()
            self?.terminalProblem = result == .shown ? nil : result.message
            self?.terminalAccessGranted = result == .shown
        }
    }

    private func markInterrupted(_ id: String, since lastEvent: Date) {
        try? store.update(id: id) { existing in
            guard var session = existing, session.updatedAt == lastEvent, session.state == .thinking || session.state == .waiting else {
                return .ignore // a hook event arrived meanwhile
            }
            session.state = .idle
            session.waitingFor = nil
            return .write(session)
        }
        if let index = sessions.firstIndex(where: { $0.id == id }), sessions[index].updatedAt == lastEvent {
            sessions[index].state = .idle
        }
    }

    private func markRead(_ id: String) {
        try? store.update(id: id) { existing in
            guard var session = existing, session.state == .unread else { return .ignore }
            session.state = .idle
            return .write(session)
        }
        if let index = sessions.firstIndex(where: { $0.id == id }), sessions[index].state == .unread {
            sessions[index].state = .idle
        }
    }

    private func pushIndicators() {
        guard isEnabled else {
            controller.setIndicators([])
            return
        }
        let level = UInt8((min(1, max(0.1, brightness)) * 255).rounded())
        let indicators: [Indicator] = (0..<SlotAssignment.slotCount).compactMap { slot in
            guard let id = assignment.session(inSlot: slot), let session = sessions.first(where: { $0.id == id }) else { return nil }
            return Indicator(led: Self.leds[slot], color: session.state.color.scaled(by: level), breathing: session.state.breathing)
        }
        controller.setIndicators(indicators)
    }
}
