import Foundation
import Observation

@MainActor
@Observable
final class SettingsViewModel {
    var configuration: SpectrumConfiguration
    var selectedPreset: SpectrumPreset?

    init(configuration: SpectrumConfiguration = SpectrumConfiguration()) {
        self.configuration = configuration
    }

    func applyPreset(_ preset: SpectrumPreset) {
        selectedPreset = preset
        var next = preset.configuration
        next.barStyle = configuration.barStyle
        next.showGrid = configuration.showGrid
        next.peakHoldEnabled = configuration.peakHoldEnabled
        next.peakHoldStyle = configuration.peakHoldStyle
        next.smoothingEnabled = configuration.smoothingEnabled
        configuration = next
    }

    var frequencyResolutionText: String {
        let hz = configuration.frequencyResolution(sampleRate: 48_000)
        return String(format: "%.2f Hz  (at 48 kHz)", hz)
    }
}
