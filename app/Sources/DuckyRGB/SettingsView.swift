import DuckyCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Environment(LightingController.self) private var controller
    @AppStorage(DockIcon.key) private var showDockIcon = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section("Application") {
                Toggle("Lancer à l'ouverture de session", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
                Toggle("Afficher l'icône dans le Dock", isOn: $showDockIcon)
                    .onChange(of: showDockIcon) { _, show in DockIcon.apply(show) }
            }
            Section("Clavier") {
                StatusHeader()
                if let info = controller.info {
                    LabeledContent("Protocole", value: "v\(info.version)")
                    LabeledContent("LEDs", value: "\(info.ledCount)")
                    LabeledContent("Effets", value: "\(info.effectCount)")
                    LabeledContent("Mémoire persistante", value: info.persistent ? "Oui" : "Non")
                }
                Button("Relire l'état du clavier") { controller.refresh() }
                    .disabled(controller.connection == .disconnected)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginError = nil
        } catch {
            loginError = "Impossible de modifier l'ouverture de session : \(error.localizedDescription)"
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}
