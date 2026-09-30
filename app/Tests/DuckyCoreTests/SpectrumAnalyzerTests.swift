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
