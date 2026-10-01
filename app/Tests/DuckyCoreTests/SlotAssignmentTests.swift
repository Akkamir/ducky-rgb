import XCTest
@testable import DuckyCore

final class SlotAssignmentTests: XCTestCase {
    private func sessions(_ ids: [String]) -> [AgentSession] {
        ids.enumerated().map { i, id in
            AgentSession(sessionID: id, state: .idle, cwd: "/x", pid: 1, startedAt: Date(timeIntervalSince1970: Double(i)))
        }
    }

    private func slots(_ plan: SlotAssignment) -> [String: Int] {
        Dictionary(uniqueKeysWithValues: plan.slots.map { (String($0.key.dropFirst("claude-".count)), $0.value) })
    }

    func testArrivalOrderAndWaiting() {
        var plan = SlotAssignment()
        plan.update(sessions: sessions(["a", "b", "c", "d"]))
        XCTAssertEqual(slots(plan), ["a": 0, "b": 1, "c": 2])
    }

    func testSlotsAreStableAndFreedSlotGoesToOldestWaiting() {
        var plan = SlotAssignment()
        var all = sessions(["a", "b", "c", "d", "e"])
        plan.update(sessions: all)
        all.remove(at: 1) // b ends: its slot goes to d, the oldest waiting; a and c keep theirs
        plan.update(sessions: all)
        XCTAssertEqual(slots(plan), ["a": 0, "c": 2, "d": 1])
    }

    func testChoosingAnOccupiedSlotSwaps() {
        var plan = SlotAssignment()
        let all = sessions(["a", "b", "c"])
        plan.update(sessions: all)
        plan.choose(.slot(0), for: all[2].id, sessions: all)
        XCTAssertEqual(slots(plan), ["c": 0, "b": 1, "a": 2])
        plan.update(sessions: all)
        XCTAssertEqual(slots(plan), ["c": 0, "b": 1, "a": 2])
    }

    func testChoosingFromTheWaitingListTakesTheSlot() {
        var plan = SlotAssignment()
        let all = sessions(["a", "b", "c", "d"])
        plan.update(sessions: all)
        plan.choose(.slot(1), for: all[3].id, sessions: all)
        XCTAssertEqual(slots(plan), ["a": 0, "d": 1, "c": 2])
    }

    func testHiddenSessionStaysOff() {
        var plan = SlotAssignment()
        let all = sessions(["a", "b", "c", "d"])
        plan.update(sessions: all)
        plan.choose(.hidden, for: all[0].id, sessions: all)
        XCTAssertEqual(slots(plan), ["b": 1, "c": 2, "d": 0])
        XCTAssertEqual(plan.choice(for: all[0].id), .hidden)
        plan.update(sessions: all)
        XCTAssertNil(plan.slots[all[0].id])
        plan.choose(.slot(2), for: all[0].id, sessions: all)
        XCTAssertEqual(slots(plan), ["b": 1, "a": 2, "d": 0])
    }

    func testEndedSessionsAreForgotten() {
        var plan = SlotAssignment()
        let all = sessions(["a", "b"])
        plan.update(sessions: all)
        plan.choose(.hidden, for: all[0].id, sessions: all)
        plan.update(sessions: [all[1]])
        XCTAssertNil(plan.choice(for: all[0].id))
        XCTAssertEqual(plan.session(inSlot: 1), all[1].id)
    }
}
