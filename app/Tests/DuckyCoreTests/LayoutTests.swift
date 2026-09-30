import XCTest
@testable import DuckyCore

final class LayoutTests: XCTestCase {
    func testSixtyEightKeysWithSequentialLEDIndices() {
        XCTAssertEqual(KeyboardLayout.keys.count, 68)
        XCTAssertEqual(KeyboardLayout.keys.map(\.id), Array(0..<68))
        XCTAssertEqual(KeyboardLayout.index(named: "enter"), 42)
        XCTAssertEqual(KeyboardLayout.keys[1].legend, "&")
        XCTAssertEqual(KeyboardLayout.keys[16].legend, "A")
    }

    func testHitTesting() {
        XCTAssertEqual(KeyboardLayout.key(atX: 0.5, y: 0.5)?.name, "esc")
        XCTAssertEqual(KeyboardLayout.key(atX: 14.2, y: 1.5)?.name, "enter")
        XCTAssertEqual(KeyboardLayout.key(atX: 14.2, y: 2.5)?.name, "enter")
        XCTAssertEqual(KeyboardLayout.key(atX: 7, y: 4.5)?.name, "space")
        XCTAssertNil(KeyboardLayout.key(atX: 15.1, y: 0.5))
    }

    func testPreviewLayers() {
        var overlay = [RGB?](repeating: nil, count: 68)
        overlay[0] = RGB(200, 100, 50)
        let base = BaseSettings(enabled: true, effectID: 1, hue: 0, saturation: 255, brightness: 128)
        let colors = LightingPreview.colors(base: base, overlay: overlay)
        XCTAssertEqual(colors[0], RGB(100, 50, 25))
        XCTAssertEqual(colors[1], RGB(hue: 0, saturation: 255, value: 128))

        var off = base
        off.enabled = false
        XCTAssertEqual(LightingPreview.colors(base: off, overlay: overlay)[1], .black)
    }
}
