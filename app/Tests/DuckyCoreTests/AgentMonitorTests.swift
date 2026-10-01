import XCTest
@testable import DuckyCore

final class FakeTerminal: TerminalControlling, @unchecked Sendable {
    var front: String?
    var allowed = true
    private(set) var focused: [String] = []

    func frontmostTTY() async -> String? { front }

    func focus(tty: String) async -> TerminalFocusResult {
        guard allowed else { return .accessDenied }
        focused.append(tty)
        front = tty
        return .shown
    }

    func requestAccess() async -> TerminalFocusResult { allowed ? .shown : .accessDenied }
}

@MainActor
final class AgentMonitorTests: XCTestCase {
    private var dir: URL!
    private var registryDir: URL { dir.appendingPathComponent("registry") }
    private var store: AgentStore!
    private var defaults: UserDefaults!
    private var alive: Set<Int32> = []
    /// Job id -> tty of a Terminal tab running `claude attach <job>`.
    private var attached: [String: String] = [:]
    /// Called on each liveness check (lets a test change the files mid-refresh).
    private var isAliveHook: ((Int32) -> Void)?
    private let terminal = FakeTerminal()

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("monitor-\(UUID().uuidString)")
        store = AgentStore(directory: dir)
        defaults = UserDefaults(suiteName: "AgentMonitorTests-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func waitUntil(_ timeout: TimeInterval = 2, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
    }

    private func add(_ id: String, _ state: AgentState, pid: Int32, tty: String? = nil, at time: Double = 0) throws {
        alive.insert(pid)
        try store.write(AgentSession(sessionID: id, state: state, cwd: "/p/\(id)", tty: tty, pid: pid,
                                     startedAt: Date(timeIntervalSince1970: time)))
    }

    private func setUp() async -> (FakeKeyboard, LightingController, AgentMonitor) {
        let fake = FakeKeyboard()
        let controller = LightingController(transport: fake, saveDelay: 0.1, indicatorRefresh: 60)
        controller.start()
        await waitUntil { controller.connection == .connected }
        let monitor = AgentMonitor(store: store, controller: controller, terminal: terminal, defaults: defaults,
                                   registry: ClaudeSessionRegistry(directory: registryDir), ttyOf: { "ttys0\($0)" },
                                   attachedTabs: { [unowned self] in self.attached },
                                   isAlive: { [unowned self] pid in
                                       self.isAliveHook?(pid)
                                       return self.alive.contains(pid)
                                   }, autoRefresh: false)
        return (fake, controller, monitor)
    }

    private let delete = UInt8(KeyboardLayout.index(named: "delete")!)
    private let pageUp = UInt8(KeyboardLayout.index(named: "pageup")!)

    func testSessionsLightTheirKeys() async throws {
        let (fake, _, monitor) = await setUp()
        try add("a", .thinking, pid: 10, at: 0)
        try add("b", .waiting, pid: 11, at: 1)
        monitor.refresh()
        XCTAssertEqual(monitor.sessions.map(\.sessionID), ["a", "b"])
        let level = UInt8((0.6 * 255).rounded())
        let expected = [
            Indicator(led: delete, color: AgentState.thinking.color.scaled(by: level), breathing: true),
            Indicator(led: pageUp, color: AgentState.waiting.color.scaled(by: level), breathing: true),
        ]
        await waitUntil { fake.indicators == expected }
        XCTAssertEqual(fake.indicators, expected)
    }

    func testDeadSessionsAreRemoved() async throws {
        let (fake, _, monitor) = await setUp()
        try add("a", .idle, pid: 10)
        monitor.refresh()
        await waitUntil { fake.indicators.count == 1 }
        alive.remove(10)
        monitor.refresh()
        XCTAssertTrue(monitor.sessions.isEmpty)
        XCTAssertTrue(store.load().isEmpty)
        await waitUntil { fake.indicators.isEmpty }
        XCTAssertTrue(fake.indicators.isEmpty)
    }

    func testUnreadTurnsIdleWhenItsTabIsInFront() async throws {
        let (_, _, monitor) = await setUp()
        try add("a", .unread, pid: 10, tty: "ttys003")
        terminal.front = "ttys009"
        monitor.refresh()
        XCTAssertEqual(monitor.sessions.first?.state, .unread)
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(monitor.sessions.first?.state, .unread)
        terminal.front = "ttys003"
        monitor.refresh()
        await waitUntil { monitor.sessions.first?.state == .idle }
        XCTAssertEqual(monitor.sessions.first?.state, .idle)
        XCTAssertEqual(store.load().first?.state, .idle)
    }

    func testAgentKeyFocusesTheTabAndMarksItRead() async throws {
        let (fake, _, monitor) = await setUp()
        try add("a", .idle, pid: 10, tty: "ttys001", at: 0)
        try add("b", .unread, pid: 11, tty: "ttys002", at: 1)
        monitor.refresh()
        fake.pressAgentKey(1)
        await waitUntil { monitor.sessions.last?.state == .idle }
        XCTAssertEqual(terminal.focused, ["ttys002"])
        XCTAssertEqual(monitor.sessions.last?.state, .idle)
    }

    func testRefusedTerminalAccessIsReported() async throws {
        let (_, _, monitor) = await setUp()
        try add("a", .unread, pid: 10, tty: "ttys001")
        terminal.allowed = false
        monitor.refresh()
        monitor.activate(slot: 0)
        await waitUntil { monitor.terminalProblem != nil }
        XCTAssertEqual(monitor.terminalProblem, TerminalFocusResult.accessDenied.message)
        terminal.allowed = true
        monitor.requestTerminalAccess()
        await waitUntil { monitor.terminalProblem == nil }
        XCTAssertEqual(monitor.terminalAccessGranted, true)
        XCTAssertEqual(monitor.sessions.first?.state, .unread)
    }

    func testManualChoiceAndSwitchingOff() async throws {
        let (fake, _, monitor) = await setUp()
        try add("a", .idle, pid: 10, at: 0)
        try add("b", .error, pid: 11, at: 1)
        monitor.refresh()
        monitor.choose(.slot(0), for: monitor.sessions[1].id)
        await waitUntil { fake.indicators.first?.led == self.delete && fake.indicators.first?.color.r == AgentState.error.color.scaled(by: 153).r }
        XCTAssertEqual(monitor.slot(of: monitor.sessions[1].id), 0)
        monitor.isEnabled = false
        await waitUntil { fake.indicators.isEmpty }
        XCTAssertTrue(fake.indicators.isEmpty)
        XCTAssertFalse(AgentMonitor(store: store, controller: LightingController(transport: FakeKeyboard()), terminal: terminal,
                                    defaults: defaults, autoRefresh: false).isEnabled)
    }

    func testUnknownProcessExpiresOnlyAfterALongSilence() async throws {
        let (_, _, monitor) = await setUp()
        try store.write(AgentSession(sessionID: "a", state: .idle, cwd: "/p", pid: 0, startedAt: Date(timeIntervalSince1970: 0),
                                     updatedAt: Date()))
        monitor.refresh()
        XCTAssertEqual(monitor.sessions.count, 1)
        monitor.refresh(now: Date().addingTimeInterval(13 * 3600))
        XCTAssertTrue(monitor.sessions.isEmpty)
    }

    func testDeadSessionIsKeptWhenANewProcessResumedIt() async throws {
        let (_, _, monitor) = await setUp()
        try add("a", .idle, pid: 10)
        alive.remove(10)
        isAliveHook = { [unowned self] pid in
            // the session is resumed by a new process between the read and the delete
            if pid == 10 { try? self.store.write(AgentSession(sessionID: "a", state: .thinking, cwd: "/p/a", pid: 20,
                                                               startedAt: Date(timeIntervalSince1970: 0))) }
        }
        alive.insert(20)
        monitor.refresh()
        XCTAssertEqual(store.load().first?.pid, 20)
    }


    func testInterruptedTurnTurnsIdle() async throws {
        let (fake, _, monitor) = await setUp()
        let transcript = dir.appendingPathComponent("t.jsonl")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var session = AgentSession(sessionID: "a", state: .thinking, cwd: "/p", pid: 10, startedAt: Date(timeIntervalSince1970: 0),
                                   updatedAt: Date(timeIntervalSince1970: 100))
        session.transcriptPath = transcript.path
        alive.insert(10)
        try store.write(session)
        let interrupt = #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]},"timestamp":"1970-01-01T00:01:00.000Z"}"#
        try Data(interrupt.utf8).write(to: transcript)
        monitor.refresh()
        XCTAssertEqual(monitor.sessions.first?.state, .thinking) // an interrupt older than the last event
        let later = interrupt.replacingOccurrences(of: "00:01:00", with: "00:02:00")
        try Data(later.utf8).write(to: transcript)
        monitor.refresh()
        XCTAssertEqual(monitor.sessions.first?.state, .idle)
        XCTAssertEqual(store.load().first?.state, .idle)
        await waitUntil { fake.indicators.first?.breathing == false }
        XCTAssertEqual(fake.indicators.first?.breathing, false)
    }


    private func register(pid: Int32, session: String, status: String = "idle", name: String? = nil, nameSource: String = "auto") throws {
        try FileManager.default.createDirectory(at: registryDir, withIntermediateDirectories: true)
        let nameField = name.map { #","name":"\#($0)","nameSource":"\#(nameSource)""# } ?? ""
        let json = #"{"pid":\#(pid),"sessionId":"\#(session)","cwd":"/p/\#(session)","startedAt":1790842222096,"status":"\#(status)"\#(nameField)}"#
        try Data(json.utf8).write(to: registryDir.appendingPathComponent("\(pid).json"))
    }

    func testRunningSessionsAreDiscoveredFromClaudeRegistry() async throws {
        let (_, _, monitor) = await setUp()
        alive.formUnion([21, 22, 23])
        try register(pid: 21, session: "busy1", status: "busy", name: "Refonte du README")
        try register(pid: 22, session: "calm2", name: "project-40", nameSource: "derived")
        try register(pid: 23, session: "ghost", status: "busy") // registered, but its process is gone
        alive.remove(23)
        monitor.refresh()
        XCTAssertEqual(monitor.sessions.map(\.sessionID), ["busy1", "calm2"])
        XCTAssertEqual(monitor.sessions[0].state, .thinking)
        XCTAssertEqual(monitor.sessions[0].displayName, "Refonte du README")
        XCTAssertEqual(monitor.sessions[0].tty, "ttys021")
        XCTAssertEqual(monitor.sessions[1].state, .idle)
        XCTAssertEqual(monitor.sessions[1].displayName, "calm2") // a derived name is not a title
    }

    func testSessionReplacedInItsProcessIsRemoved() async throws {
        let (_, _, monitor) = await setUp()
        try add("old", .idle, pid: 30)
        try register(pid: 30, session: "new")
        monitor.refresh()
        XCTAssertEqual(monitor.sessions.map(\.sessionID), ["new"])
        XCTAssertEqual(store.load().map(\.sessionID), ["new"])
    }

    func testKnownSessionKeepsItsHookState() async throws {
        let (_, _, monitor) = await setUp()
        try add("a", .waiting, pid: 40)
        try register(pid: 40, session: "a", status: "idle", name: "Titre")
        monitor.refresh()
        XCTAssertEqual(monitor.sessions.first?.state, .waiting)
        XCTAssertEqual(monitor.sessions.first?.title, "Titre")
    }


    func testBackgroundSessionOpensItsAttachTab() async throws {
        let (fake, _, monitor) = await setUp()
        alive.insert(50)
        try FileManager.default.createDirectory(at: registryDir, withIntermediateDirectories: true)
        let json = #"{"pid":50,"sessionId":"a1b2c3d4-aaaa","kind":"bg","jobId":"a1b2c3d4","status":"idle"}"#
        try Data(json.utf8).write(to: registryDir.appendingPathComponent("50.json"))
        attached = ["a1b2c3d4": "ttys007"]
        monitor.refresh()
        XCTAssertEqual(monitor.sessions.first?.jobID, "a1b2c3d4")
        try store.update(id: monitor.sessions[0].id) { existing in
            var session = existing!
            session.state = .unread
            return .write(session)
        }
        terminal.front = "ttys007" // the attach tab is in front: the answer has been seen
        monitor.refresh()
        await waitUntil { monitor.sessions.first?.state == .idle }
        XCTAssertEqual(monitor.sessions.first?.state, .idle)
        terminal.front = nil
        fake.pressAgentKey(0)
        await waitUntil { self.terminal.focused == ["ttys007"] }
        XCTAssertEqual(terminal.focused, ["ttys007"])
    }

    func testAttachCommandsAreParsed() {
        let ps = """
        ttys007  /Users/x/.local/bin/claude attach a1b2c3d4
        ttys005  claude --resume 460648fe
        ??       /Users/x/.local/share/claude/versions/2.1.285 --bg-pty-host /tmp/x
        ttys009  claude attach abc123 --foo
        """
        XCTAssertEqual(ProcessDetails.attachedTabs(fromPS: ps), ["a1b2c3d4": "ttys007", "abc123": "ttys009"])
    }
}
