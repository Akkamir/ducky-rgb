import AppKit
import DuckyCore
import SwiftUI

struct MenuContent: View {
    @Environment(LightingController.self) private var controller
    @Environment(PresetStore.self) private var presets
    @Environment(\.openWindow) private var openWindow
    @AppStorage(MainSection.storageKey) private var section: MainSection = .editor

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            StatusHeader()
            HostModeBanner()
            Divider()
            Text("Presets").font(.caption).foregroundStyle(.secondary)
            ForEach(presets.all) { preset in
                Button {
                    controller.apply(preset)
                } label: {
                    HStack {
                        Image(systemName: "checkmark")
                            .opacity(preset.matches(base: controller.base, overlay: controller.overlay) ? 1 : 0)
                        Text(preset.name)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!controller.canControl)
            }
            Divider()
            BaseControls(showsColor: false)
            Divider()
            Button("Ouvrir l'éditeur…") { open(.editor) }
            Button("Réglages…") { open(.settings) }
            Button("Quitter Ducky RGB") { NSApp.terminate(nil) }
        }
        .buttonStyle(.borderless)
        .padding(14)
        .frame(width: 300)
        .onAppear { controller.refreshIfPresent() }
    }

    private func open(_ target: MainSection) {
        section = target
        openWindow(id: MainWindow.id)
        NSApp.activate(ignoringOtherApps: true)
    }
}
