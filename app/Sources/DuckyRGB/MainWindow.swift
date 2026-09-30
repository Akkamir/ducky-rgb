import DuckyCore
import SwiftUI

enum MainSection: String, CaseIterable, Identifiable {
    case editor, presets, settings

    static let storageKey = "mainSection"
    var id: String { rawValue }

    var title: String {
        switch self {
        case .editor: return "Éditeur"
        case .presets: return "Presets"
        case .settings: return "Réglages"
        }
    }

    var icon: String {
        switch self {
        case .editor: return "paintbrush"
        case .presets: return "square.grid.2x2"
        case .settings: return "gearshape"
        }
    }
}

struct MainWindow: View {
    static let id = "main"
    @Environment(LightingController.self) private var controller
    @AppStorage(MainSection.storageKey) private var section: MainSection = .editor

    var body: some View {
        NavigationSplitView {
            List(MainSection.allCases, selection: selection) { item in
                Label(item.title, systemImage: item.icon).tag(item)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180)
        } detail: {
            switch section {
            case .editor: EditorView()
            case .presets: PresetsView()
            case .settings: SettingsView()
            }
        }
        .onAppear { if controller.canControl { controller.refresh() } }
    }

    private var selection: Binding<MainSection?> {
        Binding(get: { section }, set: { if let value = $0 { section = value } })
    }
}
