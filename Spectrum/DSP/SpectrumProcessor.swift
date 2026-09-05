import Accelerate
import Foundation

/// DSP orchestrator: sliding-window FFT → log-band mapping → dB → smoothing → `SpectrumData`.
///
/// Owns reusable FFT state and never runs on the real-time audio callback.
final class SpectrumProcessor: @unchecked Sendable {
    private var configuration: SpectrumConfiguration
    private var sampleRate: Double
    private var fft: FFTProcessor
    private var mapper: FrequencyMapper
    private var smoother: SpectrumSmoother
    private var timeBuffer: [Float]
    private var filled: Int
    private var linearBands: [Float]
    private var dbBands: [Float]
    private var hop: Int

    init(configuration: SpectrumConfiguration, sampleRate: Double) {
        self.configuration = configuration
        self.sampleRate = sampleRate
        self.fft = FFTProcessor(size: configuration.fftSize, window: configuration.windowFunction)
        self.mapper = FrequencyMapper(
            sampleRate: sampleRate,
            fftSize: configuration.fftSize,
            barCount: configuration.barCount,
            minimumFrequency: configuration.minimumFrequency,
            maximumFrequency: configuration.maximumFrequency,
            aggregation: configuration.aggregation
        )
        self.smoother = SpectrumSmoother(
            barCount: configuration.barCount,
            attack: configuration.attackCoefficient,
            release: configuration.releaseCoefficient,
            peakHoldSeconds: configuration.peakHoldSeconds,
            peakDecayDBPerSecond: configuration.peakDecayDBPerSecond,
            floorDB: configuration.minimumDB
        )
        self.timeBuffer = [Float](repeating: 0, count: configuration.fftSize)
        self.filled = 0
        self.linearBands = [Float](repeating: 0, count: configuration.barCount)
        self.dbBands = [Float](repeating: configuration.minimumDB, count: configuration.barCount)
        self.hop = configuration.hopSize(sampleRate: sampleRate)
    }

    var hopSize: Int { hop }

    var currentMapper: FrequencyMapper { mapper }

    func reconfigure(configuration: SpectrumConfiguration, sampleRate: Double) {
        let fftChanged = configuration.fftSize != self.configuration.fftSize
        let windowChanged = configuration.windowFunction != self.configuration.windowFunction
        let mappingChanged =
            fftChanged
            || configuration.barCount != self.configuration.barCount
            || configuration.minimumFrequency != self.configuration.minimumFrequency
            || configuration.maximumFrequency != self.configuration.maximumFrequency
            || configuration.aggregation != self.configuration.aggregation
            || sampleRate != self.sampleRate

        self.configuration = configuration
        self.sampleRate = sampleRate
        self.hop = configuration.hopSize(sampleRate: sampleRate)

        if fftChanged {
            fft = FFTProcessor(size: configuration.fftSize, window: configuration.windowFunction)
            timeBuffer = [Float](repeating: 0, count: configuration.fftSize)
            filled = 0
        } else if windowChanged {
            fft.setWindow(configuration.windowFunction)
        }

        if mappingChanged {
            mapper = FrequencyMapper(
                sampleRate: sampleRate,
                fftSize: configuration.fftSize,
                barCount: configuration.barCount,
                minimumFrequency: configuration.minimumFrequency,
                maximumFrequency: configuration.maximumFrequency,
                aggregation: configuration.aggregation
            )
        }

        if configuration.barCount != linearBands.count {
            linearBands = [Float](repeating: 0, count: configuration.barCount)
            dbBands = [Float](repeating: configuration.minimumDB, count: configuration.barCount)
            smoother.reset(barCount: configuration.barCount, floorDB: configuration.minimumDB)
        }

        smoother.attack = configuration.attackCoefficient
        smoother.release = configuration.releaseCoefficient
        smoother.peakHoldSeconds = configuration.peakHoldSeconds
        smoother.peakDecayDBPerSecond = configuration.peakDecayDBPerSecond
    }

    func reset() {
        timeBuffer = [Float](repeating: 0, count: configuration.fftSize)
        filled = 0
        smoother.reset(barCount: configuration.barCount, floorDB: configuration.minimumDB)
    }

    /// Appends PCM, returning a spectrum snapshot once a hop has been accumulated.
    func push(samples: UnsafeBufferPointer<Float>, peakDBFS: Float, rmsDBFS: Float, isClipping: Bool) -> SpectrumData? {
        let fftSize = configuration.fftSize
        var offset = 0
        var latest: SpectrumData?

        while offset < samples.count {
            let space = fftSize - filled
            let copyCount = min(space, samples.count - offset)
            if copyCount > 0 {
                timeBuffer.withUnsafeMutableBufferPointer { dest in
                    dest.baseAddress!.advanced(by: filled)
                        .update(from: samples.baseAddress!.advanced(by: offset), count: copyCount)
                }
                filled += copyCount
                offset += copyCount
            }

            if filled == fftSize {
                latest = analyzeFrame(peakDBFS: peakDBFS, rmsDBFS: rmsDBFS, isClipping: isClipping)
                let keep = fftSize - hop
                if keep > 0 {
                    timeBuffer.withUnsafeMutableBufferPointer { buffer in
                        memmove(buffer.baseAddress!, buffer.baseAddress! + hop, keep * MemoryLayout<Float>.stride)
                    }
                    filled = keep
                } else {
                    filled = 0
                }
            }
        }

        return latest
    }

    private func analyzeFrame(peakDBFS: Float, rmsDBFS: Float, isClipping: Bool) -> SpectrumData {
        let magnitudes = timeBuffer.withUnsafeBufferPointer { fft.process(samples: $0) }
        mapper.map(magnitudes: magnitudes, into: &linearBands)
        DecibelCalculator.amplitudeToDB(
            linearBands,
            result: &dbBands,
            minimumMagnitude: configuration.minimumMagnitude,
            floorDB: configuration.minimumDB
        )

        let timestamp = machAbsoluteNanoseconds()
        let smoothed = smoother.process(
            levelsDB: dbBands,
            timestamp: timestamp,
            enableSmoothing: configuration.smoothingEnabled,
            enablePeakHold: configuration.peakHoldEnabled
        )

        return SpectrumData(
            frequencies: mapper.centerFrequencies(),
            magnitudesDB: smoothed.levels,
            peakMagnitudesDB: smoothed.peaks,
            timestamp: timestamp,
            peakDBFS: peakDBFS,
            rmsDBFS: rmsDBFS,
            isClipping: isClipping,
            sampleRate: sampleRate,
            nyquist: mapper.nyquist,
            generation: 0
        )
    }
}

func machAbsoluteNanoseconds() -> UInt64 {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    let ticks = mach_absolute_time()
    return ticks * UInt64(info.numer) / UInt64(info.denom)
}
