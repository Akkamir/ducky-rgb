/// Which agent session shows on which indicator key (0 = Delete, 1 = Page Up, 2 = Page Down).
/// Sessions take free slots in arrival order and keep them; a manual choice pins a slot (swapping with its
/// occupant) or hides the session. Choices last as long as the session.
public struct SlotAssignment: Equatable, Sendable {
    public enum Choice: Hashable, Sendable {
        case slot(Int)
        case hidden
    }

    public static let slotCount = 3

    /// Session id -> slot.
    public private(set) var slots: [String: Int] = [:]
    private var manual: [String: Choice] = [:]

    public init() {}

    public func choice(for id: String) -> Choice? { manual[id] }

    public func session(inSlot slot: Int) -> String? {
        slots.first { $0.value == slot }?.key
    }

    /// Recomputes the slots for the current sessions (ordered by arrival).
    public mutating func update(sessions: [AgentSession]) {
        let ids = Set(sessions.map(\.id))
        manual = manual.filter { ids.contains($0.key) }
        var next: [String: Int] = [:]
        for (id, choice) in manual {
            if case .slot(let slot) = choice { next[id] = slot }
        }
        for session in sessions where manual[session.id] == nil {
            if let slot = slots[session.id], !next.values.contains(slot) { next[session.id] = slot } // keeps its key
        }
        for session in sessions where manual[session.id] == nil && next[session.id] == nil {
            guard let free = (0..<Self.slotCount).first(where: { !next.values.contains($0) }) else { break }
            next[session.id] = free
        }
        slots = next
    }

    public mutating func choose(_ choice: Choice, for id: String, sessions: [AgentSession]) {
        if case .slot(let slot) = choice, let occupant = session(inSlot: slot), occupant != id {
            if let own = slots[id] {
                manual[occupant] = .slot(own) // swap
            } else {
                manual[occupant] = nil
                slots[occupant] = nil // back to the waiting list
            }
        }
        manual[id] = choice
        slots[id] = nil
        update(sessions: sessions)
    }
}
