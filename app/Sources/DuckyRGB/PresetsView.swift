import DuckyCore
import SwiftUI

struct PresetsView: View {
    @Environment(LightingController.self) private var controller
    @Environment(PresetStore.self) private var presets
    @State private var renaming: Preset?
    @State private var newName = ""

    private let columns = [GridItem(.adaptive(minimum: 240), spacing: 16)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let error = presets.loadError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(presets.all) { preset in
                        PresetCard(
                            preset: preset,
                            isActive: preset.matches(base: controller.base, overlay: controller.overlay),
                            canApply: controller.canControl,
                            apply: { controller.apply(preset) }
                        )
                        .contextMenu {
                            Button("Dupliquer") { presets.duplicate(id: preset.id) }
                            if !preset.builtIn {
                                Button("Renommer…") {
                                    newName = preset.name
                                    renaming = preset
                                }
                                Button("Supprimer", role: .destructive) { presets.delete(id: preset.id) }
                            }
                        }
                    }
                }
            }
            .padding(20)
        }
        .sheet(item: $renaming) { preset in
            NamePrompt(title: "Renommer le preset", name: $newName) {
                presets.rename(id: preset.id, to: newName)
            }
        }
    }
}

struct PresetCard: View {
    let preset: Preset
    let isActive: Bool
    let canApply: Bool
    let apply: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            KeyboardCanvas(colors: LightingPreview.colors(base: preset.base, overlay: preset.overlayColors()))
                .allowsHitTesting(false)
            HStack {
                Text(preset.name).font(.headline)
                if isActive {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
                Spacer()
                Button("Appliquer", action: apply).disabled(!canApply)
            }
            Text(preset.builtIn ? "Fourni · \(EffectCatalog.name(for: preset.base.effectID))" : EffectCatalog.name(for: preset.base.effectID))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary))
    }
}
