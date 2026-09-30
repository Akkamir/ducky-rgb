# Audio Mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An "audio mode" in Ducky RGB: while armed and the Mac plays sound, the keyboard shows the validated eq-smooth equaliser; after 3 s of silence it returns to the saved lighting.

**Architecture:** `DuckyCore` gains a pure spectrum analyzer and equaliser renderer (ported from `experiments/audio`), a Core Audio system tap behind an `AudioCapture` protocol, live host-mode frames in `LightingController` (coalesced, never saved) and an observable `AudioMode` that ticks at 30 Hz. The app adds a menu section, pauses audio while the editor is the key window and ends live frames before quitting.

**Tech Stack:** Swift 5 mode, SwiftUI, Observation, Accelerate (vDSP), Core Audio process taps (macOS 14.2+), XCTest.

**Spec:** `docs/superpowers/specs/2026-10-01-audio-mode-design.md`

**Extraction:** `python3 scripts/extract_plan_files.py docs/superpowers/plans/2026-10-01-audio-mode.md --task N <paths>`

## Global Constraints

- Minimum macOS 14.2 (package platform and bundle `LSMinimumSystemVersion`); bundle carries `NSAudioCaptureUsageDescription`.
- Silence: RMS below -80 dBFS for 3 s; tick 1/30 s; analysis 2048-sample Hann FFT, 15 log bands 40 Hz-16 kHz, auto gain (ceiling -0.15 dB/frame, 45 dB range), smoothing attack instant / decay 0.85.
- Palettes (top row first): classic `ff0000 ff7800 e6e600 50ff00 00ff3c`, ocean `f0faff 78ebff 00d2ff 0096ff 005aff`, sunset `ffeb78 ff9600 ff3c5a ff00b4 aa00ff`, neon `a0ffff ff78e6 ff00c8 8c00ff 006eff`, fire `fffadc ffe650 ffb400 ff6e00 ff2800`.
- Audio mode never writes flash: host commands 0x02/0x03 only; all HID writes go through `LightingController`'s serial queue.
- UI copy in French; code and commits in English; branch `audio-mode`.

## Review Focus

1. Frames arriving faster than the keyboard accepts must not pile up: only the latest pending frame is sent (`testLiveFramesAreCoalesced`).
2. Our own live frames must not raise the "Contrôlé par la CLI" banner, and must resume after a replug (`testOwnLiveFramesDoNotShowCLIBanner`, `testLiveFramesResumeAfterReconnect`).
3. Quitting or disarming must hand the LEDs back to the saved lighting (`testDisarmEndsLiveFramesAndStopsCapture`; quit path drains the HID queue: `testFlushWaitsForQueuedWork`).
4. Capture failure (permission refused) must be visible and leave the mode disarmed (`testCaptureFailureIsReported`).
5. A short gap between tracks must not flicker to the resting lighting before 3 s (`testSilenceReturnsToRestingLightingAfterDelay`).

---

### Task 1: Host frames in the client and the simulated keyboard

**Files:** Modify `app/Sources/DuckyCore/Protocol.swift`, `app/Sources/DuckyCore/KeyboardClient.swift`, `app/Tests/DuckyCoreTests/FakeKeyboard.swift`, `app/Tests/DuckyCoreTests/KeyboardClientTests.swift`

**Interfaces:** Produces `DuckyProtocol.hostLEDsPerReport = 9`, `KeyboardClient.sendHostFrame(_ colors: [RGB]) throws`, `FakeKeyboard.hostColors: [RGB]`.

- [ ] **Step 1: Failing test** (append to `KeyboardClientTests`)

```swift
    func testSendHostFrame() throws {
        let fake = FakeKeyboard()
        let frame = (0..<68).map { RGB(UInt8($0), 0, 255 - UInt8($0)) }
        try KeyboardClient(transport: fake).sendHostFrame(frame)
        XCTAssertEqual(fake.commands().filter { $0 == .hostSet }.count, 8)
        XCTAssertEqual(fake.hostColors, frame)
    }
```

- [ ] **Step 2: Run** `cd app && swift test --filter testSendHostFrame` — Expected: compile failure (`sendHostFrame`, `hostColors`).

- [ ] **Step 3: Implement**

`Protocol.swift`, in `DuckyProtocol`: `public static let hostLEDsPerReport = 9`.

`KeyboardClient.swift`, after `setHostMode`:

```swift
    /// Sends a whole live frame for the host mode, 9 LEDs per report.
    public func sendHostFrame(_ colors: [RGB]) throws {
        for first in stride(from: 0, to: colors.count, by: DuckyProtocol.hostLEDsPerReport) {
            let chunk = colors[first..<min(first + DuckyProtocol.hostLEDsPerReport, colors.count)]
            try send(DuckyProtocol.request(.hostSet, [UInt8(first), UInt8(chunk.count)] + chunk.flatMap { [$0.r, $0.g, $0.b] }))
        }
    }
```

`FakeKeyboard.swift`: add `var hostColors = [RGB](repeating: .black, count: 68)` and replace `case .hostSet, .hostFill: return reply()` with:

```swift
            case .hostSet:
                let first = Int(a[1]), count = Int(a[2])
                guard count <= 9, first + count <= 68 else { return fail(.badArgument) }
                for i in 0..<count { hostColors[first + i] = RGB(a[3 + 3 * i], a[4 + 3 * i], a[5 + 3 * i]) }
                return reply()
            case .hostFill:
                hostColors = [RGB](repeating: RGB(a[1], a[2], a[3]), count: 68)
                return reply()
```

- [ ] **Step 4: Run** `cd app && swift test` — Expected: all pass.
- [ ] **Step 5: Commit** `App: send whole host-mode frames`

---

### Task 2: Live frames in LightingController

**Files:** Modify `app/Sources/DuckyCore/LightingController.swift`, `app/Tests/DuckyCoreTests/LightingControllerTests.swift`

**Interfaces:** Consumes `sendHostFrame` (Task 1). Produces `LightingController.showingLiveFrames: Bool`, `showLiveFrame(_ colors: [RGB])`, `endLiveFrames()`; `flushPendingSave` now always completes after queued HID work.

- [ ] **Step 1: Failing tests** (append to `LightingControllerTests`)

```swift
    func testLiveFramesUseHostModeWithoutSaving() async {
        let fake = FakeKeyboard()
        let controller = await started(fake, saveDelay: 0.1)
        let frame = [RGB](repeating: RGB(255, 0, 0), count: 68)
        controller.showLiveFrame(frame)
        await waitUntil { fake.hostColors == frame }
        XCTAssertTrue(fake.hostMode)
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(fake.commands().contains(.save))
        controller.endLiveFrames()
        await waitUntil { !fake.hostMode }
        XCTAssertFalse(fake.hostMode)
        XCTAssertFalse(controller.showingLiveFrames)
    }

    func testLiveFramesAreCoalesced() async {
        let fake = FakeKeyboard()
        let controller = await started(fake)
        for i in 0..<50 { controller.showLiveFrame([RGB](repeating: RGB(UInt8(i), 0, 0), count: 68)) }
        await waitUntil { fake.hostColors.first == RGB(49, 0, 0) }
        XCTAssertEqual(fake.hostColors.first, RGB(49, 0, 0))
        XCTAssertLessThan(fake.commands().filter { $0 == .hostSet }.count, 50 * 8)
    }

    func testOwnLiveFramesDoNotShowCLIBanner() async {
        let fake = FakeKeyboard()
        let controller = await started(fake)
        controller.showLiveFrame([RGB](repeating: .black, count: 68))
        await waitUntil { fake.hostMode }
        controller.refresh()
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(controller.hostMode)
    }

    func testLiveFramesResumeAfterReconnect() async {
        let fake = FakeKeyboard()
        let controller = await started(fake)
        controller.showLiveFrame([RGB](repeating: .black, count: 68))
        await waitUntil { fake.hostMode }
        fake.setConnected(false)
        await waitUntil { controller.connection == .disconnected }
        fake.hostMode = false // the keyboard restarted
        fake.setConnected(true)
        await waitUntil { controller.connection == .connected }
        controller.showLiveFrame([RGB](repeating: .black, count: 68))
        await waitUntil { fake.hostMode }
        XCTAssertTrue(fake.hostMode)
    }

    func testFlushWaitsForQueuedWork() async {
        let fake = FakeKeyboard()
        let controller = await started(fake)
        controller.showLiveFrame([RGB](repeating: .black, count: 68))
        controller.endLiveFrames()
        var flushed = false
        controller.flushPendingSave { flushed = true }
        await waitUntil { flushed }
        XCTAssertFalse(fake.hostMode)
    }
```

- [ ] **Step 2: Run** `cd app && swift test --filter LightingControllerTests` — Expected: compile failure.

- [ ] **Step 3: Implement**

Add at the end of `LightingController.swift` (file scope):

```swift
/// Holds the latest live frame until the HID queue sends it; older unsent frames are replaced.
final class LiveFrameSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var frame: [RGB]?
    private var enableHostMode = false

    /// Stores the frame; returns true when no send is queued yet.
    func put(_ colors: [RGB], enableHostMode enable: Bool) -> Bool {
        lock.withLock {
            let wasEmpty = frame == nil
            frame = colors
            enableHostMode = enableHostMode || enable
            return wasEmpty
        }
    }

    func take() -> (frame: [RGB], enableHostMode: Bool)? {
        lock.withLock {
            guard let colors = frame else { return nil }
            let enable = enableHostMode
            frame = nil
            enableHostMode = false
            return (colors, enable)
        }
    }

    func clear() {
        lock.withLock {
            frame = nil
            enableHostMode = false
        }
    }
}
```

In the class, after `public private(set) var lastError: String?`:

```swift
    /// True while the app streams live frames (audio mode) through the host mode.
    public private(set) var showingLiveFrames = false
```

and after `private var editGeneration = 0`: `private let liveFrame = LiveFrameSlot()`.

In `connectionChanged(_:)`, first line of the function: `showingLiveFrames = false // a replugged keyboard starts without host mode`.

In `apply(snapshot:)`, replace `hostMode = state.hostMode` with `hostMode = state.hostMode && !showingLiveFrames // our own live frames are not "the CLI"`.

Replace the `guard saveState == .pending, canControl else { completion(); return }` block of `flushPendingSave` with:

```swift
        guard saveState == .pending, canControl else {
            queue.async { Task { @MainActor in completion() } } // after queued HID work
            return
        }
```

Add before `private func edit(`:

```swift
    /// Shows a live frame through the host mode (audio mode). Nothing is saved.
    public func showLiveFrame(_ colors: [RGB]) {
        guard canControl else { return }
        let enableHostMode = !showingLiveFrames
        showingLiveFrames = true
        guard liveFrame.put(colors, enableHostMode: enableHostMode) else { return }
        queue.async { [client, liveFrame] in
            guard let next = liveFrame.take() else { return }
            do {
                if next.enableHostMode { try client.setHostMode(true) }
                try client.sendHostFrame(next.frame)
            } catch {
                Task { @MainActor [weak self] in self?.report(error) }
            }
        }
    }

    /// Stops live frames: the keyboard shows the saved lighting again.
    public func endLiveFrames() {
        guard showingLiveFrames else { return }
        showingLiveFrames = false
        liveFrame.clear()
        queue.async { [client] in
            do { try client.setHostMode(false) } catch {
                Task { @MainActor [weak self] in self?.report(error) }
            }
        }
    }
```

- [ ] **Step 4: Run** `cd app && swift test` — Expected: all pass.
- [ ] **Step 5: Commit** `App: live host-mode frames in the lighting controller`

---

### Task 3: Spectrum analyzer

**Files:** Create `app/Sources/DuckyCore/SpectrumAnalyzer.swift`, `app/Tests/DuckyCoreTests/SpectrumAnalyzerTests.swift`

**Interfaces:** Produces `struct Spectrum { levels: [Float]; rmsDB: Float }`, `final class SpectrumAnalyzer(sampleRate:fftSize:)` with `static bandCount = 15`, `static silenceThresholdDB: Float = -80`, `var sampleRate`, `append(_ samples: [Float])`, `analyze() -> Spectrum`.

- [ ] **Step 1: Failing tests**

<!-- file: app/Tests/DuckyCoreTests/SpectrumAnalyzerTests.swift -->
```swift
import XCTest
@testable import DuckyCore

final class SpectrumAnalyzerTests: XCTestCase {
    private func sine(_ hz: Double, count: Int = 2048, rate: Double = 48000, amplitude: Float = 0.5) -> [Float] {
        (0..<count).map { amplitude * Float(sin(2 * .pi * hz * Double($0) / rate)) }
    }

    func testToneLandsInItsBand() {
        let analyzer = SpectrumAnalyzer(sampleRate: 48000)
        analyzer.append(sine(1000))
        let spectrum = analyzer.analyze()
        XCTAssertEqual(spectrum.levels.count, 15)
        // log-spaced edges 40 Hz - 16 kHz: 1 kHz is in band 8
        XCTAssertEqual(spectrum.levels.indices.max { spectrum.levels[$0] < spectrum.levels[$1] }, 8)
        XCTAssertGreaterThan(spectrum.rmsDB, -20)
    }

    func testSilenceIsBelowThreshold() {
        let analyzer = SpectrumAnalyzer(sampleRate: 48000)
        analyzer.append([Float](repeating: 0, count: 2048))
        XCTAssertLessThan(analyzer.analyze().rmsDB, SpectrumAnalyzer.silenceThresholdDB)
    }

    func testLevelsFallGraduallyAfterSound() {
        let analyzer = SpectrumAnalyzer(sampleRate: 48000)
        analyzer.append(sine(1000))
        XCTAssertEqual(analyzer.analyze().levels[8], 1, accuracy: 0.001)
        analyzer.append([Float](repeating: 0, count: 2048))
        let after = analyzer.analyze().levels[8]
        XCTAssertGreaterThan(after, 0.8)
        XCTAssertLessThan(after, 1)
    }
}
```

- [ ] **Step 2: Run** `cd app && swift test --filter SpectrumAnalyzerTests` — Expected: compile failure.

- [ ] **Step 3: Implement**

<!-- file: app/Sources/DuckyCore/SpectrumAnalyzer.swift -->
```swift
import Accelerate
import Foundation

public struct Spectrum: Sendable {
    /// 15 smoothed band levels, 0...1, bass first.
    public let levels: [Float]
    /// Loudness of the analysed window (RMS, dBFS).
    public let rmsDB: Float
}

/// Mono samples in, 15 smoothed log-spaced band levels out (40 Hz - 16 kHz), with automatic gain.
/// `append` may be called from the capture thread; `analyze` from one other thread.
public final class SpectrumAnalyzer: @unchecked Sendable {
    public static let bandCount = 15
    public static let silenceThresholdDB: Float = -80

    public var sampleRate: Double
    private let fftSize: Int
    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private var window: [Float]
    private let edges: [Double]

    private let lock = NSLock()
    private var ring: [Float]
    private var ringIndex = 0

    private var smoothed = [Float](repeating: 0, count: bandCount)
    private var ceiling: Float = -40

    public init(sampleRate: Double, fftSize: Int = 2048) {
        self.sampleRate = sampleRate
        self.fftSize = fftSize
        log2n = vDSP_Length(log2(Double(fftSize)))
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        edges = (0...Self.bandCount).map { 40 * pow(16000 / 40, Double($0) / Double(Self.bandCount)) }
        ring = [Float](repeating: 0, count: fftSize)
    }

    deinit {
        vDSP_destroy_fftsetup(setup)
    }

    public func append(_ samples: [Float]) {
        lock.withLock {
            for sample in samples {
                ring[ringIndex] = sample
                ringIndex = (ringIndex + 1) % fftSize
            }
        }
    }

    public func analyze() -> Spectrum {
        let samples = lock.withLock { Array(ring[ringIndex...] + ring[..<ringIndex]) }

        var meanSquare: Float = 0
        vDSP_measqv(samples, 1, &meanSquare, vDSP_Length(fftSize))
        let rmsDB = 10 * log10(meanSquare + 1e-12)

        var windowed = [Float](repeating: 0, count: fftSize)
        vDSP_vmul(samples, 1, window, 1, &windowed, 1, vDSP_Length(fftSize))
        var real = [Float](repeating: 0, count: fftSize / 2), imag = [Float](repeating: 0, count: fftSize / 2)
        var magnitudes = [Float](repeating: 0, count: fftSize / 2)
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                windowed.withUnsafeBufferPointer { wp in
                    wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: fftSize / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(fftSize / 2))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &magnitudes, 1, vDSP_Length(fftSize / 2))
            }
        }

        let binHz = sampleRate / Double(fftSize)
        let levels: [Float] = (0..<Self.bandCount).map { b in
            let lo = max(1, Int(edges[b] / binHz)), hi = min(magnitudes.count, max(lo + 1, Int(edges[b + 1] / binHz)))
            let energy = magnitudes[lo..<hi].reduce(0, +) / Float(hi - lo)
            return 10 * log10(energy + 1e-12)
        }
        ceiling = max(levels.max() ?? -40, ceiling - 0.15)
        for b in 0..<Self.bandCount {
            let raw = max(0, min(1, (levels[b] - (ceiling - 45)) / 45))
            smoothed[b] = raw > smoothed[b] ? raw : smoothed[b] * 0.85 + raw * 0.15
        }
        return Spectrum(levels: smoothed, rmsDB: rmsDB)
    }
}
```

- [ ] **Step 4: Run** `cd app && swift test --filter SpectrumAnalyzerTests` — Expected: 3 pass.
- [ ] **Step 5: Commit** `App: spectrum analyzer for the audio mode`

---

### Task 4: Equaliser palettes and renderer

**Files:** Create `app/Sources/DuckyCore/Equaliser.swift`, `app/Tests/DuckyCoreTests/EqualiserTests.swift`

**Interfaces:** Produces `enum EqualiserPalette: String, CaseIterable, Codable, Identifiable` (`classic, ocean, sunset, neon, fire`) with `name: String`, `rows: [RGB]` (top first); `enum EqualiserRenderer { static func frame(levels: [Float], palette: EqualiserPalette) -> [RGB] }`.

- [ ] **Step 1: Failing tests**

<!-- file: app/Tests/DuckyCoreTests/EqualiserTests.swift -->
```swift
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
```

- [ ] **Step 2: Run** `cd app && swift test --filter EqualiserTests` — Expected: compile failure.

- [ ] **Step 3: Implement**

<!-- file: app/Sources/DuckyCore/Equaliser.swift -->
```swift
/// Equaliser colour palettes validated on the keyboard: colours by bar height, top row first.
public enum EqualiserPalette: String, CaseIterable, Codable, Identifiable, Sendable {
    case classic, ocean, sunset, neon, fire

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .classic: return "Classique"
        case .ocean: return "Océan"
        case .sunset: return "Coucher de soleil"
        case .neon: return "Néon"
        case .fire: return "Feu"
        }
    }

    public var rows: [RGB] {
        switch self {
        case .classic: return [RGB(255, 0, 0), RGB(255, 120, 0), RGB(230, 230, 0), RGB(80, 255, 0), RGB(0, 255, 60)]
        case .ocean: return [RGB(240, 250, 255), RGB(120, 235, 255), RGB(0, 210, 255), RGB(0, 150, 255), RGB(0, 90, 255)]
        case .sunset: return [RGB(255, 235, 120), RGB(255, 150, 0), RGB(255, 60, 90), RGB(255, 0, 180), RGB(170, 0, 255)]
        case .neon: return [RGB(160, 255, 255), RGB(255, 120, 230), RGB(255, 0, 200), RGB(140, 0, 255), RGB(0, 110, 255)]
        case .fire: return [RGB(255, 250, 220), RGB(255, 230, 80), RGB(255, 180, 0), RGB(255, 110, 0), RGB(255, 40, 0)]
        }
    }
}

/// eq-smooth: one band per column (by the key's physical position), bar height = level x 5 rows, the top
/// LED lit partially, colour by row.
public enum EqualiserRenderer {
    public static func frame(levels: [Float], palette: EqualiserPalette) -> [RGB] {
        guard !levels.isEmpty else { return [RGB](repeating: .black, count: KeyboardLayout.ledCount) }
        let rows = palette.rows
        return KeyboardLayout.keys.map { key in
            let band = min(levels.count - 1, Int((key.x + key.width / 2) / KeyboardLayout.width * Double(levels.count)))
            let row = Int(key.y + key.height - 1)
            let fill = max(0, min(1, Double(levels[band]) * 5 - Double(4 - row)))
            return rows[row].scaled(by: UInt8((fill * 255).rounded()))
        }
    }
}
```

- [ ] **Step 4: Run** `cd app && swift test --filter EqualiserTests` — Expected: 4 pass. (Half fill: `0.5*5 - 2 = 0.5`, `0.5*255 = 127.5` rounds to 128.)
- [ ] **Step 5: Commit** `App: equaliser palettes and renderer`

---

### Task 5: Audio capture (system tap)

**Files:** Create `app/Sources/DuckyCore/AudioCapture.swift`; modify `app/Package.swift` (platform `.macOS("14.2")`).

**Interfaces:** Produces `protocol AudioCapture: AnyObject, Sendable { var onSamples: (@Sendable ([Float]) -> Void)? {get set}; var sampleRate: Double {get}; func start() throws; func stop() }`, `enum AudioCaptureError: Error { case coreAudio(String, OSStatus) }`, `final class SystemAudioTap: AudioCapture`.

- [ ] **Step 1: Implement** (hardware-only; verified in Task 7)

<!-- file: app/Sources/DuckyCore/AudioCapture.swift -->
```swift
import AudioToolbox
import CoreAudio
import Foundation

/// A source of mono audio samples.
public protocol AudioCapture: AnyObject, Sendable {
    /// Called on a background queue with mono samples.
    var onSamples: (@Sendable ([Float]) -> Void)? { get set }
    var sampleRate: Double { get }
    func start() throws
    func stop()
}

public enum AudioCaptureError: Error, Equatable {
    case coreAudio(String, OSStatus)
}

/// Captures what the Mac plays (headphones included) with a Core Audio process tap, and restarts on the
/// new output when the default output device changes. Needs NSAudioCaptureUsageDescription.
public final class SystemAudioTap: AudioCapture, @unchecked Sendable {
    public var onSamples: (@Sendable ([Float]) -> Void)?
    public private(set) var sampleRate: Double = 48000

    private let control = DispatchQueue(label: "ducky-rgb.audio.control")
    private let io = DispatchQueue(label: "ducky-rgb.audio.io")
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var outputListener: AudioObjectPropertyListenerBlock?
    private var outputAddress = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
                                                          mScope: kAudioObjectPropertyScopeGlobal,
                                                          mElement: kAudioObjectPropertyElementMain)

    public init() {}

    public func start() throws {
        try control.sync {
            try startTap()
            let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                guard let self else { return }
                self.stopTap()
                try? self.startTap()
            }
            outputListener = listener
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &outputAddress, control, listener)
        }
    }

    public func stop() {
        control.sync {
            if let listener = outputListener {
                AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &outputAddress, control, listener)
                outputListener = nil
            }
            stopTap()
        }
    }

    private func check(_ status: OSStatus, _ what: String) throws {
        if status != noErr { throw AudioCaptureError.coreAudio(what, status) }
    }

    private func defaultOutputUID() throws -> String {
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &outputAddress, 0, nil, &size, &deviceID), "default output")
        var uidAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
                                                    mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var uid: CFString = "" as CFString
        size = UInt32(MemoryLayout<CFString>.size)
        try check(withUnsafeMutablePointer(to: &uid) { AudioObjectGetPropertyData(deviceID, &uidAddress, 0, nil, &size, $0) }, "output uid")
        return uid as String
    }

    private func startTap() throws {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.muteBehavior = .unmuted
        description.isPrivate = true
        try check(AudioHardwareCreateProcessTap(description, &tapID), "create tap")

        let outputUID = try defaultOutputUID()
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Ducky RGB audio",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID), "create aggregate device")

        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var formatAddress = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                                                       mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        try check(AudioObjectGetPropertyData(tapID, &formatAddress, 0, nil, &size, &format), "tap format")
        sampleRate = format.mSampleRate

        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, io) { [weak self] _, input, _, _, _ in
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            guard let self, let first = buffers.first, let data = first.mData else { return }
            let channels = max(Int(first.mNumberChannels), 1)
            let frames = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * channels)
            let samples = data.assumingMemoryBound(to: Float.self)
            var mono = [Float](repeating: 0, count: frames)
            for f in 0..<frames {
                var sum: Float = 0
                for c in 0..<channels { sum += samples[f * channels + c] }
                mono[f] = sum / Float(channels)
            }
            self.onSamples?(mono)
        }, "io proc")
        try check(AudioDeviceStart(aggregateID, procID), "start capture")
    }

    private func stopTap() {
        if let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
            self.procID = nil
        }
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }
}
```

In `Package.swift`, replace `platforms: [.macOS(.v14)]` with `platforms: [.macOS("14.2")]`.

- [ ] **Step 2: Build** `cd app && swift build && swift test` — Expected: build complete, all tests pass.
- [ ] **Step 3: Commit** `App: system audio capture through a Core Audio process tap`

---

### Task 6: AudioMode

**Files:** Create `app/Sources/DuckyCore/AudioMode.swift`, `app/Tests/DuckyCoreTests/AudioModeTests.swift`

**Interfaces:** Consumes Tasks 2-5. Produces `@MainActor @Observable final class AudioMode(controller:makeCapture:defaults:silenceDelay:autoTick:)` with `status: Status` (`.off, .listening, .playing, .paused, .failed(String)`), `isArmed`, `isPaused`, `palette`, `restore()`, `setArmed(_:)`, `setPaused(_:)`, `suspendForQuit()`, internal `tick(now:)`.

- [ ] **Step 1: Failing tests**

<!-- file: app/Tests/DuckyCoreTests/AudioModeTests.swift -->
```swift
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
```

- [ ] **Step 2: Run** `cd app && swift test --filter AudioModeTests` — Expected: compile failure.

- [ ] **Step 3: Implement**

<!-- file: app/Sources/DuckyCore/AudioMode.swift -->
```swift
import Foundation
import Observation

/// Audio mode: while armed and the Mac plays sound, the keyboard shows the equaliser as live frames;
/// after `silenceDelay` seconds of silence (or while paused) it shows the saved lighting again.
@MainActor
@Observable
public final class AudioMode {
    public enum Status: Equatable, Sendable {
        case off
        case listening // armed, silent: the saved lighting is shown
        case playing
        case paused // the editor is being used
        case failed(String)
    }

    private enum Keys {
        static let armed = "audioMode.armed"
        static let palette = "audioMode.palette"
    }

    public private(set) var status: Status = .off
    public private(set) var isArmed = false
    public private(set) var isPaused = false
    public var palette: EqualiserPalette {
        didSet { defaults.set(palette.rawValue, forKey: Keys.palette) }
    }

    private let controller: LightingController
    private let makeCapture: () -> AudioCapture
    private let defaults: UserDefaults
    private let silenceDelay: TimeInterval
    private let autoTick: Bool
    private var capture: AudioCapture?
    private var analyzer: SpectrumAnalyzer?
    private var silentSince: Date?
    private var loop: Task<Void, Never>?

    public init(controller: LightingController, makeCapture: @escaping () -> AudioCapture, defaults: UserDefaults = .standard,
                silenceDelay: TimeInterval = 3, autoTick: Bool = true) {
        self.controller = controller
        self.makeCapture = makeCapture
        self.defaults = defaults
        self.silenceDelay = silenceDelay
        self.autoTick = autoTick
        palette = defaults.string(forKey: Keys.palette).flatMap(EqualiserPalette.init(rawValue:)) ?? .ocean
    }

    /// Re-arms the mode if it was armed when the app last quit.
    public func restore() {
        if defaults.bool(forKey: Keys.armed) { arm() }
    }

    public func setArmed(_ armed: Bool) {
        guard armed != isArmed else { return }
        defaults.set(armed, forKey: Keys.armed)
        if armed { arm() } else { disarm() }
    }

    public func setPaused(_ paused: Bool) {
        isPaused = paused
        guard isArmed else { return }
        if paused {
            controller.endLiveFrames()
            status = .paused
        } else if status == .paused {
            status = .listening
        }
    }

    /// Hands the LEDs back before quitting, keeping the armed state for the next launch.
    public func suspendForQuit() {
        stopCapture()
        controller.endLiveFrames()
    }

    private func arm() {
        let capture = makeCapture()
        let analyzer = SpectrumAnalyzer(sampleRate: capture.sampleRate)
        capture.onSamples = { samples in analyzer.append(samples) }
        do {
            try capture.start()
        } catch {
            capture.onSamples = nil
            isArmed = false
            defaults.set(false, forKey: Keys.armed)
            status = .failed(Self.describe(error))
            return
        }
        analyzer.sampleRate = capture.sampleRate
        self.capture = capture
        self.analyzer = analyzer
        isArmed = true
        silentSince = nil
        status = isPaused ? .paused : .listening
        if autoTick {
            loop = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    self?.tick()
                    try? await Task.sleep(nanoseconds: 33_000_000)
                }
            }
        }
    }

    private func disarm() {
        stopCapture()
        controller.endLiveFrames()
        isArmed = false
        status = .off
    }

    private func stopCapture() {
        loop?.cancel()
        loop = nil
        capture?.stop()
        capture?.onSamples = nil
        capture = nil
        analyzer = nil
        silentSince = nil
    }

    /// One step: analyse the latest audio, then show an equaliser frame or the saved lighting.
    func tick(now: Date = Date()) {
        guard isArmed, let capture, let analyzer else { return }
        analyzer.sampleRate = capture.sampleRate // follows an output device change
        let spectrum = analyzer.analyze()
        if isPaused {
            status = .paused
            return
        }
        if spectrum.rmsDB < SpectrumAnalyzer.silenceThresholdDB {
            let since = silentSince ?? now
            silentSince = since
            if now.timeIntervalSince(since) >= silenceDelay {
                controller.endLiveFrames()
                status = .listening
                return
            }
            if status != .playing { return } // still resting: stay on the saved lighting
        } else {
            silentSince = nil
            status = .playing
        }
        controller.showLiveFrame(EqualiserRenderer.frame(levels: spectrum.levels, palette: palette))
    }

    private static func describe(_ error: Error) -> String {
        if case AudioCaptureError.coreAudio(let what, let status) = error {
            return "capture audio impossible (\(what), code \(status)). Vérifie l'autorisation dans Réglages Système > Confidentialité."
        }
        return error.localizedDescription
    }
}
```

- [ ] **Step 4: Run** `cd app && swift test` — Expected: all pass.
- [ ] **Step 5: Commit** `App: audio mode (armed, silence, pause, palette)`

---

### Task 7: App integration and hardware check

**Files:** Modify `app/Sources/DuckyRGB/DuckyRGBApp.swift`, `app/Sources/DuckyRGB/MenuContent.swift`, `app/Sources/DuckyRGB/EditorView.swift`, `app/scripts/bundle.sh`; create `app/Sources/DuckyRGB/AudioModeSection.swift`.

- [ ] **Step 1: Model, launch and quit** (`DuckyRGBApp.swift`)

In `AppModel`, add `let audio: AudioMode` initialised in `init()`:

```swift
    let audio: AudioMode

    init() {
        audio = AudioMode(controller: controller, makeCapture: { SystemAudioTap() })
    }
```

(`controller` and `presets` stay stored `let` properties initialised inline; declare `init()` after them.)

In `applicationDidFinishLaunching`, after `AppModel.shared.controller.start()`: `AppModel.shared.audio.restore()`.

In `applicationShouldTerminate`, replace `AppModel.shared.controller.flushPendingSave { reply() }` with:

```swift
            AppModel.shared.audio.suspendForQuit()
            AppModel.shared.controller.flushPendingSave { reply() }
```

Inject `.environment(model.audio)` next to the two existing `.environment(model.presets)` calls.

- [ ] **Step 2: Menu section**

<!-- file: app/Sources/DuckyRGB/AudioModeSection.swift -->
```swift
import DuckyCore
import SwiftUI

/// Audio mode switch, palette and status, for the menu bar extra.
struct AudioModeSection: View {
    @Environment(AudioMode.self) private var audio

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Mode audio", isOn: Binding(get: { audio.isArmed }, set: { audio.setArmed($0) }))
            Picker("Palette", selection: Binding(get: { audio.palette }, set: { audio.palette = $0 })) {
                ForEach(EqualiserPalette.allCases) { palette in
                    Text(palette.name).tag(palette)
                }
            }
            Text(statusText)
                .font(.caption)
                .foregroundStyle(statusColor)
        }
    }

    private var statusText: String {
        switch audio.status {
        case .off: return "Désactivé"
        case .listening: return "En écoute · éclairage de repos"
        case .playing: return "Égaliseur actif"
        case .paused: return "En pause pendant l'édition"
        case .failed(let message): return "Échec : \(message)"
        }
    }

    private var statusColor: Color {
        if case .failed = audio.status { return .red }
        return .secondary
    }
}
```

In `MenuContent.swift`, after `BaseControls(showsColor: false)` add:

```swift
            Divider()
            AudioModeSection()
```

- [ ] **Step 3: Pause while the editor is the key window** (`EditorView.swift`)

Add `@Environment(AudioMode.self) private var audio` and `@Environment(\.controlActiveState) private var activeState`, and on the outer `ScrollView` add:

```swift
        .onChange(of: activeState, initial: true) { _, state in audio.setPaused(state == .key) }
        .onDisappear { audio.setPaused(false) }
```

- [ ] **Step 4: Bundle Info.plist** (`app/scripts/bundle.sh`): set `LSMinimumSystemVersion` to `14.2` and add
`<key>NSAudioCaptureUsageDescription</key><string>Ducky RGB lit le son du système pour animer le clavier au rythme de la musique.</string>`.

- [ ] **Step 5: Build, test, bundle** `cd app && swift build && swift test && scripts/bundle.sh` — Expected: build complete, all tests pass, bundle signed.

- [ ] **Step 6: Hardware check (user):** arm in the menu (grant audio permission), play music on headphones -> equaliser; pause the music -> saved lighting after 3 s; open the editor -> saved lighting; leave it -> equaliser; change palette; quit -> saved lighting.

- [ ] **Step 7: Commit and push** `App: audio mode in the menu (equaliser, palettes, silence, editor pause)`; update `README.md` (app section: audio mode, macOS 14.2) and `CLAUDE.local.md`.
