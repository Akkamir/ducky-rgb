import AppKit
import CoreServices
import DuckyCore

/// Terminal.app through AppleScript, on a background queue (Apple events and the permission prompt block).
final class AppleScriptTerminal: TerminalControlling, @unchecked Sendable {
    private static let bundleID = "com.apple.Terminal"
    private let queue = DispatchQueue(label: "ducky-rgb.terminal")

    func frontmostTTY() async -> String? {
        await run { [self] in
            guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Self.bundleID,
                  self.permission(askingUser: false) == noErr else { return nil } // never prompts on its own
            let tty = self.script("tell application \"Terminal\" to return tty of selected tab of front window")
            return tty.map { $0.replacingOccurrences(of: "/dev/", with: "") }
        }
    }

    func requestAccess() async -> TerminalFocusResult {
        await run { [self] in
            guard self.terminalIsRunning else { return .terminalNotRunning }
            return Self.result(self.permission(askingUser: true))
        }
    }

    func focus(tty: String) async -> TerminalFocusResult {
        await run { [self] in
            // Never launch Terminal just to look for a tab; the tty is checked before going into the script.
            guard self.terminalIsRunning else { return .terminalNotRunning }
            guard tty.allSatisfy({ $0.isLetter || $0.isNumber }) else { return .tabNotFound }
            let access = Self.result(self.permission(askingUser: true))
            guard access == .shown else { return access }
            let source = """
            with timeout of 3 seconds
                tell application "Terminal"
                    repeat with w in windows
                        repeat with t in tabs of w
                            if tty of t is "/dev/\(tty)" then
                                set selected of t to true
                                set index of w to 1
                                activate
                                return "ok"
                            end if
                        end repeat
                    end repeat
                end tell
            end timeout
            return "missing"
            """
            return self.script(source) == "ok" ? .shown : .tabNotFound
        }
    }

    private var terminalIsRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).isEmpty
    }

    private static func result(_ status: OSStatus) -> TerminalFocusResult {
        switch Int(status) {
        case Int(noErr): return .shown
        case -1743: return .accessDenied // errAEEventNotPermitted
        case -600: return .terminalNotRunning // procNotFound
        default: return .failed(status)
        }
    }

    private func run<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: work()) }
        }
    }

    /// Apple events permission for Terminal; with `askingUser`, shows the system prompt the first time.
    private func permission(askingUser: Bool) -> OSStatus {
        let target = NSAppleEventDescriptor(bundleIdentifier: Self.bundleID)
        guard let desc = target.aeDesc else { return OSStatus(procNotFound) }
        return AEDeterminePermissionToAutomateTarget(desc, typeWildCard, typeWildCard, askingUser)
    }

    private func script(_ source: String) -> String? {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        return error == nil ? result?.stringValue : nil
    }
}
