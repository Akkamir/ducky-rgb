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
        defaults.set(armed, forKey: Keys.armed)
        if armed {
            if !isArmed { arm() }
        } else {
            disarm() // also clears a failure
        }
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
        capture.onFailure = { [weak self] error in
            Task { @MainActor in self?.captureFailed(error) }
        }
        do {
            try capture.start()
        } catch {
            // The stored choice is kept: a transient failure at login does not disarm for good.
            capture.stop()
            capture.onSamples = nil
            capture.onFailure = nil
            captureFailed(error)
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

    private func captureFailed(_ error: Error) {
        stopCapture()
        controller.endLiveFrames()
        isArmed = false
        status = .failed(Self.describe(error))
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
        capture?.onFailure = nil
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
        guard controller.canControl else {
            status = .listening // nothing to light yet: the keyboard is absent
            silentSince = nil
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
