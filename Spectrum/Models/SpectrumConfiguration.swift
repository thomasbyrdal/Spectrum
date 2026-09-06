import Foundation

enum BarCount: Int, CaseIterable, Identifiable, Sendable {
    case n32 = 32
    case n64 = 64
    case n128 = 128
    case n256 = 256
    case n512 = 512
    case n1024 = 1024

    var id: Int { rawValue }
    var label: String { String(rawValue) }
}

enum FFTSize: Int, CaseIterable, Identifiable, Sendable {
    case n2048 = 2_048
    case n4096 = 4_096
    case n8192 = 8_192
    case n16384 = 16_384
    case n32768 = 32_768
    case n65536 = 65_536

    var id: Int { rawValue }
    var label: String { String(rawValue) }
}

enum BandAggregation: String, CaseIterable, Identifiable, Sendable {
    case peak = "Peak"
    case average = "Average"
    case rms = "RMS"

    var id: String { rawValue }
}

enum SpectrumPreset: String, CaseIterable, Identifiable, Sendable {
    case speech = "Speech"
    case music = "Music"
    case detailed = "Detailed"
    case lowCPU = "Low CPU"

    var id: String { rawValue }

    var configuration: SpectrumConfiguration {
        switch self {
        case .speech:
            var config = SpectrumConfiguration()
            config.barCount = 64
            config.fftSize = 8_192
            config.windowFunction = .hann
            config.overlap = 0.75
            config.minimumFrequency = 80
            config.maximumFrequency = 8_000
            return config
        case .music:
            var config = SpectrumConfiguration()
            config.barCount = 128
            config.fftSize = 16_384
            config.windowFunction = .hann
            config.overlap = 0.75
            return config
        case .detailed:
            var config = SpectrumConfiguration()
            config.barCount = 256
            config.fftSize = 32_768
            config.windowFunction = .hann
            config.overlap = 0.75
            return config
        case .lowCPU:
            var config = SpectrumConfiguration()
            config.barCount = 64
            config.fftSize = 4_096
            config.windowFunction = .hann
            config.overlap = 0.50
            config.targetFrameRate = 30
            return config
        }
    }
}

enum BarStyle: String, CaseIterable, Identifiable, Sendable {
    case solid = "Solid"
    case gradient = "Gradient"
    case blueGradient = "Blue gradient"
    case greenGradient = "Green gradient"
    case redGradient = "Red gradient"
    case heat = "Heat"

    var id: String { rawValue }
}

enum PeakHoldStyle: String, CaseIterable, Identifiable, Sendable {
    case bar = "Bar"
    case rect = "Rect"

    var id: String { rawValue }
}

enum PeakHoldMode: String, CaseIterable, Identifiable, Sendable {
    case off = "Off"
    case bar = "Bar"
    case rect = "Rect"

    var id: String { rawValue }
}

enum StereoSpectrumLayout: String, CaseIterable, Identifiable, Sendable {
    case sideBySide
    case stacked

    var id: String { rawValue }

    var label: String {
        switch self {
        case .sideBySide: return "Left | Right"
        case .stacked: return "Right over left"
        }
    }
}

struct SpectrumConfiguration: Equatable, Sendable {
    var barCount: Int = 128
    var fftSize: Int = 8_192
    var windowFunction: WindowFunction = .hann
    var minimumFrequency: Float = 20
    var maximumFrequency: Float = 22_500
    var minimumDB: Float = -100
    var maximumDB: Float = 0
    var smoothingEnabled: Bool = true
    var peakHoldEnabled: Bool = true
    var peakHoldStyle: PeakHoldStyle = .bar
    var overlap: Float = 0.75
    var targetFrameRate: Int = 60
    var aggregation: BandAggregation = .peak
    var attackCoefficient: Float = 0.90
    var releaseCoefficient: Float = 0.90
    var peakHoldSeconds: Float = 0.4
    var peakDecayDBPerSecond: Float = 28
    var barStyle: BarStyle = .gradient
    var showGrid: Bool = true
    var barGlowEnabled: Bool = true
    var barReflectionEnabled: Bool = false
    var minimumMagnitude: Float = 1.0e-12

    var peakHoldMode: PeakHoldMode {
        get {
            guard peakHoldEnabled else { return .off }
            switch peakHoldStyle {
            case .bar: return .bar
            case .rect: return .rect
            }
        }
        set {
            switch newValue {
            case .off:
                peakHoldEnabled = false
            case .bar:
                peakHoldEnabled = true
                peakHoldStyle = .bar
            case .rect:
                peakHoldEnabled = true
                peakHoldStyle = .rect
            }
        }
    }

    /// Hop size in samples. Overlap and target frame rate both constrain it:
    /// a large FFT with 75% overlap would otherwise update too slowly for a 60 FPS display.
    func hopSize(sampleRate: Double) -> Int {
        let overlapHop = max(1, Int(Float(fftSize) * (1.0 - overlap)))
        let fps = max(15, targetFrameRate)
        let fpsHop = max(1, Int(sampleRate / Double(fps)))
        return min(overlapHop, fpsHop)
    }

    /// Bin spacing in Hz: `sampleRate / FFTSize`.
    func frequencyResolution(sampleRate: Double) -> Double {
        guard fftSize > 0 else { return 0 }
        return sampleRate / Double(fftSize)
    }

    /// Highest frequency that can legally be displayed for this sample rate.
    func displayMaximumFrequency(sampleRate: Double) -> Float {
        let nyquist = Float(sampleRate / 2.0)
        return min(maximumFrequency, nyquist)
    }
}
