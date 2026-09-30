import XCTest
@testable import DuckyCore

final class ProtocolTests: XCTestCase {
    func testRequestIsPaddedTo32Bytes() {
        let report = DuckyProtocol.request(.getOverlay, [7])
        XCTAssertEqual(report.count, 32)
        XCTAssertEqual(Array(report.prefix(3)), [0x14, 7, 0])
    }

    func testPayloadRejectsErrorStatusAndWrongCommand() {
        var reply = [UInt8](repeating: 0, count: 32)
        reply[0] = 0x13
        reply[1] = 2
        XCTAssertThrowsError(try DuckyProtocol.payload(of: reply, for: .setBase)) { error in
            XCTAssertEqual(error as? DuckyError, .status(.setBase, .badArgument))
        }
        reply[1] = 0
        XCTAssertThrowsError(try DuckyProtocol.payload(of: reply, for: .save)) { error in
            XCTAssertEqual(error as? DuckyError, .malformedReply)
        }
        XCTAssertEqual(try DuckyProtocol.payload(of: reply, for: .setBase).count, 30)
    }

    func testSetBaseEncoding() {
        let base = BaseSettings(enabled: false, effectID: 5, hue: 10, saturation: 20, brightness: 30, speed: 40)
        XCTAssertEqual(Array(DuckyProtocol.setBase(base).prefix(7)), [0x13, 0, 5, 10, 20, 30, 40])
    }

    func testSetOverlayEncoding() {
        let report = DuckyProtocol.setOverlay(first: 14, colors: [RGB(1, 2, 3), nil])
        XCTAssertEqual(Array(report.prefix(11)), [0x15, 14, 2, 1, 1, 2, 3, 0, 0, 0, 0])
    }

    func testDecodeStateAndOverlay() throws {
        let state = try DuckyProtocol.decodeState([1, 4, 10, 20, 30, 40, 1, 3, 1] + zeros(21))
        XCTAssertEqual(state.base, BaseSettings(enabled: true, effectID: 4, hue: 10, saturation: 20, brightness: 30, speed: 40))
        XCTAssertTrue(state.hostMode)
        XCTAssertEqual(state.customizedCount, 3)
        XCTAssertTrue(state.dirty)

        let overlay = try DuckyProtocol.decodeOverlay([63, 2, 1, 9, 8, 7, 0, 0, 0, 0] + zeros(20))
        XCTAssertEqual(overlay.first, 63)
        XCTAssertEqual(overlay.colors, [RGB(9, 8, 7), nil])
    }

    func testDecodeRejectsOversizedCounts() {
        XCTAssertThrowsError(try DuckyProtocol.decodeOverlay([0, 8] + zeros(28)))
        XCTAssertThrowsError(try DuckyProtocol.decodeEffects([0, 29] + zeros(28)))
    }

    func testHSVConversionMatchesPrimaryColours() {
        XCTAssertEqual(RGB(hue: 0, saturation: 255, value: 255), RGB(255, 0, 0))
        XCTAssertEqual(RGB(hue: 85, saturation: 255, value: 255), RGB(2, 255, 0))
        XCTAssertEqual(RGB(hue: 0, saturation: 0, value: 200), RGB(200, 200, 200))
        XCTAssertEqual(RGB(200, 100, 50).scaled(by: 128), RGB(100, 50, 25))
    }

    func testEffectCatalogNames() {
        XCTAssertEqual(EffectCatalog.all.count, 15)
        XCTAssertEqual(EffectCatalog.name(for: 15), "Heatmap sur fond")
        XCTAssertEqual(EffectCatalog.name(for: 1), "Couleur unie")
        XCTAssertEqual(EffectCatalog.name(for: 99), "Effet 99")
    }

    private func zeros(_ n: Int) -> [UInt8] { [UInt8](repeating: 0, count: n) }

    func testBaseColourRoundTripsEveryHue() {
        for saturation in [UInt8(255), 128] {
            for hue in 0...255 {
                let rgb = RGB(hue: UInt8(hue), saturation: saturation, value: 255)
                let unit = rgb.unitHueSaturation
                let back = QMKColor.hueSaturation(fromUnitHue: unit.hue, saturation: unit.saturation)
                XCTAssertEqual(back.hue, UInt8(hue), "hue \(hue) sat \(saturation)")
            }
        }
    }
}
