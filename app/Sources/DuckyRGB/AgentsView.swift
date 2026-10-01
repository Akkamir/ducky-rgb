import DuckyCore
import SwiftUI

/// The key picker value of a session row: a key, or none (waiting or hidden).
private enum KeyChoice: Hashable {
    case key(Int)
    case none
}

/// One session: state, name and key picker.
struct AgentRow: View {
    @Environment(AgentMonitor.self) private var monitor
    let session: AgentSession

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color(session.state.color))
                .frame(width: 10, height: 10)
                .help(session.state.label)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.displayName).lineLimit(1).truncationMode(.tail)
                Text(caption).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Picker("Touche", selection: choice) {
                ForEach(0..<AgentMonitor.keyLabels.count, id: \.self) { slot in
                    Text(AgentMonitor.keyLabels[slot]).tag(KeyChoice.key(slot))
                }
                Text("Aucune").tag(KeyChoice.none)
            }
            .labelsHidden()
            .fixedSize()
        }
    }

    private var caption: String {
        if monitor.slot(of: session.id) == nil {
            return monitor.assignment.choice(for: session.id) == .hidden ? "\(session.state.label) · masquée" : "\(session.state.label) · en attente d'une touche"
        }
        if session.jobID != nil { return "\(session.state.label) · en arrière-plan" }
        return session.tty == nil ? "\(session.state.label) · sans onglet Terminal" : session.state.label
    }

    private var choice: Binding<KeyChoice> {
        Binding(get: { monitor.slot(of: session.id).map(KeyChoice.key) ?? .none },
                set: { value in
                    switch value {
                    case .key(let slot): monitor.choose(.slot(slot), for: session.id)
                    case .none: monitor.choose(.hidden, for: session.id)
                    }
                })
    }
}

/// Compact list for the menu bar extra.
struct AgentsMenuSection: View {
    @Environment(AgentMonitor.self) private var monitor
    let openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Agents Claude").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Rafraîchir") { monitor.refresh() }.font(.caption)
                Button("Configurer…", action: openSettings).font(.caption)
            }
            if monitor.sessions.isEmpty {
                Text("Aucune session").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(monitor.sessions) { session in
                AgentRow(session: session)
            }
        }
    }
}

/// The window's Agents section: sessions, keyboard display and the Claude Code integration.
struct AgentsView: View {
    @Environment(AgentMonitor.self) private var monitor
    @Environment(LightingController.self) private var controller
    @State private var installed = false
    @State private var installError: String?

    private let settingsURL = HookInstaller.standardSettingsURL()
    private var hookPath: String? {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/ducky-agent-hook")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url.path : nil
    }

    var body: some View {
        @Bindable var monitor = monitor
        Form {
            Section {
                if monitor.sessions.isEmpty {
                    Text("Aucune session Claude Code en cours.").foregroundStyle(.secondary)
                }
                ForEach(monitor.sessions) { session in
                    AgentRow(session: session)
                }
                if let problem = monitor.terminalProblem {
                    Text(problem).font(.caption).foregroundStyle(.orange)
                }
                HStack {
                    Button("Autoriser Terminal") { monitor.requestTerminalAccess() }
                    if monitor.terminalAccessGranted == true {
                        Label("Accès à Terminal autorisé", systemImage: "checkmark.circle").font(.caption).foregroundStyle(.green)
                    }
                }
            } header: {
                HStack {
                    Text("Sessions")
                    Spacer()
                    Button("Rafraîchir") { monitor.refresh() }
                }
            } footer: {
                Text("Liste mise à jour chaque seconde à partir des sessions Claude Code en cours.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Clavier") {
                Toggle("Afficher sur le clavier", isOn: $monitor.isEnabled)
                LabeledContent("Luminosité des voyants") {
                    Slider(value: $monitor.brightness, in: 0.1...1)
                }
                Text("Suppr, PgUp et PgDn montrent jusqu'à 3 sessions, par-dessus l'éclairage et le mode audio. "
                    + "Fn + la touche affiche l'onglet Terminal de la session.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    ForEach(AgentState.allCases, id: \.self) { state in
                        Label { Text(state.label).font(.caption) } icon: {
                            Circle().fill(Color(state.color)).frame(width: 8, height: 8)
                        }
                    }
                }
                if controller.canControl && !controller.supportsIndicators {
                    Text("Le firmware du clavier ne gère pas encore les voyants (protocole v3 requis).")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            Section("Intégration Claude Code") {
                LabeledContent("Hooks", value: installed ? "Installés" : "Non installés")
                Text("Ajoute à ~/.claude/settings.json un hook par événement utile, sans toucher aux autres réglages "
                    + "(copie de l'original : settings.json.ducky-backup). Les sessions déjà ouvertes doivent être relancées.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button(installed ? "Réinstaller" : "Installer") { change(install: true) }
                        .disabled(hookPath == nil)
                    Button("Désinstaller") { change(install: false) }
                        .disabled(!installed)
                }
                if hookPath == nil {
                    Text("Disponible depuis l'application empaquetée (scripts/bundle.sh).").font(.caption).foregroundStyle(.secondary)
                }
                if let installError {
                    Text(installError).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear { refreshInstalled() }
    }

    private func refreshInstalled() {
        installed = hookPath.map { HookInstaller.isInstalled(try? Data(contentsOf: settingsURL), hookPath: $0) } ?? false
    }

    private func change(install: Bool) {
        do {
            if install, let hookPath {
                try HookInstaller.install(settingsURL: settingsURL, hookPath: hookPath)
            } else {
                try HookInstaller.uninstall(settingsURL: settingsURL)
            }
            installError = nil
        } catch HookInstaller.Failure.invalidSettings {
            installError = "~/.claude/settings.json n'est pas un JSON valide : rien n'a été modifié."
        } catch {
            installError = "Impossible de modifier ~/.claude/settings.json : \(error.localizedDescription)"
        }
        refreshInstalled()
    }
}
