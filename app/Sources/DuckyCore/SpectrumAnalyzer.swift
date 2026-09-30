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
