import Accelerate
import Foundation

/// Real-valued FFT using Accelerate `vDSP_fft_zrip`.
///
/// Normalization (documented because spectrum analyzers disagree on this):
/// 1. A window is applied to the time-domain frame (`vDSP_vmul`).
/// 2. `vDSP_fft_zrip` (forward, radix-2) produces a packed split-complex spectrum.
///    The transform is unnormalized: a DC value of 1.0 yields `N` in `realp[0]`.
///    Packed format stores DC in `realp[0]`, Nyquist in `imagp[0]`.
/// 3. Magnitude is `hypot(re, im)`.
/// 4. We scale every bin by `1 / (N * coherentGain)`.
///    Coherent gain is the mean of the window (Hann = 0.5). This makes a full-scale
///    sine (`±1.0`) that lands on a bin read approximately `0 dBFS` after `20*log10`.
///    An extra ×2 for non-DC bins would make that sine read +6 dB.
///
/// Frequency of bin `k` is `k * sampleRate / N`. Nyquist is bin `N/2`.
final class FFTProcessor: @unchecked Sendable {
    let size: Int
    private(set) var windowFunction: WindowFunction

    private let log2n: vDSP_Length
    private let halfSize: Int
    private let fftSetup: FFTSetup

    private let window: UnsafeMutablePointer<Float>
    private let timeDomain: UnsafeMutablePointer<Float>
    private let realp: UnsafeMutablePointer<Float>
    private let imagp: UnsafeMutablePointer<Float>
    private let magnitudes: UnsafeMutablePointer<Float>
    private var magnitudeCache: [Float]
    private var scale: Float
    private var nyquistScale: Float

    init(size: Int, window: WindowFunction = .hann) {
        precondition(size >= 16 && size.nonzeroBitCount == 1, "FFT size must be a power of two.")
        self.size = size
        self.windowFunction = window
        self.log2n = vDSP_Length(size.trailingZeroBitCount)
        self.halfSize = size / 2

        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            preconditionFailure("Unable to create vDSP FFT setup.")
        }
        self.fftSetup = setup

        self.window = .allocate(capacity: size)
        self.timeDomain = .allocate(capacity: size)
        self.realp = .allocate(capacity: halfSize)
        self.imagp = .allocate(capacity: halfSize)
        self.magnitudes = .allocate(capacity: halfSize)
        self.window.initialize(repeating: 0, count: size)
        self.timeDomain.initialize(repeating: 0, count: size)
        self.realp.initialize(repeating: 0, count: halfSize)
        self.imagp.initialize(repeating: 0, count: halfSize)
        self.magnitudes.initialize(repeating: 0, count: halfSize)
        self.magnitudeCache = [Float](repeating: 0, count: halfSize)

        let gain = max(window.coherentGain, 1.0e-6)
        // zrip already folds negative frequencies into bins 1..<N/2 (implicit ×2).
        // Divide by N and the window coherent gain so a 0 dBFS bin-centered sine reads ~0 dBFS.
        self.scale = 1.0 / (Float(size) * gain)
        self.nyquistScale = 1.0 / (Float(size) * gain)

        let coefficients = window.makeCoefficients(size: size)
        let windowPtr = self.window
        coefficients.withUnsafeBufferPointer { source in
            windowPtr.update(from: source.baseAddress!, count: size)
        }
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
        window.deinitialize(count: size)
        timeDomain.deinitialize(count: size)
        realp.deinitialize(count: halfSize)
        imagp.deinitialize(count: halfSize)
        magnitudes.deinitialize(count: halfSize)
        window.deallocate()
        timeDomain.deallocate()
        realp.deallocate()
        imagp.deallocate()
        magnitudes.deallocate()
    }

    func setWindow(_ window: WindowFunction) {
        guard window != windowFunction else { return }
        windowFunction = window
        let coefficients = window.makeCoefficients(size: size)
        coefficients.withUnsafeBufferPointer { source in
            self.window.update(from: source.baseAddress!, count: size)
        }
        let gain = max(window.coherentGain, 1.0e-6)
        scale = 1.0 / (Float(size) * gain)
        nyquistScale = 1.0 / (Float(size) * gain)
    }

    /// Linear (not dB) one-sided magnitudes, length `size/2` (DC .. just below Nyquist).
    func process(samples: [Float]) -> [Float] {
        samples.withUnsafeBufferPointer { buffer in
            process(samples: buffer)
        }
    }

    func process(samples: UnsafeBufferPointer<Float>) -> [Float] {
        let count = min(samples.count, size)
        memset(timeDomain, 0, size * MemoryLayout<Float>.stride)
        if let base = samples.baseAddress, count > 0 {
            memcpy(timeDomain, base, count * MemoryLayout<Float>.stride)
        }

        if count > 1 {
            var mean: Float = 0
            vDSP_meanv(timeDomain, 1, &mean, vDSP_Length(count))
            var neg = -mean
            vDSP_vsadd(timeDomain, 1, &neg, timeDomain, 1, vDSP_Length(count))
        }

        vDSP_vmul(timeDomain, 1, window, 1, timeDomain, 1, vDSP_Length(size))

        var split = DSPSplitComplex(realp: realp, imagp: imagp)
        timeDomain.withMemoryRebound(to: DSPComplex.self, capacity: halfSize) { complex in
            vDSP_ctoz(complex, 2, &split, 1, vDSP_Length(halfSize))
        }
        vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
        vDSP_zvabs(&split, 1, magnitudes, 1, vDSP_Length(halfSize))

        magnitudes[0] *= nyquistScale
        if halfSize > 1 {
            var s = scale
            vDSP_vsmul(magnitudes + 1, 1, &s, magnitudes + 1, 1, vDSP_Length(halfSize - 1))
        }

        magnitudeCache.withUnsafeMutableBufferPointer { dest in
            dest.baseAddress!.update(from: magnitudes, count: halfSize)
        }
        return magnitudeCache
    }

    /// Frequency in Hz of the strongest non-DC bin.
    func peakFrequency(magnitudes: [Float], sampleRate: Double) -> Float {
        guard magnitudes.count > 1, sampleRate > 0 else { return 0 }
        var maxValue: Float = 0
        var maxIndex: vDSP_Length = 0
        magnitudes.withUnsafeBufferPointer { buffer in
            vDSP_maxvi(buffer.baseAddress! + 1, 1, &maxValue, &maxIndex, vDSP_Length(magnitudes.count - 1))
        }
        let bin = Int(maxIndex) + 1
        return Float(bin) * Float(sampleRate) / Float(size)
    }
}
