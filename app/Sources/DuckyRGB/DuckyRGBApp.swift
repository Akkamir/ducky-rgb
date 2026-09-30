import AppKit
import DuckyCore
import SwiftUI

@MainActor
final class AppModel {
    static let shared = AppModel()
    let controller: LightingController
    let presets = PresetStore.standard()
    let audio: AudioMode

    init() {
        let controller = LightingController(transport: IOKitHIDTransport())
        self.controller = controller
        audio = AudioMode(controller: controller, makeCapture: { SystemAudioTap() })
    }
}

enum DockIcon {
    static let key = "showDockIcon"

    static func apply(_ show: Bool) {
        NSApp.setActivationPolicy(show ? .regular : .accessory)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
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
        } label: {
            Image(systemName: "keyboard")
        }
        .menuBarExtraStyle(.window)

        Window("Ducky RGB", id: MainWindow.id) {
            MainWindow()
                .environment(model.controller)
                .environment(model.presets)
                .environment(model.audio)
        }
        .defaultSize(width: 980, height: 640)
    }
}
