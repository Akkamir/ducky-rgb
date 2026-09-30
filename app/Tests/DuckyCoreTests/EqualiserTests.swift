import XCTest
@testable import DuckyCore

final class EqualiserTests: XCTestCase {
    func testSilenceIsBlack() {
        let frame = EqualiserRenderer.frame(levels: [Float](repeating: 0, count: 15), palette: .ocean)
        XCTAssertEqual(frame.count, 68)
        XCTAssertTrue(frame.allSatisfy { $0 == .black })
    }

    func testFullLevelsColourEachRow() {
        let frame = EqualiserRenderer.frame(levels: [Float](repeating: 1, count: 15), palette: .sunset)
        XCTAssertEqual(frame[KeyboardLayout.index(named: "esc")!], EqualiserPalette.sunset.rows[0])
        XCTAssertEqual(frame[KeyboardLayout.index(named: "space")!], EqualiserPalette.sunset.rows[4])
        XCTAssertEqual(frame[KeyboardLayout.index(named: "enter")!], EqualiserPalette.sunset.rows[2])
    }

    func testTopLEDOfABarIsPartial() {
        let frame = EqualiserRenderer.frame(levels: [Float](repeating: 0.5, count: 15), palette: .classic)
        let rows = EqualiserPalette.classic.rows
        XCTAssertEqual(frame[KeyboardLayout.index(named: "lctrl")!], rows[4])            // level 0: full
        XCTAssertEqual(frame[KeyboardLayout.index(named: "lshift")!], rows[3])           // level 1: full
        XCTAssertEqual(frame[KeyboardLayout.index(named: "caps")!], rows[2].scaled(by: 128)) // level 2: half
        XCTAssertEqual(frame[KeyboardLayout.index(named: "tab")!], .black)               // level 3: off
    }

    func testPalettesHaveFiveRowsAndFrenchNames() {
        XCTAssertEqual(EqualiserPalette.allCases.map(\.name), ["Classique", "Océan", "Coucher de soleil", "Néon", "Feu"])
        XCTAssertTrue(EqualiserPalette.allCases.allSatisfy { $0.rows.count == 5 })
    }
}
