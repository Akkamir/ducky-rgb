import DuckyCore
import SwiftUI

struct EditorView: View {
    enum Tool: Hashable { case brush, eraser }

    @Environment(LightingController.self) private var controller
    @Environment(PresetStore.self) private var presets
    @Environment(AudioMode.self) private var audio
    @Environment(\.controlActiveState) private var activeState
    @State private var tool: Tool = .brush
    @State private var brush = Color.red
    @State private var savingPreset = false
    @State private var presetName = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                StatusHeader()
                HostModeBanner()
                GroupBox("Fond") {
                    BaseControls().padding(6)
                }
                GroupBox("Touches personnalisées") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 12) {
                            Picker("Outil", selection: $tool) {
                                Label("Pinceau", systemImage: "paintbrush").tag(Tool.brush)
                                Label("Gomme", systemImage: "eraser").tag(Tool.eraser)
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 220)
                            ColorPicker("Couleur", selection: $brush, supportsOpacity: false)
                            Spacer()
                            Button("Tout remplir") { controller.fill(RGB(brush)) }
                            Button("Tout effacer") { controller.clearOverlay() }
                        }
                        KeyboardCanvas(colors: LightingPreview.colors(base: controller.base, overlay: controller.overlay)) { index in
                            controller.paint([index], color: tool == .brush ? RGB(brush) : nil)
                        }
                        Text("Aperçu statique · effet de fond : \(EffectCatalog.name(for: controller.base.effectID)). Le clavier montre le rendu réel.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(6)
                }
                HStack {
                    Spacer()
                    Button("Enregistrer comme preset…") {
                        presetName = ""
                        savingPreset = true
                    }
                }
            }
            .padding(20)
            .disabled(!controller.canControl)
        }
        .sheet(isPresented: $savingPreset) {
            NamePrompt(title: "Nouveau preset", name: $presetName) {
                presets.add(Preset(name: presetName, base: controller.base, overlay: controller.overlay))
            }
        }
        // While the editor is the key window, the audio mode pauses: the saved lighting stays visible.
        .onChange(of: activeState, initial: true) { _, state in audio.setPaused(state == .key) }
        .onDisappear { audio.setPaused(false) }
    }
}
