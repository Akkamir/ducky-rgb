/// Static approximation of what the keyboard shows: custom keys dimmed by the brightness, other
/// keys in the base colour (animated effects are represented by their base colour).
public enum LightingPreview {
    public static func colors(base: BaseSettings, overlay: [RGB?]) -> [RGB] {
        let background = base.enabled ? RGB(hue: base.hue, saturation: base.saturation, value: base.brightness) : .black
        return overlay.map { $0?.scaled(by: base.brightness) ?? background }
    }
}
