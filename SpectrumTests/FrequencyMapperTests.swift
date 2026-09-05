import XCTest
@testable import Spectrum

final class FrequencyMapperTests: XCTestCase {
    func testLogarithmicBandCentersIncrease() {
        let mapper = FrequencyMapper(
            sampleRate: 48_000,
            fftSize: 16_384,
            barCount: 128,
            minimumFrequency: 10,
            maximumFrequency: 20_000
        )
        let centers = mapper.centerFrequencies()
        XCTAssertEqual(centers.count, 128)
        for index in 1..<centers.count {
            XCTAssertGreaterThan(centers[index], centers[index - 1])
        }
        XCTAssertEqual(centers.first ?? 0, 10, accuracy: 2)
        XCTAssertLessThan(centers.last ?? 0, 20_000)
    }

    func testDoesNotExceedNyquist() {
        let mapper = FrequencyMapper(
            sampleRate: 48_000,
            fftSize: 4_096,
            barCount: 64,
            minimumFrequency: 10,
            maximumFrequency: 25_000
        )
        XCTAssertEqual(mapper.displayMaximum, 24_000, accuracy: 0.1)
        XCTAssertLessThanOrEqual(mapper.bands.last?.upperFrequency ?? 0, 24_000.1)
    }

    func testLogPosition() {
        XCTAssertEqual(FrequencyMapper.logPosition(frequency: 10, minFrequency: 10, maxFrequency: 10_000), 0, accuracy: 0.001)
        XCTAssertEqual(FrequencyMapper.logPosition(frequency: 10_000, minFrequency: 10, maxFrequency: 10_000), 1, accuracy: 0.001)
        XCTAssertEqual(FrequencyMapper.logPosition(frequency: 100, minFrequency: 10, maxFrequency: 10_000), 1.0 / 3.0, accuracy: 0.01)
        XCTAssertEqual(FrequencyMapper.logPosition(frequency: 1_000, minFrequency: 10, maxFrequency: 10_000), 2.0 / 3.0, accuracy: 0.01)
    }

    func testOneKilohertzMapsToExpectedBand() {
        let mapper = FrequencyMapper(
            sampleRate: 48_000,
            fftSize: 16_384,
            barCount: 128,
            minimumFrequency: 10,
            maximumFrequency: 20_000,
            aggregation: .peak
        )
        let fft = FFTProcessor(size: 16_384, window: .hann)
        let samples = SignalGenerator.sine(frequency: 1_000, sampleRate: 48_000, count: 16_384, amplitude: 0.8)
        let magnitudes = fft.process(samples: samples)
        let bands = mapper.map(magnitudes: magnitudes)
        let peakIndex = bands.enumerated().max(by: { $0.element < $1.element })?.offset ?? 0
        let peakBand = mapper.bands[peakIndex]
        XCTAssertTrue(
            peakBand.lowerFrequency <= 1_200 && peakBand.upperFrequency >= 800,
            "1 kHz peak landed in \(peakBand.lowerFrequency)–\(peakBand.upperFrequency) Hz"
        )
    }

    func testPeakAggregationTakesMaximum() {
        let mapper = FrequencyMapper(
            sampleRate: 48_000,
            fftSize: 1_024,
            barCount: 2,
            minimumFrequency: 10,
            maximumFrequency: 24_000,
            aggregation: .peak
        )
        var magnitudes = [Float](repeating: 0.01, count: 512)
        if let band = mapper.bands.first {
            XCTAssertGreaterThan(band.endBin - band.firstBin, 1)
            magnitudes[band.firstBin] = 0.9
        }
        let mapped = mapper.map(magnitudes: magnitudes)
        XCTAssertEqual(mapped[0], 0.9, accuracy: 0.0001)
    }

    func testSubBinBarsDoNotCloneASingleBassBin() {
        let mapper = FrequencyMapper(
            sampleRate: 48_000,
            fftSize: 8_192,
            barCount: 256,
            minimumFrequency: 10,
            maximumFrequency: 24_000,
            aggregation: .peak
        )
        var magnitudes = [Float](repeating: 0.001, count: 4_096)
        magnitudes[1] = 1.0
        let mapped = mapper.map(magnitudes: magnitudes)
        let hot = mapped.filter { $0 > 0.2 }.count
        XCTAssertLessThan(hot, 24, "A single FFT bin leaked into \(hot) bars")
        XCTAssertGreaterThan(mapped[0], mapped[80])
    }
}
