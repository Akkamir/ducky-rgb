import Foundation
import Observation

/// Built-in presets plus the user's presets, saved as JSON.
@MainActor
@Observable
public final class PresetStore {
    private struct File: Codable {
        var version = 1
        var presets: [Preset]
    }

    public private(set) var userPresets: [Preset] = []
    public private(set) var loadError: String?
    public var all: [Preset] { Preset.builtIns + userPresets }

    private let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
        load()
    }

    public static func standard() -> PresetStore {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return PresetStore(fileURL: support.appendingPathComponent("Ducky RGB/presets.json"))
    }

    public func load() {
        loadError = nil
        guard let data = try? Data(contentsOf: fileURL) else {
            userPresets = []
            return
        }
        do {
            userPresets = try JSONDecoder().decode(File.self, from: data).presets.filter { !$0.builtIn }
        } catch {
            userPresets = []
            let aside = URL(fileURLWithPath: fileURL.path + ".corrupt")
            try? FileManager.default.removeItem(at: aside)
            try? FileManager.default.moveItem(at: fileURL, to: aside)
            loadError = "Fichier de presets illisible, mis de côté : \(aside.lastPathComponent)"
        }
    }

    public func add(_ preset: Preset) {
        var preset = preset
        preset.builtIn = false
        userPresets.append(preset)
        persist()
    }

    public func rename(id: UUID, to name: String) {
        guard let i = userPresets.firstIndex(where: { $0.id == id }) else { return }
        userPresets[i].name = name
        persist()
    }

    @discardableResult
    public func duplicate(id: UUID) -> Preset? {
        guard let source = all.first(where: { $0.id == id }) else { return nil }
        let copy = Preset(name: "\(source.name) (copie)", base: source.base, overlay: source.overlayColors())
        add(copy)
        return copy
    }

    public func delete(id: UUID) {
        userPresets.removeAll { $0.id == id }
        persist()
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(File(presets: userPresets)).write(to: fileURL, options: .atomic)
            loadError = nil
        } catch {
            loadError = "Impossible d'enregistrer les presets : \(error.localizedDescription)"
        }
    }
}
