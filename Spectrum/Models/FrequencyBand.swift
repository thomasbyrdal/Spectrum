import Foundation

struct FrequencyBand: Equatable, Sendable {
    let index: Int
    let lowerFrequency: Float
    let upperFrequency: Float
    /// Inclusive FFT bin index.
    let firstBin: Int
    /// Exclusive FFT bin index.
    let endBin: Int

    var centerFrequency: Float {
        sqrt(max(lowerFrequency, 1) * max(upperFrequency, 1))
    }
}
