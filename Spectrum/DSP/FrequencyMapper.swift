import Accelerate
import Foundation

/// Maps FFT bins onto logarithmically spaced display bands.
///
/// The number of bars is independent of FFT size. Each band covers a log-spaced
/// frequency interval; bins that fall inside it are aggregated (default: peak).
struct FrequencyMapper: Sendable {
    let sampleRate: Double
    let fftSize: Int
    let barCount: Int
    let minimumFrequency: Float
    let maximumFrequency: Float
    let aggregation: BandAggregation
    let bands: [FrequencyBand]

    var nyquist: Float { Float(sampleRate / 2.0) }

    var displayMinimum: Float { minimumFrequency }

    var displayMaximum: Float {
        min(maximumFrequency, nyquist)
    }

    var binHz: Float {
        guard fftSize > 0 else { return 0 }
        return Float(sampleRate) / Float(fftSize)
    }

    init(
        sampleRate: Double,
        fftSize: Int,
        barCount: Int,
        minimumFrequency: Float,
        maximumFrequency: Float,
        aggregation: BandAggregation = .peak
    ) {
        self.sampleRate = max(sampleRate, 1)
        self.fftSize = max(fftSize, 2)
        self.barCount = max(barCount, 1)
        self.aggregation = aggregation

        let nyquist = Float(self.sampleRate / 2.0)
        let maxF = min(max(maximumFrequency, 1), nyquist)
        let minF = min(max(minimumFrequency, 1), maxF)
        self.minimumFrequency = minF
        self.maximumFrequency = maxF
        self.bands = Self.makeBands(
            barCount: self.barCount,
            minFrequency: minF,
            maxFrequency: maxF,
            fftSize: self.fftSize,
            sampleRate: self.sampleRate
        )
    }

    func centerFrequencies() -> [Float] {
        bands.map(\.centerFrequency)
    }

    /// Convert a frequency to a 0...1 logarithmic x coordinate for the current display range.
    func xPosition(for frequency: Float) -> Float {
        Self.logPosition(frequency: frequency, minFrequency: displayMinimum, maxFrequency: displayMaximum)
    }

    static func logPosition(frequency: Float, minFrequency: Float, maxFrequency: Float) -> Float {
        let minF = max(minFrequency, 1)
        let maxF = max(maxFrequency, minF * 1.0001)
        let clamped = min(max(frequency, minF), maxF)
        let logMin = log10(minF)
        let logMax = log10(maxF)
        return (log10(clamped) - logMin) / (logMax - logMin)
    }

    func map(magnitudes: [Float]) -> [Float] {
        var output = [Float](repeating: 0, count: barCount)
        map(magnitudes: magnitudes, into: &output)
        return output
    }

    func map(magnitudes: [Float], into output: inout [Float]) {
        if output.count != barCount {
            output = [Float](repeating: 0, count: barCount)
        }
        let binCount = magnitudes.count
        guard binCount > 0 else { return }
        let binHz = self.binHz

        for band in bands {
            let start = min(max(band.firstBin, 0), binCount)
            let end = min(max(band.endBin, start), binCount)
            guard start < end else {
                output[band.index] = 0
                continue
            }

            // Bars narrower than one FFT bin must not all clone the same bin —
            // that paints a frozen “sweep” across the bass when DC leaks.
            if end - start <= 1, binHz > 0 {
                output[band.index] = Self.interpolatedMagnitude(
                    magnitudes,
                    frequency: band.centerFrequency,
                    binHz: binHz
                )
                continue
            }

            let slice = magnitudes[start..<end]
            switch aggregation {
            case .peak:
                output[band.index] = vDSP.maximum(slice)
            case .average:
                output[band.index] = vDSP.mean(slice)
            case .rms:
                output[band.index] = vDSP.rootMeanSquare(slice)
            }
        }
    }

    private static func makeBands(
        barCount: Int,
        minFrequency: Float,
        maxFrequency: Float,
        fftSize: Int,
        sampleRate: Double
    ) -> [FrequencyBand] {
        let logMin = log10(minFrequency)
        let logMax = log10(maxFrequency)
        let binHz = Float(sampleRate) / Float(fftSize)
        let maxBin = fftSize / 2

        var bands: [FrequencyBand] = []
        bands.reserveCapacity(barCount)

        for index in 0..<barCount {
            let t0 = Float(index) / Float(barCount)
            let t1 = Float(index + 1) / Float(barCount)
            let lower = pow(10, logMin + t0 * (logMax - logMin))
            let upper = pow(10, logMin + t1 * (logMax - logMin))
            let firstBin = min(max(Int((lower / binHz).rounded(.towardZero)), 1), maxBin)
            var endBin = min(max(Int((upper / binHz).rounded(.awayFromZero)), firstBin + 1), maxBin)
            if endBin <= firstBin {
                endBin = min(firstBin + 1, maxBin)
            }
            bands.append(
                FrequencyBand(
                    index: index,
                    lowerFrequency: lower,
                    upperFrequency: upper,
                    firstBin: firstBin,
                    endBin: endBin
                )
            )
        }

        return bands
    }

    private static func interpolatedMagnitude(_ magnitudes: [Float], frequency: Float, binHz: Float) -> Float {
        let bin = Double(frequency) / Double(binHz)
        let lower = Int(floor(bin))
        let upper = lower + 1
        guard lower >= 1, lower < magnitudes.count else {
            return lower >= 0 && lower < magnitudes.count ? magnitudes[lower] : 0
        }
        if upper >= magnitudes.count {
            return magnitudes[lower]
        }
        let fraction = Float(bin - Double(lower))
        return magnitudes[lower] + (magnitudes[upper] - magnitudes[lower]) * fraction
    }
}
