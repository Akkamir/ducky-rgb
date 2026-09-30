/// Effects compiled into the hostrgb firmware, by stable protocol id (spec section 2).
public struct Effect: Identifiable, Hashable, Sendable {
    public let id: UInt8
    public let name: String
}

public enum EffectCatalog {
    public static let all: [Effect] = [
        Effect(id: 1, name: "Couleur unie"),
        Effect(id: 2, name: "Respiration"),
        Effect(id: 3, name: "Dégradé"),
        Effect(id: 4, name: "Cycle de couleurs"),
        Effect(id: 5, name: "Arc-en-ciel"),
        Effect(id: 6, name: "Chevrons"),
        Effect(id: 7, name: "Vague de teinte"),
        Effect(id: 8, name: "Pluie de pixels"),
        Effect(id: 9, name: "Pluie Matrix"),
        Effect(id: 10, name: "Réaction à la frappe"),
        Effect(id: 11, name: "Onde"),
        Effect(id: 12, name: "Ondes multiples"),
        Effect(id: 13, name: "Heatmap de frappe"),
        Effect(id: 14, name: "Bande de saturation"),
        Effect(id: 15, name: "Heatmap sur fond"),
        Effect(id: 16, name: "Heatmap sur couleurs perso"),
    ]

    public static func name(for id: UInt8) -> String {
        all.first { $0.id == id }?.name ?? "Effet \(id)"
    }

    /// What the base colour changes for an effect (checked against the QMK animations), or nil when the
    /// effect ignores it (it picks its own colours).
    public static func colorLabel(for id: UInt8) -> String? {
        switch id {
        case 1: return "Couleur des touches"
        case 2: return "Couleur de la respiration"
        case 3: return "Teinte de départ du dégradé"
        case 7: return "Teinte de la vague"
        case 10, 16: return "Couleur de la frappe"
        case 11, 12: return "Teinte de départ des ondes"
        case 14: return "Couleur de la bande"
        case 15: return "Couleur du fond"
        default: return nil // 4, 5, 6, 8, 9, 13: rainbow, random or fixed colours
        }
    }

    /// Catalog entries for the ids a keyboard reports, keeping unknown ids visible.
    public static func effects(for ids: [UInt8]) -> [Effect] {
        ids.map { id in Effect(id: id, name: name(for: id)) }
    }
}
