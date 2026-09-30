/// Equaliser colour palettes validated on the keyboard: colours by bar height, top row first.
public enum EqualiserPalette: String, CaseIterable, Codable, Identifiable, Sendable {
    case classic, ocean, sunset, neon, fire

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .classic: return "Classique"
        case .ocean: return "Océan"
        case .sunset: return "Coucher de soleil"
        case .neon: return "Néon"
        case .fire: return "Feu"
        }
    }

    public var rows: [RGB] {
        switch self {
        case .classic: return [RGB(255, 0, 0), RGB(255, 120, 0), RGB(230, 230, 0), RGB(80, 255, 0), RGB(0, 255, 60)]
        case .ocean: return [RGB(240, 250, 255), RGB(120, 235, 255), RGB(0, 210, 255), RGB(0, 150, 255), RGB(0, 90, 255)]
        case .sunset: return [RGB(255, 235, 120), RGB(255, 150, 0), RGB(255, 60, 90), RGB(255, 0, 180), RGB(170, 0, 255)]
        case .neon: return [RGB(160, 255, 255), RGB(255, 120, 230), RGB(255, 0, 200), RGB(140, 0, 255), RGB(0, 110, 255)]
        case .fire: return [RGB(255, 250, 220), RGB(255, 230, 80), RGB(255, 180, 0), RGB(255, 110, 0), RGB(255, 40, 0)]
        }
    }
}

/// eq-smooth: one band per column (by the key's physical position), bar height = level x 5 rows, the top
/// LED lit partially, colour by row.
public enum EqualiserRenderer {
    public static func frame(levels: [Float], palette: EqualiserPalette) -> [RGB] {
        guard !levels.isEmpty else { return [RGB](repeating: .black, count: KeyboardLayout.ledCount) }
        let rows = palette.rows
        return KeyboardLayout.keys.map { key in
            let band = min(levels.count - 1, Int((key.x + key.width / 2) / KeyboardLayout.width * Double(levels.count)))
            let row = Int(key.y + key.height - 1)
            let fill = max(0, min(1, Double(levels[band]) * 5 - Double(4 - row)))
            return rows[row].scaled(by: UInt8((fill * 255).rounded()))
        }
    }
}
