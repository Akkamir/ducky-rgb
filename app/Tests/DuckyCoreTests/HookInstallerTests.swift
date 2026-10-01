import XCTest
@testable import DuckyCore

final class HookInstallerTests: XCTestCase {
    private let path = "/Applications/Ducky RGB.app/Contents/MacOS/ducky-agent-hook"

    private func json(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func commands(_ settings: [String: Any], _ event: String) -> [String] {
        let groups = (settings["hooks"] as? [String: Any])?[event] as? [[String: Any]] ?? []
        return groups.flatMap { ($0["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String } }
    }

    private let existing = Data(#"""
    {"model": "opus", "hooks": {"PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "rtk hook claude"}]}],
     "Stop": [{"hooks": [{"type": "command", "command": "python3 other.py"}]}]}}
    """#.utf8)

    func testInstallAddsEveryEventAndKeepsOtherHooks() throws {
        let settings = try json(HookInstaller.installing(into: existing, hookPath: path))
        XCTAssertEqual(settings["model"] as? String, "opus")
        for event in HookInstaller.events {
            XCTAssertEqual(commands(settings, event).filter { $0.contains("ducky-agent-hook") }.count, 1, event)
        }
        XCTAssertEqual(commands(settings, "PreToolUse").first, "rtk hook claude")
        XCTAssertTrue(commands(settings, "Stop").contains("python3 other.py"))
        XCTAssertEqual(commands(settings, "Stop").last, "'/Applications/Ducky RGB.app/Contents/MacOS/ducky-agent-hook' claude")
    }

    func testInstallIsIdempotentAndWorksWithoutAFile() throws {
        let once = try HookInstaller.installing(into: nil, hookPath: path)
        let twice = try HookInstaller.installing(into: once, hookPath: path)
        XCTAssertEqual(commands(try json(twice), "Stop").count, 1)
        XCTAssertTrue(HookInstaller.isInstalled(twice, hookPath: path))
        XCTAssertFalse(HookInstaller.isInstalled(twice, hookPath: "/elsewhere/ducky-agent-hook"))
        XCTAssertFalse(HookInstaller.isInstalled(existing, hookPath: path))
    }

    func testUninstallRemovesOnlyOurHooks() throws {
        let installed = try HookInstaller.installing(into: existing, hookPath: path)
        let settings = try json(HookInstaller.removing(from: installed))
        XCTAssertEqual(commands(settings, "PreToolUse"), ["rtk hook claude"])
        XCTAssertEqual(commands(settings, "Stop"), ["python3 other.py"])
        XCTAssertNil((settings["hooks"] as? [String: Any])?["SessionStart"])
    }

    func testRefusesInvalidSettings() {
        XCTAssertThrowsError(try HookInstaller.installing(into: Data("{ nope".utf8), hookPath: path))
        XCTAssertThrowsError(try HookInstaller.installing(into: Data(#"{"hooks": []}"#.utf8), hookPath: path))
    }

    func testInstallFileKeepsABackup() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hooks-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("settings.json")
        try existing.write(to: file)
        try HookInstaller.install(settingsURL: file, hookPath: path)
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("settings.json.ducky-backup")), existing)
        XCTAssertTrue(HookInstaller.isInstalled(try Data(contentsOf: file), hookPath: path))
        try HookInstaller.uninstall(settingsURL: file)
        XCTAssertFalse(HookInstaller.isInstalled(try Data(contentsOf: file), hookPath: path))
        try HookInstaller.install(settingsURL: file, hookPath: path)
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("settings.json.ducky-backup")), existing) // first one kept
    }
}
