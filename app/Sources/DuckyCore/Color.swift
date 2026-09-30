import Foundation

public struct RGB: Codable, Hashable, Sendable {
    public var r: UInt8
    public var g: UInt8
    public var b: UInt8

    public init(_ r: UInt8, _ g: UInt8, _ b: UInt8) {
        self.r = r
        self.g = g
        self.b = b
    }

    public static let black = RGB(0, 0, 0)

    /// QMK-style HSV, every component 0-255.
    public init(hue: UInt8, saturation: UInt8, value: UInt8) {
        let h = Double(hue) / 256 * 6
        let s = Double(saturation) / 255
        let v = Double(value) / 255
        let f = h - floor(h)
        let p = v * (1 - s), q = v * (1 - s * f), t = v * (1 - s * (1 - f))
        let rgb: (Double, Double, Double)
        switch Int(h) % 6 {
        case 0: rgb = (v, t, p)
        case 1: rgb = (q, v, p)
        case 2: rgb = (p, v, t)
        case 3: rgb = (p, q, v)
        case 4: rgb = (t, p, v)
        default: rgb = (v, p, q)
        }
        func byte(_ x: Double) -> UInt8 { UInt8((x * 255).rounded()) }
        self.init(byte(rgb.0), byte(rgb.1), byte(rgb.2))
    }

    /// Dims the colour the way the firmware applies brightness to custom keys.
    public func scaled(by value: UInt8) -> RGB {
        func s(_ c: UInt8) -> UInt8 { UInt8(UInt16(c) * UInt16(value) / 255) }
        return RGB(s(r), s(g), s(b))
    }
}

extension RGB {
    /// Hue and saturation in 0...1, as NSColor's HSB components report them.
    public var unitHueSaturation: (hue: Double, saturation: Double) {
        let r = Double(self.r) / 255, g = Double(self.g) / 255, b = Double(self.b) / 255
        let maxC = max(r, g, b), minC = min(r, g, b), delta = maxC - minC
        guard delta > 0 else { return (0, 0) }
        var hue: Double
        if maxC == r {
            hue = (g - b) / delta
        } else if maxC == g {
            hue = (b - r) / delta + 2
        } else {
            hue = (r - g) / delta + 4
        }
        hue /= 6
        if hue < 0 { hue += 1 }
        return (hue, delta / maxC)
    }
}

/// Conversions between unit HSB components (colour pickers) and QMK's 0-255 HSV.
public enum QMKColor {
    public static func hueSaturation(fromUnitHue hue: Double, saturation: Double) -> (hue: UInt8, saturation: UInt8) {
        // Nearest step, wrapping 256 back to 0: the exact inverse of RGB(hue:saturation:value:).
        (UInt8(Int((max(0, min(1, hue)) * 256).rounded()) % 256), UInt8(max(0, min(255, (saturation * 255).rounded()))))
    }
}
