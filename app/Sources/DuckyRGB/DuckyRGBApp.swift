import AppKit
import DuckyCore
import SwiftUI

@MainActor
final class AppModel {
    static let shared = AppModel()
    let controller: LightingController
    let presets = PresetStore.standard()
    let audio: AudioMode
    let agents: AgentMonitor

    init() {
        let controller = LightingController(transport: IOKitHIDTransport())
        self.controller = controller
        audio = AudioMode(controller: controller, makeCapture: { SystemAudioTap() })
        agents = AgentMonitor(store: .standard(), controller: controller, terminal: AppleScriptTerminal())
    }

    /// SwiftUI's openWindow, captured by the menu bar label (the one view that always exists).
    var openMainWindow: (() -> Void)?

    func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let openMainWindow {
            openMainWindow()
        } else {
            NSApp.windows.first { $0.identifier?.rawValue == MainWindow.id }?.makeKeyAndOrderFront(nil)
        }
    }
}

/// The menu bar icon; it also hands SwiftUI's openWindow to the app delegate (Dock click, Cmd+Tab).
struct MenuBarLabel: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: "keyboard")
            .onAppear { AppModel.shared.openMainWindow = { openWindow(id: MainWindow.id) } }
    }
}

enum DockIcon {
    static let key = "showDockIcon"

    static func apply(_ show: Bool) {
        NSApp.setActivationPolicy(show ? .regular : .accessory)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var launchedAt = Date()

    /// Dock icon click: show the window when none is open.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { MainActor.assumeIsolated { AppModel.shared.showMainWindow() } }
        return true
    }

    /// Cmd+Tab only activates the app: show the window when nothing is on screen. Not when the menu bar panel
    /// activated it (the panel is then visible), nor right after launch (login items stay quiet).
    func applicationDidBecomeActive(_ notification: Notification) {
        guard NSApp.activationPolicy() == .regular, Date().timeIntervalSince(launchedAt) > 3 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            let onScreen = NSApp.windows.contains { $0.isVisible && !$0.className.contains("StatusBar") }
            if !onScreen { MainActor.assumeIsolated { AppModel.shared.showMainWindow() } }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        launchedAt = Date()
        MainActor.assumeIsolated {
            DockIcon.apply(UserDefaults.standard.bool(forKey: DockIcon.key))
            AppModel.shared.controller.start()
            AppModel.shared.audio.restore()
        }
    }

    /// Hands the LEDs back from the audio mode and writes a pending edit to the keyboard before quitting
    /// (the debounced save may not have run yet).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        var replied = false
        let reply = {
            guard !replied else { return }
            replied = true
            sender.reply(toApplicationShouldTerminate: true)
        }
        MainActor.assumeIsolated {
            AppModel.shared.audio.suspendForQuit() // hands the LEDs back to the saved lighting
            AppModel.shared.controller.setIndicators([]) // agent indicators off (sent before the flush completes)
            AppModel.shared.controller.flushPendingSave { reply() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { reply() }
        return .terminateLater
    }
}

@main
struct DuckyRGBApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
                .environment(model.controller)
                .environment(model.presets)
                .environment(model.audio)
                .environment(model.agents)
        } label: {
            MenuBarLabel()
        }
        .menuBarExtraStyle(.window)

        Window("Ducky RGB", id: MainWindow.id) {
            MainWindow()
                .environment(model.controller)
                .environment(model.presets)
                .environment(model.audio)
                .environment(model.agents)
        }
        .defaultSize(width: 980, height: 640)
    }
}
