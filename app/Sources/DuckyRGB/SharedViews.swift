import AppKit
import DuckyCore
import SwiftUI

extension Color {
    init(_ rgb: RGB) {
        self.init(.sRGB, red: Double(rgb.r) / 255, green: Double(rgb.g) / 255, blue: Double(rgb.b) / 255, opacity: 1)
    }
}

extension RGB {
    init(_ color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .black
        func byte(_ x: CGFloat) -> UInt8 { UInt8(max(0, min(255, (x * 255).rounded()))) }
        self.init(byte(ns.redComponent), byte(ns.greenComponent), byte(ns.blueComponent))
    }

    /// Readable legend colour on top of this key colour.
    var legendColor: Color {
        let luminance = 0.299 * Double(r) + 0.587 * Double(g) + 0.114 * Double(b)
        return luminance > 140 ? .black : .white
    }
}

struct StatusHeader: View {
    @Environment(LightingController.self) private var controller

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Circle().fill(dotColor).frame(width: 8, height: 8)
                Text("Ducky One 2 SF").font(.headline)
            }
            Text(detail).font(.caption).foregroundStyle(.secondary)
            if let error = controller.lastError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private var dotColor: Color {
        switch controller.connection {
        case .disconnected: return .gray
        case .outdatedFirmware: return .orange
        case .connected:
            if case .failed = controller.saveState { return .red }
            return .green
        }
    }

    private var detail: String {
        switch controller.connection {
        case .disconnected: return "Non détecté"
        case .outdatedFirmware(let version): return "Firmware v\(version) : à mettre à jour (protocole v2 requis)"
        case .connected:
            switch controller.saveState {
            case .saved: return "Connecté · enregistré dans le clavier"
            case .pending: return "Connecté · modifications en cours…"
            case .failed(let message): return "Échec d'enregistrement : \(message)"
            }
        }
    }
}

struct HostModeBanner: View {
    @Environment(LightingController.self) private var controller

    var body: some View {
        if controller.hostMode {
            HStack {
                Label("Contrôlé par la CLI", systemImage: "terminal")
                Spacer()
                Button("Reprendre la main") { controller.releaseHostMode() }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 6).fill(.orange.opacity(0.15)))
        }
    }
}

/// Effect, on/off, colour, brightness and speed of the base layer.
struct BaseControls: View {
    @Environment(LightingController.self) private var controller
    private let showsColor: Bool

    init(showsColor: Bool = true) {
        self.showsColor = showsColor
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Fond allumé", isOn: binding(\.enabled))
            Picker("Effet", selection: binding(\.effectID)) {
                ForEach(controller.effects) { effect in
                    Text(effect.name).tag(effect.id)
                }
            }
            if showsColor {
                ColorPicker("Couleur du fond", selection: baseColor, supportsOpacity: false)
            }
            LabeledContent("Luminosité") {
                Slider(value: level(\.brightness), in: 0...200)
            }
            LabeledContent("Vitesse") {
                Slider(value: level(\.speed), in: 0...255)
            }
        }
        .disabled(!controller.canControl)
    }

    private func binding<T>(_ keyPath: WritableKeyPath<BaseSettings, T>) -> Binding<T> {
        Binding(
            get: { controller.base[keyPath: keyPath] },
            set: { value in
                var base = controller.base
                base[keyPath: keyPath] = value
                controller.setBase(base)
            }
        )
    }

    private func level(_ keyPath: WritableKeyPath<BaseSettings, UInt8>) -> Binding<Double> {
        Binding(
            get: { Double(controller.base[keyPath: keyPath]) },
            set: { value in
                var base = controller.base
                base[keyPath: keyPath] = UInt8(max(0, min(255, value.rounded())))
                controller.setBase(base)
            }
        )
    }

    /// Hue and saturation of the base; brightness stays on its own slider.
    private var baseColor: Binding<Color> {
        Binding(
            get: { Color(RGB(hue: controller.base.hue, saturation: controller.base.saturation, value: 255)) },
            set: { color in
                guard let ns = NSColor(color).usingColorSpace(.sRGB) else { return }
                var base = controller.base
                (base.hue, base.saturation) = QMKColor.hueSaturation(fromUnitHue: ns.hueComponent, saturation: ns.saturationComponent)
                controller.setBase(base)
            }
        )
    }
}

struct NamePrompt: View {
    private let title: String
    @Binding private var name: String
    private let onSave: () -> Void
    @Environment(\.dismiss) private var dismiss

    init(title: String, name: Binding<String>, onSave: @escaping () -> Void) {
        self.title = title
        self._name = name
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            TextField("Nom", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
                .onSubmit(save)
            HStack {
                Spacer()
                Button("Annuler") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Enregistrer", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
    }

    private func save() {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        onSave()
        dismiss()
    }
}
