import Foundation

/// Window applied to each FFT frame before the transform.
/// Coefficients are generated once and applied with `vDSP_vmul`.
enum WindowFunction: String, CaseIterable, Identifiable, Hashable, Sendable {
    case hann = "Hann"
    case blackmanHarris = "Blackman-Harris"
    case rectangular = "Rectangular"

    var id: String { rawValue }

    /// Mean of the window (coherent gain). Used to keep a 0 dBFS sine near 0 dBFS after the FFT.
    var coherentGain: Float {
        switch self {
        case .hann: return 0.5
        case .blackmanHarris: return 0.35875
        case .rectangular: return 1.0
        }
    }

    func makeCoefficients(size: Int) -> [Float] {
        precondition(size > 0)
        var window = [Float](repeating: 1, count: size)

        switch self {
        case .rectangular:
            break
        case .hann:
            let scale = 2.0 * Float.pi / Float(size)
            for n in 0..<size {
                window[n] = 0.5 * (1.0 - cos(scale * Float(n)))
            }
        case .blackmanHarris:
            // 4-term Blackman-Harris (minimum 4-term, -92 dB sidelobes).
            let a0: Float = 0.35875
            let a1: Float = 0.48829
            let a2: Float = 0.14128
            let a3: Float = 0.01168
            let scale = 2.0 * Float.pi / Float(size)
            for n in 0..<size {
                let x = scale * Float(n)
                window[n] = a0 - a1 * cos(x) + a2 * cos(2 * x) - a3 * cos(3 * x)
            }
        }

        return window
    }
}
