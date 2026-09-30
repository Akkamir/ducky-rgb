import AppKit
import DuckyCore
import SwiftUI

@MainActor
final class AppModel {
    static let shared = AppModel()
    let controller = LightingController(transport: IOKitHIDTransport())
    let presets = PresetStore.standard()
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
        }
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
        } label: {
            Image(systemName: "keyboard")
        }
        .menuBarExtraStyle(.window)

        Window("Ducky RGB", id: MainWindow.id) {
            MainWindow()
                .environment(model.controller)
                .environment(model.presets)
        }
        .defaultSize(width: 980, height: 640)
    }
}
