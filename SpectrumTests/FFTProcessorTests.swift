import XCTest
@testable import Spectrum

final class FFTProcessorTests: XCTestCase {
    func testOneKilohertzPeakAt48k() {
        assertPeak(frequency: 1_000, sampleRate: 48_000, fftSize: 16_384, toleranceBins: 2)
    }

    func testOneHundredHertzPeak() {
        assertPeak(frequency: 100, sampleRate: 48_000, fftSize: 16_384, toleranceBins: 2)
    }

    func testTenKilohertzPeak() {
        assertPeak(frequency: 10_000, sampleRate: 48_000, fftSize: 16_384, toleranceBins: 2)
    }

    func testSampleRates() {
        for sampleRate in [44_100.0, 48_000.0, 96_000.0] {
            assertPeak(frequency: 1_000, sampleRate: sampleRate, fftSize: 16_384, toleranceBins: 2)
        }
    }

    func testFFTSizes() {
        for size in [2_048, 4_096, 8_192, 16_384, 32_768] {
            assertPeak(frequency: 1_000, sampleRate: 48_000, fftSize: size, toleranceBins: 3)
        }
    }

    func testFullScaleSineIsNearZeroDBFS() {
        let sampleRate = 48_000.0
        let fftSize = 16_384
        let bin = 341
        let frequency = Double(bin) * sampleRate / Double(fftSize)
        let samples = SignalGenerator.sine(
            frequency: frequency,
            sampleRate: sampleRate,
            count: fftSize,
            amplitude: 1.0
        )
        let fft = FFTProcessor(size: fftSize, window: .hann)
        let magnitudes = fft.process(samples: samples)
        let peak = magnitudes.dropFirst().max() ?? 0
        let db = DecibelCalculator.amplitudeToDB(peak, floorDB: -200)
        XCTAssertEqual(db, 0, accuracy: 1.5, "0 dBFS sine should land near 0 dBFS, got \(db)")
    }

    func testConstantOffsetDoesNotLeakIntoAudibleBins() {
        let samples = [Float](repeating: 0.5, count: 8_192)
        let fft = FFTProcessor(size: 8_192, window: .hann)
        let magnitudes = fft.process(samples: samples)
        let audible = magnitudes.dropFirst().max() ?? 1
        XCTAssertLessThan(audible, 0.02, "DC leakage into audible bins was \(audible)")
    }

    func testMultiToneHasThreePeaks() {
        let sampleRate = 48_000.0
        let fftSize = 16_384
        let tones = [100.0, 1_000.0, 10_000.0]
        let samples = SignalGenerator.multiTone(
            frequencies: tones,
            sampleRate: sampleRate,
            count: fftSize,
            amplitude: 0.3
        )
        let fft = FFTProcessor(size: fftSize, window: .hann)
        let magnitudes = fft.process(samples: samples)
        let mapper = FrequencyMapper(
            sampleRate: sampleRate,
            fftSize: fftSize,
            barCount: 256,
            minimumFrequency: 10,
            maximumFrequency: 24_000,
            aggregation: .peak
        )
        let bands = mapper.map(magnitudes: magnitudes)

        for tone in tones {
            let nearby = zip(mapper.bands, bands)
                .filter { band, _ in
                    tone >= Double(band.lowerFrequency) * 0.7 && tone <= Double(band.upperFrequency) * 1.4
                }
                .map(\.1)
            let localPeak = nearby.max() ?? 0
            XCTAssertGreaterThan(localPeak, 0.05, "Expected a peak near \(tone) Hz")
        }
    }

    private func assertPeak(frequency: Double, sampleRate: Double, fftSize: Int, toleranceBins: Int, file: StaticString = #filePath, line: UInt = #line) {
        let samples = SignalGenerator.sine(
            frequency: frequency,
            sampleRate: sampleRate,
            count: fftSize,
            amplitude: 0.9
        )
        let fft = FFTProcessor(size: fftSize, window: .hann)
        let magnitudes = fft.process(samples: samples)
        let peakFrequency = fft.peakFrequency(magnitudes: magnitudes, sampleRate: sampleRate)
        let binHz = Float(sampleRate) / Float(fftSize)
        let tolerance = binHz * Float(toleranceBins)
        XCTAssertEqual(
            peakFrequency,
            Float(frequency),
            accuracy: tolerance,
            "Peak \(peakFrequency) Hz not within \(tolerance) Hz of \(frequency)",
            file: file,
            line: line
        )
    }
}
