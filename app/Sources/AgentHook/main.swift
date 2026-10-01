// ducky-agent-hook: Claude Code runs it on each hook event (see HookInstaller). It updates the session's file for
// Ducky RGB's agent indicators. It never fails and prints nothing, so it can never disturb Claude.
import Darwin
import DuckyCore
import Foundation

/// The agent process behind this hook: the first ancestor that is not a shell, preferably Claude itself.
func agentProcess() -> (pid: Int32, tty: String?) {
    let shells: Set<String> = ["sh", "bash", "zsh", "dash", "fish", "env"]
    var pid = getppid()
    var fallback: (pid: Int32, tty: String?)?
    for _ in 0..<12 {
        guard pid > 1, let info = ProcessDetails.info(pid) else { break }
        let path = ProcessDetails.path(of: pid)
        let name = URL(fileURLWithPath: path).lastPathComponent
        if path.contains("/claude/") || name == "claude" { return (pid, info.tty) }
        if fallback == nil && !shells.contains(name) && !path.isEmpty { fallback = (pid, info.tty) }
        pid = info.parent
    }
    return fallback ?? (0, nil) // unknown: the app keeps the session until its events stop
}

let source = CommandLine.arguments.dropFirst().first ?? "claude"
let input = FileHandle.standardInput.readDataToEndOfFile()
guard source == "claude", let event = try? JSONDecoder().decode(HookEvent.self, from: input), !event.sessionID.isEmpty else { exit(0) }
let process = agentProcess()
let id = AgentSession.id(sessionID: event.sessionID)
try? AgentStore.standard().update(id: id) { existing in
    AgentTransition.apply(event, to: existing, pid: process.pid, tty: process.tty, now: Date())
}
exit(0)
