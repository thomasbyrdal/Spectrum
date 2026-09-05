import Foundation

/// Immutable spectrum snapshot handed from the DSP thread to the UI.
/// Arrays are copied at construction so the audio path never shares mutable storage.
struct SpectrumData: Sendable, Equatable {
    let frequencies: [Float]
    let magnitudesDB: [Float]
    let peakMagnitudesDB: [Float]
    let timestamp: UInt64
    let peakDBFS: Float
    let rmsDBFS: Float
    let isClipping: Bool
    let sampleRate: Double
    let nyquist: Float
    /// Increments on every source start/stop so the UI can drop stale frames.
    let generation: UInt64

    var barCount: Int { magnitudesDB.count }

    func withGeneration(_ generation: UInt64) -> SpectrumData {
        SpectrumData(
            frequencies: frequencies,
            magnitudesDB: magnitudesDB,
            peakMagnitudesDB: peakMagnitudesDB,
            timestamp: timestamp,
            peakDBFS: peakDBFS,
            rmsDBFS: rmsDBFS,
            isClipping: isClipping,
            sampleRate: sampleRate,
            nyquist: nyquist,
            generation: generation
        )
    }

    static func empty(barCount: Int, sampleRate: Double, configuration: SpectrumConfiguration) -> SpectrumData {
        let nyquist = Float(sampleRate / 2.0)
        let maxF = min(configuration.maximumFrequency, nyquist)
        let minF = min(configuration.minimumFrequency, maxF)
        let frequencies: [Float]
        if barCount > 0 {
            let logMin = log10(max(minF, 1))
            let logMax = log10(max(maxF, minF + 1))
            frequencies = (0..<barCount).map { index in
                let t = Float(index) / Float(max(barCount - 1, 1))
                return pow(10, logMin + t * (logMax - logMin))
            }
        } else {
            frequencies = []
        }
        let floor = configuration.minimumDB
        return SpectrumData(
            frequencies: frequencies,
            magnitudesDB: [Float](repeating: floor, count: barCount),
            peakMagnitudesDB: [Float](repeating: floor, count: barCount),
            timestamp: 0,
            peakDBFS: floor,
            rmsDBFS: floor,
            isClipping: false,
            sampleRate: sampleRate,
            nyquist: nyquist,
            generation: 0
        )
    }
}

struct InputLevel: Sendable, Equatable {
    var peakDBFS: Float
    var rmsDBFS: Float
    var isClipping: Bool

    static let silent = InputLevel(peakDBFS: -120, rmsDBFS: -120, isClipping: false)
}
