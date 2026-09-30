/// One key of the Ducky One 2 SF ISO: LED index, QWERTY position name, AZERTY legend,
/// physical rectangle in key units (from the QMK iso/keyboard.json layout).
public struct KeyInfo: Identifiable, Hashable, Sendable {
    public let id: Int
    public let name: String
    public let legend: String
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public func contains(x px: Double, y py: Double) -> Bool {
        px >= x && px < x + width && py >= y && py < y + height
    }
}

public enum KeyboardLayout {
    public static let ledCount = 68
    public static let width = 16.25
    public static let height = 5.0

    private static let names = ("esc 1 2 3 4 5 6 7 8 9 0 minus equal backspace delete "
        + "tab q w e r t y u i o p lbracket rbracket pageup "
        + "caps a s d f g h j k l semicolon quote hash enter pagedown "
        + "lshift iso_backslash z x c v b n m comma dot slash rshift up "
        + "lctrl lgui lalt space ralt fn rctrl left down right").split(separator: " ").map(String.init)

    private static let legends = [
        "Échap", "&", "é", "\"", "'", "(", "-", "è", "_", "ç", "à", ")", "=", "⌫", "Suppr",
        "⇥", "A", "Z", "E", "R", "T", "Y", "U", "I", "O", "P", "^", "$", "⇞",
        "⇪", "Q", "S", "D", "F", "G", "H", "J", "K", "L", "M", "ù", "*", "↩", "⇟",
        "⇧", "<", "W", "X", "C", "V", "B", "N", ",", ";", ":", "!", "⇧", "↑",
        "Ctrl", "⌘", "⌥", "", "⌥", "Fn", "Ctrl", "←", "↓", "→",
    ]

    private static let geometry: [(Double, Double, Double, Double)] = [
        (0, 0, 1, 1), (1, 0, 1, 1), (2, 0, 1, 1), (3, 0, 1, 1), (4, 0, 1, 1), (5, 0, 1, 1),
        (6, 0, 1, 1), (7, 0, 1, 1), (8, 0, 1, 1), (9, 0, 1, 1), (10, 0, 1, 1), (11, 0, 1, 1),
        (12, 0, 1, 1), (13, 0, 2, 1), (15.25, 0, 1, 1), (0, 1, 1.5, 1), (1.5, 1, 1, 1), (2.5, 1, 1, 1),
        (3.5, 1, 1, 1), (4.5, 1, 1, 1), (5.5, 1, 1, 1), (6.5, 1, 1, 1), (7.5, 1, 1, 1), (8.5, 1, 1, 1),
        (9.5, 1, 1, 1), (10.5, 1, 1, 1), (11.5, 1, 1, 1), (12.5, 1, 1, 1), (15.25, 1, 1, 1), (0, 2, 1.75, 1),
        (1.75, 2, 1, 1), (2.75, 2, 1, 1), (3.75, 2, 1, 1), (4.75, 2, 1, 1), (5.75, 2, 1, 1), (6.75, 2, 1, 1),
        (7.75, 2, 1, 1), (8.75, 2, 1, 1), (9.75, 2, 1, 1), (10.75, 2, 1, 1), (11.75, 2, 1, 1), (12.75, 2, 1, 1),
        (13.75, 1, 1.25, 2), (15.25, 2, 1, 1), (0, 3, 1.25, 1), (1.25, 3, 1, 1), (2.25, 3, 1, 1), (3.25, 3, 1, 1),
        (4.25, 3, 1, 1), (5.25, 3, 1, 1), (6.25, 3, 1, 1), (7.25, 3, 1, 1), (8.25, 3, 1, 1), (9.25, 3, 1, 1),
        (10.25, 3, 1, 1), (11.25, 3, 1, 1), (12.25, 3, 2, 1), (14.25, 3, 1, 1), (0, 4, 1.25, 1), (1.25, 4, 1.25, 1),
        (2.5, 4, 1.25, 1), (3.75, 4, 6.25, 1), (10, 4, 1, 1), (11, 4, 1, 1), (12, 4, 1.25, 1), (13.25, 4, 1, 1),
        (14.25, 4, 1, 1), (15.25, 4, 1, 1),
    ]

    public static let keys: [KeyInfo] = (0..<ledCount).map { i in
        let (x, y, w, h) = geometry[i]
        return KeyInfo(id: i, name: names[i], legend: legends[i], x: x, y: y, width: w, height: h)
    }

    public static func index(named name: String) -> Int? {
        keys.first { $0.name == name }?.id
    }

    /// The key under a point expressed in key units.
    public static func key(atX x: Double, y: Double) -> KeyInfo? {
        keys.first { $0.contains(x: x, y: y) }
    }
}
