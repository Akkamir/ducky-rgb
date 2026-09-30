import XCTest
@testable import DuckyCore

@MainActor
final class LightingControllerTests: XCTestCase {
    private func waitUntil(_ timeout: TimeInterval = 2, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func started(_ fake: FakeKeyboard, saveDelay: TimeInterval = 0.1) async -> LightingController {
        let controller = LightingController(transport: fake, saveDelay: saveDelay)
        controller.start()
        await waitUntil { controller.connection != .disconnected }
        return controller
    }

    func testConnectReadsKeyboardState() async {
        let fake = FakeKeyboard()
        fake.base = BaseSettings(effectID: 7, hue: 42)
        fake.overlay[3] = RGB(9, 9, 9)
        let controller = await started(fake)
        XCTAssertEqual(controller.connection, .connected)
        XCTAssertEqual(controller.base.effectID, 7)
        XCTAssertEqual(controller.overlay[3], RGB(9, 9, 9))
        XCTAssertEqual(controller.effects.count, 14)
        XCTAssertEqual(controller.info?.persistent, true)
    }

    func testOutdatedFirmwareBlocksControl() async {
        let fake = FakeKeyboard(version: 1)
        let controller = await started(fake)
        XCTAssertEqual(controller.connection, .outdatedFirmware(version: 1))
        XCTAssertFalse(controller.canControl)
        let before = fake.commands().count
        controller.setBase(BaseSettings(effectID: 2))
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(fake.commands().count, before)
    }

    func testBurstOfChangesSavesOnce() async {
        let fake = FakeKeyboard()
        let controller = await started(fake, saveDelay: 0.2)
        for speed in UInt8(1)...5 {
            controller.setBase(BaseSettings(effectID: 1, speed: speed))
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(controller.saveState, .pending)
        await waitUntil { controller.saveState == .saved }
        XCTAssertEqual(fake.commands().filter { $0 == .setBase }.count, 5)
        XCTAssertEqual(fake.commands().filter { $0 == .save }.count, 1)
        XCTAssertEqual(fake.savedBase?.speed, 5)
    }

    func testApplyPresetWritesBaseAndOverlay() async {
        let fake = FakeKeyboard()
        let controller = await started(fake)
        let preset = Preset.builtIns.first { $0.name == "Jeu ZQSD" }!
        controller.apply(preset)
        XCTAssertTrue(preset.matches(base: controller.base, overlay: controller.overlay))
        await waitUntil { controller.saveState == .saved && fake.savedOverlay != nil }
        XCTAssertEqual(fake.savedBase, preset.base)
        XCTAssertEqual(fake.savedOverlay, preset.overlayColors())
    }

    func testPaintEraseAndClear() async {
        let fake = FakeKeyboard()
        let controller = await started(fake)
        controller.paint([0, 1], color: RGB(255, 0, 0))
        controller.paint([1], color: nil)
        await waitUntil { fake.overlay[0] != nil }
        XCTAssertEqual(controller.overlay[0], RGB(255, 0, 0))
        XCTAssertNil(controller.overlay[1])
        controller.clearOverlay()
        await waitUntil { fake.overlay[0] == nil }
        XCTAssertTrue(controller.overlay.allSatisfy { $0 == nil })
    }

    func testReconnectRefreshesState() async {
        let fake = FakeKeyboard()
        let controller = await started(fake)
        fake.setConnected(false)
        await waitUntil { controller.connection == .disconnected }
        fake.base = BaseSettings(effectID: 9)
        fake.setConnected(true)
        await waitUntil { controller.connection == .connected && controller.base.effectID == 9 }
        XCTAssertEqual(controller.base.effectID, 9)
    }

    func testRejectedCommandIsReported() async {
        let fake = FakeKeyboard()
        let controller = await started(fake)
        fake.failNext(.setBase, with: .badArgument)
        controller.setBase(BaseSettings(effectID: 3))
        await waitUntil { controller.lastError != nil }
        XCTAssertNotNil(controller.lastError)
    }

    func testReleaseHostMode() async {
        let fake = FakeKeyboard()
        fake.hostMode = true
        let controller = await started(fake)
        XCTAssertTrue(controller.hostMode)
        controller.releaseHostMode()
        await waitUntil { !fake.hostMode }
        XCTAssertFalse(controller.hostMode)
    }

    func testTransientWriteErrorKeepsConnection() async {
        let fake = FakeKeyboard()
        let controller = await started(fake)
        fake.throwNext(.setBase, .notConnected)
        controller.setBase(BaseSettings(effectID: 3))
        await waitUntil { controller.lastError != nil }
        XCTAssertEqual(controller.connection, .connected)
    }

    func testRefreshIfPresentRecoversAfterFailedStart() async {
        let fake = FakeKeyboard()
        fake.throwNext(.ping, .timeout)
        let controller = LightingController(transport: fake, saveDelay: 0.1)
        controller.start()
        await waitUntil { controller.lastError != nil }
        XCTAssertEqual(controller.connection, .disconnected)
        controller.refreshIfPresent()
        await waitUntil { controller.connection == .connected }
        XCTAssertEqual(controller.connection, .connected)
    }

    func testSuccessfulEditClearsError() async {
        let fake = FakeKeyboard()
        let controller = await started(fake)
        fake.failNext(.setBase, with: .badArgument)
        controller.setBase(BaseSettings(effectID: 3))
        await waitUntil { controller.lastError != nil }
        controller.setBase(BaseSettings(effectID: 4))
        await waitUntil { controller.lastError == nil }
        XCTAssertNil(controller.lastError)
    }

    func testFlushPendingSaveWritesImmediately() async {
        let fake = FakeKeyboard()
        let controller = await started(fake, saveDelay: 60)
        controller.setBase(BaseSettings(effectID: 6))
        var flushed = false
        controller.flushPendingSave { flushed = true }
        await waitUntil { flushed }
        XCTAssertTrue(flushed)
        XCTAssertEqual(fake.savedBase?.effectID, 6)
        XCTAssertEqual(controller.saveState, .saved)
    }
}
