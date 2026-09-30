import DuckyCore
import SwiftUI

/// Audio mode switch, palette and status, for the menu bar extra.
struct AudioModeSection: View {
    @Environment(AudioMode.self) private var audio

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Mode audio", isOn: Binding(get: { audio.isArmed }, set: { audio.setArmed($0) }))
            Picker("Palette", selection: Binding(get: { audio.palette }, set: { audio.palette = $0 })) {
                ForEach(EqualiserPalette.allCases) { palette in
                    Text(palette.name).tag(palette)
                }
            }
            Text(statusText)
                .font(.caption)
                .foregroundStyle(statusColor)
        }
    }

    private var statusText: String {
        switch audio.status {
        case .off: return "Désactivé"
        case .listening: return "En écoute · éclairage de repos"
        case .playing: return "Égaliseur actif"
        case .paused: return "En pause pendant l'édition"
        case .failed(let message): return "Échec : \(message)"
        }
    }

    private var statusColor: Color {
        if case .failed = audio.status { return .red }
        return .secondary
    }
}
