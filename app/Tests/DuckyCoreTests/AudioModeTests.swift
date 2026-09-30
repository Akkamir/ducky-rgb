import XCTest
@testable import DuckyCore

final class FakeAudioCapture: AudioCapture, @unchecked Sendable {
    var onSamples: (@Sendable ([Float]) -> Void)?
    var sampleRate: Double = 48000
    var failure: AudioCaptureError?
    private(set) var running = false

    func start() throws {
        if let failure { throw failure }
        running = true
    }

    func stop() { running = false }

    func play(_ samples: [Float]) { onSamples?(samples) }
}

@MainActor
final class AudioModeTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() async throws {
        defaults = UserDefaults(suiteName: "AudioModeTests-\(UUID().uuidString)")
    }

    private let tone = (0..<2048).map { 0.5 * Float(sin(2 * .pi * 1000 * Double($0) / 48000)) }
    private let silence = [Float](repeating: 0, count: 2048)

    private func waitUntil(_ timeout: TimeInterval = 2, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
    }

    private func setUp(_ capture: FakeAudioCapture) async -> (FakeKeyboard, LightingController, AudioMode) {
        let fake = FakeKeyboard()
        let controller = LightingController(transport: fake, saveDelay: 0.1)
        controller.start()
        await waitUntil { controller.connection == .connected }
        let mode = AudioMode(controller: controller, makeCapture: { capture }, defaults: defaults, autoTick: false)
        return (fake, controller, mode)
    }

    func testSoundShowsTheEqualiser() async {
        let capture = FakeAudioCapture()
        let (fake, _, mode) = await setUp(capture)
        mode.setArmed(true)
        XCTAssertEqual(mode.status, .listening)
        capture.play(tone)
        mode.tick()
        XCTAssertEqual(mode.status, .playing)
        await waitUntil { fake.hostMode && fake.hostColors.contains { $0 != .black } }
        XCTAssertTrue(fake.hostMode)
    }

    func testSilenceReturnsToRestingLightingAfterDelay() async {
        let capture = FakeAudioCapture()
        let (fake, _, mode) = await setUp(capture)
        mode.setArmed(true)
        capture.play(tone)
        mode.tick()
        await waitUntil { fake.hostMode }
        capture.play(silence)
        let start = Date()
        mode.tick(now: start)
        mode.tick(now: start.addingTimeInterval(2.9))
        XCTAssertEqual(mode.status, .playing)
        mode.tick(now: start.addingTimeInterval(3.1))
        XCTAssertEqual(mode.status, .listening)
        await waitUntil { !fake.hostMode }
        XCTAssertFalse(fake.hostMode)
    }

    func testPauseShowsRestingLighting() async {
        let capture = FakeAudioCapture()
        let (fake, _, mode) = await setUp(capture)
        mode.setArmed(true)
        capture.play(tone)
        mode.tick()
        await waitUntil { fake.hostMode }
        mode.setPaused(true)
        mode.tick()
        XCTAssertEqual(mode.status, .paused)
        await waitUntil { !fake.hostMode }
        XCTAssertFalse(fake.hostMode)
        mode.setPaused(false)
        mode.tick()
        XCTAssertEqual(mode.status, .playing)
    }

    func testDisarmEndsLiveFramesAndStopsCapture() async {
        let capture = FakeAudioCapture()
        let (fake, _, mode) = await setUp(capture)
        mode.setArmed(true)
        capture.play(tone)
        mode.tick()
        await waitUntil { fake.hostMode }
        mode.setArmed(false)
        XCTAssertFalse(capture.running)
        XCTAssertEqual(mode.status, .off)
        await waitUntil { !fake.hostMode }
        XCTAssertFalse(fake.hostMode)
    }

    func testCaptureFailureIsReported() async {
        let capture = FakeAudioCapture()
        capture.failure = .coreAudio("create tap", -1)
        let (_, _, mode) = await setUp(capture)
        mode.setArmed(true)
        XCTAssertFalse(mode.isArmed)
        guard case .failed = mode.status else { return XCTFail("expected failure, got \(mode.status)") }
    }

    func testArmedStateAndPaletteAreRemembered() async {
        let capture = FakeAudioCapture()
        let (_, controller, mode) = await setUp(capture)
        mode.palette = .neon
        mode.setArmed(true)
        let next = AudioMode(controller: controller, makeCapture: { FakeAudioCapture() }, defaults: defaults, autoTick: false)
        XCTAssertEqual(next.palette, .neon)
        XCTAssertFalse(next.isArmed)
        next.restore()
        XCTAssertTrue(next.isArmed)
    }
}
