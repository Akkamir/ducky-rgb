import Foundation

/// A lighting setup: a base effect plus optional per-key colours.
public struct Preset: Codable, Identifiable, Hashable, Sendable {
    public struct CustomKey: Codable, Hashable, Sendable {
        public var index: Int
        public var color: RGB
    }

    public var id: UUID
    public var name: String
    public var base: BaseSettings
    public var customKeys: [CustomKey]
    public var builtIn: Bool

    public init(id: UUID = UUID(), name: String, base: BaseSettings, overlay: [RGB?], builtIn: Bool = false) {
        self.id = id
        self.name = name
        self.base = base
        self.customKeys = overlay.enumerated().compactMap { index, color in color.map { CustomKey(index: index, color: $0) } }
        self.builtIn = builtIn
    }

    public func overlayColors(ledCount: Int = KeyboardLayout.ledCount) -> [RGB?] {
        var colors = [RGB?](repeating: nil, count: ledCount)
        for key in customKeys where colors.indices.contains(key.index) {
            colors[key.index] = key.color
        }
        return colors
    }

    public func matches(base other: BaseSettings, overlay: [RGB?]) -> Bool {
        base == other && overlayColors(ledCount: overlay.count) == overlay
    }
}

extension Preset {
    private static func overlay(_ keys: [String: RGB]) -> [RGB?] {
        var colors = [RGB?](repeating: nil, count: KeyboardLayout.ledCount)
        for (name, color) in keys {
            if let index = KeyboardLayout.index(named: name) { colors[index] = color }
        }
        return colors
    }

    private static func builtInID(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "D0C1A000-0000-4000-8000-%012d", n))!
    }

    public static let builtIns: [Preset] = {
        let red = RGB(255, 0, 0), orange = RGB(255, 120, 0), white = RGB(255, 255, 255)
        return [
            Preset(id: builtInID(1), name: "Arc-en-ciel",
                   base: BaseSettings(enabled: true, effectID: 5, hue: 0, saturation: 255, brightness: 200, speed: 128),
                   overlay: [], builtIn: true),
            Preset(id: builtInID(2), name: "Respiration blanche",
                   base: BaseSettings(enabled: true, effectID: 2, hue: 0, saturation: 0, brightness: 200, speed: 80),
                   overlay: [], builtIn: true),
            Preset(id: builtInID(3), name: "Nuit",
                   base: BaseSettings(enabled: true, effectID: 1, hue: 0, saturation: 255, brightness: 50, speed: 128),
                   overlay: [], builtIn: true),
            Preset(id: builtInID(4), name: "Jeu ZQSD",
                   base: BaseSettings(enabled: true, effectID: 1, hue: 170, saturation: 255, brightness: 110, speed: 128),
                   overlay: overlay(["w": red, "a": red, "s": red, "d": red,
                                     "up": orange, "left": orange, "down": orange, "right": orange]),
                   builtIn: true),
            Preset(id: builtInID(5), name: "Focus",
                   base: BaseSettings(enabled: false, effectID: 1, hue: 0, saturation: 0, brightness: 120, speed: 128),
                   overlay: overlay(["esc": white]), builtIn: true),
            // The audio mode's ocean rows as a still background; typing heats keys in aqua, then foam white.
            Preset(id: builtInID(6), name: "Océan heatmap",
                   base: BaseSettings(enabled: true, effectID: 16, hue: 117, saturation: 255, brightness: 140, speed: 128),
                   overlay: KeyboardLayout.keys.map { EqualiserPalette.ocean.rows[Int($0.y + $0.height - 1)] },
                   builtIn: true),
        ]
    }()
}
