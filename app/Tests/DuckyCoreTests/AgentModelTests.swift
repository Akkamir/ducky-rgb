import XCTest
@testable import DuckyCore

final class AgentModelTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000)

    private func event(_ name: String, tool: String? = nil, notification: String? = nil, prompt: String? = nil,
                       title: String? = nil) -> HookEvent {
        HookEvent(sessionID: "s1", name: name, cwd: "/Users/someone/project", toolName: tool, notificationType: notification,
                  prompt: prompt, sessionTitle: title)
    }

    private func state(after name: String, from previous: AgentState? = .idle, tool: String? = nil,
                       notification: String? = nil) -> AgentState? {
        let existing = previous.map { AgentSession(sessionID: "s1", state: $0, cwd: "/x", pid: 1, startedAt: now) }
        switch AgentTransition.apply(event(name, tool: tool, notification: notification), to: existing, pid: 42, tty: "ttys003", now: now) {
        case .write(let session): return session.state
        case .delete, .ignore: return nil
        }
    }

    func testEventsGiveTheSpecStates() {
        XCTAssertEqual(state(after: "SessionStart", from: nil), .idle)
        XCTAssertEqual(state(after: "UserPromptSubmit"), .thinking)
        XCTAssertEqual(state(after: "PreToolUse", tool: "Bash"), .thinking)
        XCTAssertEqual(state(after: "PreToolUse", tool: "AskUserQuestion"), .waiting)
        XCTAssertEqual(state(after: "PostToolUse", from: .waiting), .thinking)
        XCTAssertEqual(state(after: "PostToolUseFailure", from: .waiting), .thinking)
        XCTAssertEqual(state(after: "PermissionRequest", from: .thinking), .waiting)
        XCTAssertEqual(state(after: "Notification", from: .thinking, notification: "permission_prompt"), .waiting)
        XCTAssertEqual(state(after: "Notification", from: .thinking, notification: "elicitation_dialog"), .waiting)
        XCTAssertEqual(state(after: "Stop", from: .thinking), .unread)
        XCTAssertEqual(state(after: "StopFailure", from: .thinking), .error)
        XCTAssertEqual(state(after: "UserPromptSubmit", from: .error), .thinking)
    }

    func testIgnoredAndEndingEvents() {
        let existing = AgentSession(sessionID: "s1", state: .unread, cwd: "/x", pid: 1, startedAt: now)
        guard case .ignore = AgentTransition.apply(event("Notification", notification: "idle_prompt"), to: existing, pid: 1, tty: nil, now: now) else {
            return XCTFail("idle_prompt must not change an unread session")
        }
        guard case .delete = AgentTransition.apply(event("SessionEnd"), to: existing, pid: 1, tty: nil, now: now) else {
            return XCTFail("SessionEnd must delete")
        }
        // A session already running when the integration was installed shows up at its next event.
        XCTAssertEqual(state(after: "Notification", from: nil, notification: "idle_prompt"), .idle)
    }

    func testSessionKeepsItsIdentityAndLearnsItsName() {
        guard case .write(let started) = AgentTransition.apply(event("SessionStart"), to: nil, pid: 42, tty: "ttys003", now: now) else {
            return XCTFail("expected a session")
        }
        XCTAssertEqual(started.pid, 42)
        XCTAssertEqual(started.tty, "ttys003")
        XCTAssertEqual(started.startedAt, now)
        XCTAssertEqual(started.displayName, "project")
        let later = now.addingTimeInterval(60)
        guard case .write(let prompted) = AgentTransition.apply(event("UserPromptSubmit", prompt: "  Point du matin :\nquelles priorités aujourd'hui pour avancer ?"),
                                                                to: started, pid: 42, tty: "ttys003", now: later) else {
            return XCTFail("expected a session")
        }
        XCTAssertEqual(prompted.startedAt, now)
        XCTAssertEqual(prompted.updatedAt, later)
        XCTAssertEqual(prompted.displayName, "project · Point du matin : quelles priorités aujou…")
        guard case .write(let titled) = AgentTransition.apply(event("Stop", title: "Morning plan"), to: prompted, pid: 42, tty: nil, now: later) else {
            return XCTFail("expected a session")
        }
        XCTAssertEqual(titled.displayName, "Morning plan")
        XCTAssertEqual(titled.tty, "ttys003") // an event without a tty keeps the known one
    }

    func testDecodesClaudeHookJSON() throws {
        let json = #"{"session_id":"abc-123","hook_event_name":"PreToolUse","cwd":"/tmp/p","tool_name":"AskUserQuestion","tool_input":{"x":1}}"#
        let event = try JSONDecoder().decode(HookEvent.self, from: Data(json.utf8))
        XCTAssertEqual(event.sessionID, "abc-123")
        XCTAssertEqual(event.name, "PreToolUse")
        XCTAssertEqual(event.toolName, "AskUserQuestion")
    }

    func testStoreRoundTripLockedUpdatesAndBadFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agents-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = AgentStore(directory: dir)
        let session = AgentSession(sessionID: "s1", state: .thinking, cwd: "/x", pid: 7, startedAt: now)
        try store.write(session)
        try Data("not json".utf8).write(to: dir.appendingPathComponent("claude-broken.json"))
        XCTAssertEqual(store.load(), [session])

        try store.update(id: session.id) { existing in
            XCTAssertEqual(existing, session)
            var next = session
            next.state = .unread
            return .write(next)
        }
        XCTAssertEqual(store.load().first?.state, .unread)
        try store.update(id: session.id) { _ in .delete }
        XCTAssertEqual(store.load(), [])
    }

    func testSessionIDsCannotEscapeTheDirectory() {
        let session = AgentSession(sessionID: "../../etc/x", state: .idle, cwd: "/x", pid: 1, startedAt: now)
        XCTAssertEqual(session.id, "claude-etcx")
    }


    private func run(_ events: [HookEvent], from start: AgentState? = .idle) -> AgentSession? {
        var session = start.map { AgentSession(sessionID: "s1", state: $0, cwd: "/x", pid: 1, startedAt: now) }
        for event in events {
            switch AgentTransition.apply(event, to: session, pid: 1, tty: nil, now: now) {
            case .write(let next): session = next
            case .delete: session = nil
            case .ignore: break
            }
        }
        return session
    }

    private func tool(_ name: String, _ tool: String, id: String? = nil, agent: String? = nil) -> HookEvent {
        HookEvent(sessionID: "s1", name: name, toolName: tool, toolUseID: id, agentID: agent)
    }

    func testWaitingIsNotClearedByOtherTools() {
        let waiting = run([tool("PreToolUse", "Bash", id: "t1"), tool("PermissionRequest", "Bash", id: "t1"),
                           tool("PreToolUse", "Read", id: "t2"), tool("PostToolUse", "Read", id: "t2")])
        XCTAssertEqual(waiting?.state, .waiting)
        XCTAssertEqual(run([tool("PermissionRequest", "Bash", id: "t1"), tool("PostToolUse", "Bash", id: "t1")])?.state, .thinking)
        XCTAssertEqual(run([tool("PermissionRequest", "Bash"), tool("PostToolUseFailure", "Bash")])?.state, .thinking)
        XCTAssertEqual(run([tool("PermissionRequest", "Bash"), tool("PostToolUse", "Bash", id: "t9")])?.state, .thinking)
        XCTAssertEqual(run([tool("PermissionRequest", "Bash", id: "t1"), event("UserPromptSubmit")])?.state, .thinking)
        XCTAssertEqual(run([tool("PermissionRequest", "Bash", id: "t1"), event("Stop")])?.state, .unread)
        let answered = run([tool("PreToolUse", "AskUserQuestion", id: "q1"), tool("PreToolUse", "Read", id: "t2"),
                            tool("PostToolUse", "AskUserQuestion", id: "q1")])
        XCTAssertEqual(answered?.state, .thinking)
        XCTAssertNil(answered?.waitingFor)
    }

    func testInterruptedTurnsGoIdleWhenClaudeWaitsForInput() {
        XCTAssertEqual(run([event("UserPromptSubmit"), event("Notification", notification: "idle_prompt")])?.state, .idle)
        XCTAssertEqual(run([tool("PermissionRequest", "Bash"), event("Notification", notification: "idle_prompt")])?.state, .idle)
    }

    func testBackgroundSubagentToolsDoNotReopenAFinishedTurn() {
        XCTAssertEqual(run([event("Stop"), tool("PreToolUse", "Read", agent: "sub1")])?.state, .unread)
        XCTAssertEqual(run([event("UserPromptSubmit"), tool("PreToolUse", "Read", agent: "sub1")])?.state, .thinking)
    }

    func testCompactionAndUnknownPidKeepTheSession() {
        let compact = HookEvent(sessionID: "s1", name: "SessionStart", source: "compact")
        XCTAssertEqual(run([event("UserPromptSubmit"), compact])?.state, .thinking)
        XCTAssertEqual(run([compact], from: nil)?.state, .idle)
        let existing = AgentSession(sessionID: "s1", state: .idle, cwd: "/x", pid: 77, startedAt: now)
        guard case .write(let next) = AgentTransition.apply(event("UserPromptSubmit"), to: existing, pid: 0, tty: nil, now: now) else {
            return XCTFail("expected a session")
        }
        XCTAssertEqual(next.pid, 77)
    }
}
