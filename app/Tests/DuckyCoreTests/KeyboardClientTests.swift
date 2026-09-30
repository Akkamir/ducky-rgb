import XCTest
@testable import DuckyCore

final class KeyboardClientTests: XCTestCase {
    func testInfoStateAndEffectsPaging() throws {
        let fake = FakeKeyboard(effectIDs: Array(1...30))
        let client = KeyboardClient(transport: fake)
        XCTAssertEqual(try client.ping().version, 2)
        XCTAssertEqual(try client.info(), KeyboardInfo(version: 2, ledCount: 68, effectCount: 30, persistent: true))
        XCTAssertEqual(try client.effects(count: 30), Array(1...30))
        XCTAssertEqual(fake.commands().filter { $0 == .getEffects }.count, 2)
        XCTAssertEqual(try client.state().base, BaseSettings())
    }

    func testOverlayRoundTripAndChangedChunksOnly() throws {
        let fake = FakeKeyboard()
        let client = KeyboardClient(transport: fake)
        var colors = [RGB?](repeating: nil, count: 68)
        colors[0] = RGB(1, 2, 3)
        colors[67] = RGB(4, 5, 6)
        try client.setOverlay(colors)
        XCTAssertEqual(fake.commands().filter { $0 == .setOverlay }.count, 10)
        XCTAssertEqual(try client.overlay(ledCount: 68), colors)

        colors[20] = RGB(7, 7, 7)
        let before = fake.commands().count
        try client.setOverlay(colors, only: [20])
        XCTAssertEqual(Array(fake.commands().dropFirst(before)), [.setOverlay])
        XCTAssertEqual(fake.overlay[20], RGB(7, 7, 7))
    }

    func testStatusErrorsPropagate() {
        let fake = FakeKeyboard()
        let client = KeyboardClient(transport: fake)
        XCTAssertThrowsError(try client.setBase(BaseSettings(effectID: 99))) { error in
            XCTAssertEqual(error as? DuckyError, .status(.setBase, .badArgument))
        }
    }

    func testMismatchedReplyIsRejected() {
        let reply = DuckyProtocol.request(.getState)
        XCTAssertThrowsError(try DuckyProtocol.payload(of: reply, for: .save))
    }

    func testDisconnectedKeyboardThrows() {
        let client = KeyboardClient(transport: FakeKeyboard(connected: false))
        XCTAssertThrowsError(try client.ping()) { error in
            XCTAssertEqual(error as? DuckyError, .notConnected)
        }
    }
}
