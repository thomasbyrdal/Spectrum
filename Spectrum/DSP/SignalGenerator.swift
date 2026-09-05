import Foundation

/// Generates PCM test signals so DSP and visualization can be verified without hardware.
enum SignalGenerator {
    static func sine(
        frequency: Double,
        sampleRate: Double,
        count: Int,
        amplitude: Float = 0.5,
        phase: Double = 0
    ) -> [Float] {
        guard count > 0, sampleRate > 0 else { return [] }
        var samples = [Float](repeating: 0, count: count)
        let step = 2.0 * Double.pi * frequency / sampleRate
        for n in 0..<count {
            samples[n] = amplitude * Float(sin(phase + step * Double(n)))
        }
        return samples
    }

    static func multiTone(
        frequencies: [Double],
        sampleRate: Double,
        count: Int,
        amplitude: Float = 0.3
    ) -> [Float] {
        guard count > 0 else { return [] }
        var samples = [Float](repeating: 0, count: count)
        for frequency in frequencies {
            let tone = sine(frequency: frequency, sampleRate: sampleRate, count: count, amplitude: amplitude)
            for n in 0..<count {
                samples[n] += tone[n]
            }
        }
        return samples
    }
}

/// Stateful generator used by live capture (phase / filter memory persist across buffers).
final class LiveSignalGenerator: @unchecked Sendable {
    var kind: TestSignalKind
    var sampleRate: Double
    var amplitude: Float

    private var phase: Double = 0
    private var sweepFrequency: Double = 20
    private var pink: [Float] = [Float](repeating: 0, count: 7)

    init(kind: TestSignalKind, sampleRate: Double, amplitude: Float = 0.4) {
        self.kind = kind
        self.sampleRate = sampleRate
        self.amplitude = amplitude
    }

    func reset() {
        phase = 0
        sweepFrequency = 20
        pink = [Float](repeating: 0, count: 7)
    }

    func render(into destination: UnsafeMutablePointer<Float>, count: Int) {
        switch kind {
        case .sine1k:
            renderSine(frequency: 1_000, destination: destination, count: count)
        case .sine100:
            renderSine(frequency: 100, destination: destination, count: count)
        case .sine10k:
            renderSine(frequency: 10_000, destination: destination, count: count)
        case .multiTone:
            renderMultiTone(destination: destination, count: count)
        case .whiteNoise:
            renderWhite(destination: destination, count: count)
        case .pinkNoise:
            renderPink(destination: destination, count: count)
        case .sweep:
            renderSweep(destination: destination, count: count)
        }
    }

    private func renderSine(frequency: Double, destination: UnsafeMutablePointer<Float>, count: Int) {
        let step = 2.0 * Double.pi * frequency / sampleRate
        for n in 0..<count {
            destination[n] = amplitude * Float(sin(phase))
            phase += step
            if phase > 2.0 * Double.pi {
                phase -= 2.0 * Double.pi
            }
        }
    }

    private func renderMultiTone(destination: UnsafeMutablePointer<Float>, count: Int) {
        let frequencies = [100.0, 1_000.0, 10_000.0]
        let stepBase = 2.0 * Double.pi / sampleRate
        var localPhase = phase
        for n in 0..<count {
            var sample: Double = 0
            for frequency in frequencies {
                sample += sin(localPhase * frequency)
            }
            destination[n] = amplitude * 0.45 * Float(sample)
            localPhase += stepBase
        }
        phase = localPhase
        if phase > 2.0 * Double.pi * 10_000 {
            phase.formTruncatingRemainder(dividingBy: 2.0 * Double.pi)
        }
    }

    private func renderWhite(destination: UnsafeMutablePointer<Float>, count: Int) {
        for n in 0..<count {
            destination[n] = amplitude * Float.random(in: -1...1)
        }
    }

    /// Paul Kellet refined pink-noise filter.
    private func renderPink(destination: UnsafeMutablePointer<Float>, count: Int) {
        for n in 0..<count {
            let white = Float.random(in: -1...1)
            pink[0] = 0.99886 * pink[0] + white * 0.0555179
            pink[1] = 0.99332 * pink[1] + white * 0.0750759
            pink[2] = 0.96900 * pink[2] + white * 0.1538520
            pink[3] = 0.86650 * pink[3] + white * 0.3104856
            pink[4] = 0.55000 * pink[4] + white * 0.5329522
            pink[5] = -0.7616 * pink[5] - white * 0.0168980
            let sample = pink[0] + pink[1] + pink[2] + pink[3] + pink[4] + pink[5] + pink[6] + white * 0.5362
            pink[6] = white * 0.115926
            destination[n] = amplitude * sample * 0.11
        }
    }

    private func renderSweep(destination: UnsafeMutablePointer<Float>, count: Int) {
        let start = 20.0
        let end = min(20_000.0, sampleRate / 2.0 * 0.9)
        let duration = 8.0
        let ratio = pow(end / start, 1.0 / (duration * sampleRate))
        for n in 0..<count {
            destination[n] = amplitude * Float(sin(phase))
            phase += 2.0 * Double.pi * sweepFrequency / sampleRate
            if phase > 2.0 * Double.pi {
                phase -= 2.0 * Double.pi
            }
            sweepFrequency *= ratio
            if sweepFrequency >= end {
                sweepFrequency = start
            }
        }
    }
}
