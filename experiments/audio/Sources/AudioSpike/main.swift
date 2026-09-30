// EXPERIMENT: system audio (Core Audio process tap, macOS 14.2+) driving the Ducky in real time.
// Usage (as an app bundle, for the audio capture permission): open DuckyAudio.app --args <style>
// Styles: eq (default), eq-smooth, eq-peaks, eq-rainbow, eq-mirror, rings, pulse, colors, waves. Ctrl-C / SIGTERM hands the LEDs back to the effect.
import Accelerate
import AudioToolbox
import CoreAudio
import DuckyCore
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)
let positional = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
let style = positional.first ?? "eq"
let paletteName = positional.dropFirst().first ?? "classic"

func check(_ status: OSStatus, _ what: String) {
    if status != noErr {
        print("\(what) failed: \(status)")
        exit(1)
    }
}

func defaultOutputUID() -> String {
    var deviceID = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
                                             mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID), "default output")
    var uid: CFString = "" as CFString
    size = UInt32(MemoryLayout<CFString>.size)
    address.mSelector = kAudioDevicePropertyDeviceUID
    check(withUnsafeMutablePointer(to: &uid) { AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, $0) }, "device uid")
    return uid as String
}

// MARK: - Audio tap

let tapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
tapDescription.uuid = UUID()
tapDescription.muteBehavior = .unmuted
tapDescription.isPrivate = true
var tapID = AudioObjectID(kAudioObjectUnknown)
check(AudioHardwareCreateProcessTap(tapDescription, &tapID), "create tap")

let outputUID = defaultOutputUID()
let aggregate: [String: Any] = [
    kAudioAggregateDeviceNameKey: "DuckyAudio",
    kAudioAggregateDeviceUIDKey: UUID().uuidString,
    kAudioAggregateDeviceMainSubDeviceKey: outputUID,
    kAudioAggregateDeviceIsPrivateKey: true,
    kAudioAggregateDeviceIsStackedKey: false,
    kAudioAggregateDeviceTapAutoStartKey: true,
    kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
    kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: tapDescription.uuid.uuidString]],
]
var aggregateID = AudioObjectID(kAudioObjectUnknown)
check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID), "create aggregate")

var format = AudioStreamBasicDescription()
var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
var formatAddress = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
check(AudioObjectGetPropertyData(tapID, &formatAddress, 0, nil, &formatSize, &format), "tap format")
let sampleRate = format.mSampleRate
print("style \(style) · palette \(paletteName) · tap \(sampleRate) Hz, \(format.mChannelsPerFrame) ch, output \(outputUID)")

let fftSize = 2048
let lock = NSLock()
var ring = [Float](repeating: 0, count: fftSize)
var ringIndex = 0

let audioQueue = DispatchQueue(label: "ducky-audio.capture")
var procID: AudioDeviceIOProcID?
check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, audioQueue) { _, input, _, _, _ in
    let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
    guard let first = buffers.first, let data = first.mData else { return }
    let channels = max(Int(first.mNumberChannels), 1)
    let frames = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * channels)
    let samples = data.assumingMemoryBound(to: Float.self)
    lock.lock()
    for f in 0..<frames {
        var mono: Float = 0
        for c in 0..<channels { mono += samples[f * channels + c] }
        ring[ringIndex] = mono / Float(channels)
        ringIndex = (ringIndex + 1) % fftSize
    }
    lock.unlock()
}, "io proc")
check(AudioDeviceStart(aggregateID, procID), "start")

// MARK: - Analysis: 15 log-spaced bands (40 Hz - 16 kHz), auto gain, smoothing, bass beats

let log2n = vDSP_Length(log2(Double(fftSize)))
let fft = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
var window = [Float](repeating: 0, count: fftSize)
vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
let bands = 15
let edges: [Double] = (0...bands).map { 40 * pow(16000 / 40, Double($0) / Double(bands)) }

/// Band levels in dB and the raw 40-150 Hz energy used for kick detection.
func bandLevels() -> (levels: [Float], bassEnergy: Float) {
    lock.lock()
    let samples = Array(ring[ringIndex...] + ring[..<ringIndex])
    lock.unlock()
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
            vDSP_fft_zrip(fft, &split, 1, log2n, FFTDirection(FFT_FORWARD))
            vDSP_zvmags(&split, 1, &magnitudes, 1, vDSP_Length(fftSize / 2))
        }
    }
    let binHz = sampleRate / Double(fftSize)
    let levels: [Float] = (0..<bands).map { b in
        let lo = max(1, Int(edges[b] / binHz)), hi = max(lo + 1, Int(edges[b + 1] / binHz))
        let energy = magnitudes[lo..<min(hi, magnitudes.count)].reduce(0, +) / Float(hi - lo)
        return 10 * log10(energy + 1e-12)
    }
    let bassEnergy = magnitudes[max(1, Int(40 / binHz))...Int(150 / binHz)].reduce(0, +)
    return (levels, bassEnergy)
}

struct Analysis {
    var smoothed = [Float](repeating: 0, count: bands) // 0...1 per band
    var ceiling: Float = -40
    var bassAverage: Float = 0
    var lastBeat = Date.distantPast
    var beat = false
    var kick = false
    var lastKick = Date.distantPast
    var recentBass: [Float] = []

    mutating func update() {
        let (levels, bassEnergy) = bandLevels()
        // Kick detection without any running average: a kick is the 40-150 Hz energy rising more than
        // 4.5 dB above its lowest level of the previous ~140 ms (the dip before the kick). In dB this
        // ignores the track's loudness, so a steady techno kick keeps triggering. One kick per 0.2 s.
        let bassDB = 10 * log10(bassEnergy + 1e-12)
        let valley = recentBass.min() ?? bassDB
        recentBass.append(bassDB)
        if recentBass.count > 4 { recentBass.removeFirst() }
        let loudEnough = bassDB > ceiling - 30
        kick = bassDB - valley > 4.5 && loudEnough && Date().timeIntervalSince(lastKick) > 0.2
        if kick {
            lastKick = Date()
            recentBass = [bassDB] // the next kick must rise from a new dip
        }
        ceiling = max(levels.max() ?? -40, ceiling - 0.15)
        var raw = [Float](repeating: 0, count: bands)
        for b in 0..<bands {
            raw[b] = max(0, min(1, (levels[b] - (ceiling - 45)) / 45))
            smoothed[b] = raw[b] > smoothed[b] ? raw[b] : smoothed[b] * 0.85 + raw[b] * 0.15
        }
        let bass = (raw[0] + raw[1] + raw[2]) / 3
        beat = bass > bassAverage + 0.12 && bass > 0.35 && Date().timeIntervalSince(lastBeat) > 0.18
        if beat { lastBeat = Date() }
        bassAverage = bassAverage * 0.95 + bass * 0.05
    }

    func mean(_ range: ClosedRange<Int>) -> Float {
        range.map { smoothed[$0] }.reduce(0, +) / Float(range.count)
    }
}

// MARK: - Styles

let keys = KeyboardLayout.keys

func hsv(_ hueDegrees: Double, _ saturation: Double, _ value: Double) -> RGB {
    let h = hueDegrees.truncatingRemainder(dividingBy: 360) / 360
    func byte(_ x: Double) -> UInt8 { UInt8(max(0, min(255, (x * 255).rounded()))) }
    return RGB(hue: byte(h < 0 ? h + 1 : h), saturation: byte(saturation), value: byte(value))
}

func band(of key: KeyInfo) -> Int {
    min(bands - 1, Int((key.x + key.width / 2) / KeyboardLayout.width * Double(bands)))
}

/// Classic equaliser: one band per column, green at the bottom to red at the top.
func equaliser(_ a: Analysis) -> [RGB] {
    let rowColors = [RGB(255, 0, 0), RGB(255, 120, 0), RGB(230, 230, 0), RGB(80, 255, 0), RGB(0, 255, 60)]
    return keys.map { key in
        let row = Int(key.y + key.height - 1)
        let height = Int((a.smoothed[band(of: key)] * 5).rounded())
        return (4 - row) < height ? rowColors[row] : .black
    }
}

struct EqualiserOptions {
    var smooth = false  // the top LED of a bar lights partially instead of jumping row to row
    var peaks = false   // a white dot holds each bar's peak, then falls slowly
    var rainbow = false // one colour per column (bass to treble) instead of green-yellow-red rows
    var mirror = false  // bass in the middle, treble towards both edges
    var rowColors = palettes["classic"]! // top row first
}

/// Colours by bar height, top row first (row 0 = top, row 4 = bottom). Kept after comparing on the keyboard;
/// bottoms start one step bright and tops end on a clear highlight (darker bottoms read as a dim keyboard).
let palettes: [String: [RGB]] = [
    "classic": [RGB(255, 0, 0), RGB(255, 120, 0), RGB(230, 230, 0), RGB(80, 255, 0), RGB(0, 255, 60)],
    "ocean": [RGB(240, 250, 255), RGB(120, 235, 255), RGB(0, 210, 255), RGB(0, 150, 255), RGB(0, 90, 255)],
    "sunset": [RGB(255, 235, 120), RGB(255, 150, 0), RGB(255, 60, 90), RGB(255, 0, 180), RGB(170, 0, 255)],
    "neon": [RGB(160, 255, 255), RGB(255, 120, 230), RGB(255, 0, 200), RGB(140, 0, 255), RGB(0, 110, 255)],
    "fire": [RGB(255, 250, 220), RGB(255, 230, 80), RGB(255, 180, 0), RGB(255, 110, 0), RGB(255, 40, 0)],
]

var peakLevels = [Double](repeating: 0, count: bands) // in rows, 0...5
var peakHold = [Int](repeating: 0, count: bands)

func equaliser(_ a: Analysis, _ options: EqualiserOptions) -> [RGB] {
    for b in 0..<bands {
        let height = Double(a.smoothed[b]) * 5
        if height >= peakLevels[b] {
            peakLevels[b] = height
            peakHold[b] = 12
        } else if peakHold[b] > 0 {
            peakHold[b] -= 1
        } else {
            peakLevels[b] = max(0, peakLevels[b] - 0.08)
        }
    }
    let rowColors = options.rowColors
    return keys.map { key in
        var b = band(of: key)
        if options.mirror { b = min(bands - 1, abs(b - 7) * 2) }
        let row = Int(key.y + key.height - 1)
        let level = Double(4 - row) // 0 at the bottom row, 4 at the top
        let height = Double(a.smoothed[b]) * 5
        let fill = options.smooth ? max(0, min(1, height - level)) : (level < height.rounded() ? 1 : 0)
        let colour = options.rainbow ? hsv(Double(b) / Double(bands) * 300, 1, 1) : rowColors[row]
        if options.peaks, fill < 0.3, peakLevels[b] > 0.5, Int(level) == min(4, Int(peakLevels[b])) {
            return RGB(200, 200, 200)
        }
        return colour.scaled(by: UInt8(fill * 255))
    }
}

var flash: Double = 0
/// Whole keyboard breathes with the loudness; each bass beat flashes towards white; hue drifts.
func pulse(_ a: Analysis, time: Double) -> [RGB] {
    if a.beat { flash = 1 }
    let loudness = Double(a.mean(0...14))
    let color = hsv(time * 20, 1 - 0.7 * flash, min(1, 0.12 + 0.7 * loudness + 0.35 * flash))
    flash *= 0.85
    return keys.map { _ in color }
}

/// Bass in red, mids in green, treble in blue, with each column tinted by its own band.
func colors(_ a: Analysis) -> [RGB] {
    let bass = Double(a.mean(0...3)), mid = Double(a.mean(4...9)), treble = Double(a.mean(10...14))
    return keys.map { key in
        let local = 0.5 + 0.5 * Double(a.smoothed[band(of: key)])
        func c(_ x: Double) -> UInt8 { UInt8(max(0, min(255, x * local * 255))) }
        return RGB(c(bass), c(mid), c(treble))
    }
}

/// Rings only: each kick sends a ring from the centre; black background; ring hue rotates over time.
var rings: [Wave] = []
func ringsOnly(_ a: Analysis, time: Double) -> [RGB] {
    if a.kick { rings.append(Wave(radius: 0, hue: time * 25)) }
    rings = rings.map { Wave(radius: $0.radius + 0.3, hue: $0.hue) }.filter { $0.radius < 11 }
    let centre = (x: KeyboardLayout.width / 2, y: 2.5)
    return keys.map { key in
        let dx = key.x + key.width / 2 - centre.x, dy = (key.y + key.height / 2 - centre.y) * 1.3
        let distance = (dx * dx + dy * dy).squareRoot()
        var color = RGB.black
        var brightest = 0.0
        for ring in rings {
            let level = exp(-pow(distance - ring.radius, 2) / 0.5) * pow(1 - ring.radius / 11, 1.5)
            if level > brightest {
                brightest = level
                color = hsv(ring.hue, 1, min(1, level))
            }
        }
        return color
    }
}

struct Wave { var radius: Double; var hue: Double }
var waves: [Wave] = []
/// Each bass beat sends a ring from the centre of the keyboard; the rest glows with the loudness.
func ripples(_ a: Analysis, time: Double) -> [RGB] {
    if a.beat { waves.append(Wave(radius: 0, hue: time * 25)) }
    waves = waves.map { Wave(radius: $0.radius + 0.35, hue: $0.hue) }.filter { $0.radius < 11 }
    let loudness = Double(a.mean(0...14))
    let centre = (x: KeyboardLayout.width / 2, y: 2.5)
    return keys.map { key in
        let dx = key.x + key.width / 2 - centre.x, dy = (key.y + key.height / 2 - centre.y) * 1.3
        let distance = (dx * dx + dy * dy).squareRoot()
        var best = hsv(time * 25 + 180, 1, 0.08 + 0.25 * loudness)
        var bestLevel = 0.0
        for wave in waves {
            let level = exp(-pow(distance - wave.radius, 2) / 0.6) * (1 - wave.radius / 11)
            if level > bestLevel {
                bestLevel = level
                best = hsv(wave.hue, 1, min(1, level))
            }
        }
        return best
    }
}

// MARK: - Keyboard loop

let transport = IOKitHIDTransport()
transport.start()
let client = KeyboardClient(transport: transport)

func send(_ frame: [RGB]) throws {
    for first in stride(from: 0, to: frame.count, by: 9) {
        let chunk = frame[first..<min(first + 9, frame.count)]
        let report = DuckyProtocol.request(.hostSet, [UInt8(first), UInt8(chunk.count)] + chunk.flatMap { [$0.r, $0.g, $0.b] })
        _ = try DuckyProtocol.payload(of: try transport.exchange(report, timeout: 1), for: .hostSet)
    }
}

// Hand the LEDs back on Ctrl-C / SIGTERM (handled off the main thread: exchange blocks).
var signalSources: [DispatchSourceSignal] = []
for sig in [SIGINT, SIGTERM] {
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
    source.setEventHandler {
        try? client.setHostMode(false)
        print("LEDs handed back to the keyboard effect")
        exit(0)
    }
    source.resume()
    signalSources.append(source)
}

DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
    do {
        try client.setHostMode(true)
        var analysis = Analysis()
        var frames = 0
        let start = Date()
        while true {
            analysis.update()
            let time = Date().timeIntervalSince(start)
            let frame: [RGB]
            switch style {
            case "eq-smooth": frame = equaliser(analysis, EqualiserOptions(smooth: true, rowColors: palettes[paletteName] ?? palettes["classic"]!))
            case "eq-peaks": frame = equaliser(analysis, EqualiserOptions(smooth: true, peaks: true))
            case "eq-rainbow": frame = equaliser(analysis, EqualiserOptions(smooth: true, rainbow: true))
            case "eq-mirror": frame = equaliser(analysis, EqualiserOptions(smooth: true, mirror: true))
            case "rings": frame = ringsOnly(analysis, time: time)
            case "pulse": frame = pulse(analysis, time: time)
            case "colors": frame = colors(analysis)
            case "waves": frame = ripples(analysis, time: time)
            default: frame = equaliser(analysis)
            }
            try send(frame)
            frames += 1
            if frames % 400 == 0 {
                print(String(format: "%.0f fps", Double(frames) / time))
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
    } catch {
        print("keyboard error:", error)
        exit(1)
    }
}
RunLoop.main.run()
