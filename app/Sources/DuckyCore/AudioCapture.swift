import AudioToolbox
import CoreAudio
import Foundation

/// A source of mono audio samples.
public protocol AudioCapture: AnyObject, Sendable {
    /// Called on a background queue with mono samples.
    var onSamples: (@Sendable ([Float]) -> Void)? { get set }
    /// Called on a background queue when capture stops after a successful start.
    var onFailure: (@Sendable (Error) -> Void)? { get set }
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
    public var onFailure: (@Sendable (Error) -> Void)?
    public var sampleRate: Double { lock.withLock { currentSampleRate } }

    private let lock = NSLock()
    private var currentSampleRate: Double = 48000
    private var isRunning = false // guarded by `control`
    private let control = DispatchQueue(label: "ducky-rgb.audio.control")
    private let io = DispatchQueue(label: "ducky-rgb.audio.io")
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var outputListener: AudioObjectPropertyListenerBlock?
    private var outputAddress = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                          mScope: kAudioObjectPropertyScopeGlobal,
                                                          mElement: kAudioObjectPropertyElementMain)

    public init() {}

    deinit {
        // No `control.sync` here: the last reference may be released on `control`.
        removeOutputListener()
        stopTap()
    }

    public func start() throws {
        try control.sync {
            guard !isRunning else { return }
            try startTap()
            isRunning = true
            let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                guard let self, self.isRunning else { return } // a change queued before stop()
                self.stopTap()
                self.restart(attempt: 1)
            }
            outputListener = listener
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &outputAddress, control, listener)
        }
    }

    public func stop() {
        control.sync {
            isRunning = false
            removeOutputListener()
            stopTap()
        }
    }

    /// Restarts on the new output; the device may not be ready yet (Bluetooth), so retries a few times.
    private func restart(attempt: Int) {
        do {
            try startTap()
        } catch {
            guard attempt < 5 else {
                isRunning = false
                removeOutputListener()
                onFailure?(error)
                return
            }
            control.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, self.isRunning else { return }
                self.restart(attempt: attempt + 1)
            }
        }
    }

    private func removeOutputListener() {
        if let listener = outputListener {
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &outputAddress, control, listener)
            outputListener = nil
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

    /// Creates the tap, the aggregate device and the IO proc; on failure, releases what was created.
    private func startTap() throws {
        do {
            try createTap()
        } catch {
            stopTap()
            throw error
        }
    }

    private func createTap() throws {
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
        lock.withLock { currentSampleRate = format.mSampleRate }

        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, io) { [weak self] _, input, _, _, _ in
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            // The tap's stream comes after the output device's own input streams, if it has any.
            guard let self, let stream = buffers.last, let data = stream.mData else { return }
            let channels = max(Int(stream.mNumberChannels), 1)
            let frames = Int(stream.mDataByteSize) / (MemoryLayout<Float>.size * channels)
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
