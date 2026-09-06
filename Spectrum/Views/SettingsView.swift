import SwiftUI

struct SettingsView: View {
    @Bindable var viewModel: SpectrumViewModel

    var body: some View {
        TabView {
            audioTab
                .tabItem { Label("Audio", systemImage: "mic") }
            spectrumTab
                .tabItem { Label("Spectrum", systemImage: "waveform") }
            appearanceTab
                .tabItem { Label("Appearance", systemImage: "paintpalette") }
            performanceTab
                .tabItem { Label("Performance", systemImage: "gauge") }
        }
        .frame(width: 520, height: 460)
        .onChange(of: viewModel.settings.configuration) { _, newValue in
            viewModel.configuration = newValue
            viewModel.applySettings()
        }
    }

    private var audioTab: some View {
        Form {
            Section("Input device") {
                Picker("Source", selection: sourceBinding) {
                    Text(viewModel.source.displayName).tag(viewModel.source)
                }
                .pickerStyle(.menu)
                Text("Use the Input menu in the main window to choose a device, test signal, system audio, or application.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Microphone Access") {
                LabeledContent("Status", value: viewModel.permissions.microphoneState.rawValue)
                Text("Spectrum needs microphone access to analyze physical audio inputs such as built-in, USB, and interface devices.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Request Access") { viewModel.requestMicrophoneAndRetry() }
                    Button("Open System Settings") { viewModel.permissions.openMicrophoneSettings() }
                }
            }

            Section("System Audio") {
                LabeledContent(
                    "Screen Recording",
                    value: viewModel.permissions.screenCaptureAllowed ? "Granted" : "Required"
                )
                Text("macOS requires Screen Recording permission for Core Audio Taps, which capture audio produced by other applications. Spectrum does not record the screen.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Request Access") { viewModel.requestScreenCaptureAndRetry() }
                    Button("Open System Settings") { viewModel.permissions.openScreenRecordingSettings() }
                }
            }

            Section("Presets") {
                Picker("Preset", selection: presetBinding) {
                    Text("Custom").tag(SpectrumPreset?.none)
                    ForEach(SpectrumPreset.allCases) { preset in
                        Text(preset.rawValue).tag(Optional(preset))
                    }
                }
                .pickerStyle(.menu)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var spectrumTab: some View {
        Form {
            Section("Bars") {
                Picker("Bar count", selection: barBinding) {
                    ForEach(BarCount.allCases) { count in
                        Text(count.label).tag(count.rawValue)
                    }
                }
                .pickerStyle(.menu)
            }
            Section("FFT") {
                Picker("FFT size", selection: fftBinding) {
                    ForEach(FFTSize.allCases) { size in
                        Text(size.label).tag(size.rawValue)
                    }
                }
                .pickerStyle(.menu)
                LabeledContent("Frequency resolution") {
                    Text(String(format: "%.2f Hz  at current sample rate", viewModel.frequencyResolution))
                        .font(.body.monospaced())
                }
                Text("Resolution = sample rate / FFT size. A 48 kHz input with FFT 16384 is about 2.93 Hz/bin. Low frequencies near 10 Hz need a large FFT.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section("Frequency range") {
                TextField("Minimum Hz", value: minFreqBinding, format: .number)
                TextField("Maximum Hz", value: maxFreqBinding, format: .number)
                Text("The displayed maximum is limited by Nyquist (sample rate / 2). Spectrum never invents frequencies above that.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section("dB range") {
                TextField("Minimum dB", value: minDBBinding, format: .number)
                TextField("Maximum dB", value: maxDBBinding, format: .number)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var appearanceTab: some View {
        Form {
            Section("Theme") {
                LabeledContent("Theme", value: "Classic Dark")
            }
            Section("Bars") {
                Picker("Bar style", selection: barStyleBinding) {
                    ForEach(BarStyle.allCases) { style in
                        Text(style.rawValue).tag(style)
                    }
                }
                .pickerStyle(.menu)
                Toggle("Bar glow", isOn: glowBinding)
                Toggle("Mirrored reflection", isOn: reflectionBinding)
            }
            Section("Stereo spectrum") {
                Picker("Layout", selection: stereoLayoutBinding) {
                    ForEach(StereoSpectrumLayout.allCases) { layout in
                        Text(layout.label).tag(layout)
                    }
                }
                .pickerStyle(.menu)
                Text("Used when Show stereo spectrum is on. Left | Right places the left channel on the left. Right over left places the right channel on top and the left channel on the bottom.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section("Grid") {
                Toggle("Show grid", isOn: gridBinding)
            }
            Section("Peak hold") {
                Toggle("Peak hold", isOn: peakHoldBinding)
                Picker("Peak hold style", selection: peakHoldStyleBinding) {
                    ForEach(PeakHoldStyle.allCases) { style in
                        Text(style.rawValue).tag(style)
                    }
                }
                .pickerStyle(.menu)
                .disabled(!viewModel.settings.configuration.peakHoldEnabled)
                Slider(value: peakHoldTimeBinding, in: 0.4...3, step: 0.1) {
                    Text("Hold time")
                } minimumValueLabel: {
                    Text("0.4s")
                } maximumValueLabel: {
                    Text("3s")
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var performanceTab: some View {
        Form {
            Section("Frame rate") {
                Picker("Target FPS", selection: fpsBinding) {
                    Text("30").tag(30)
                    Text("60").tag(60)
                }
                .pickerStyle(.menu)
            }
            Section("Smoothing") {
                Toggle("Smoothing", isOn: smoothingBinding)
                Slider(value: attackBinding, in: 0.05...1) { Text("Attack") }
                Slider(value: releaseBinding, in: 0.05...1) { Text("Release") }
            }
            Section("FFT overlap") {
                Picker("Overlap", selection: overlapBinding) {
                    Text("50%").tag(Float(0.50))
                    Text("75%").tag(Float(0.75))
                    Text("87.5%").tag(Float(0.875))
                }
                .pickerStyle(.menu)
                Text("Overlap keeps the analyzer visually smooth. Hop size is also limited by the target frame rate so large FFTs still update in real time.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var sourceBinding: Binding<AudioSource> {
        Binding(
            get: { viewModel.source },
            set: { viewModel.select($0) }
        )
    }

    private var presetBinding: Binding<SpectrumPreset?> {
        Binding(
            get: { viewModel.settings.selectedPreset },
            set: { preset in
                if let preset {
                    viewModel.applyPreset(preset)
                } else {
                    viewModel.settings.selectedPreset = nil
                }
            }
        )
    }

    private var barBinding: Binding<Int> {
        Binding(
            get: { viewModel.settings.configuration.barCount },
            set: { viewModel.settings.configuration.barCount = $0 }
        )
    }

    private var fftBinding: Binding<Int> {
        Binding(
            get: { viewModel.settings.configuration.fftSize },
            set: { viewModel.settings.configuration.fftSize = $0 }
        )
    }

    private var minFreqBinding: Binding<Float> {
        Binding(
            get: { viewModel.settings.configuration.minimumFrequency },
            set: { viewModel.settings.configuration.minimumFrequency = $0 }
        )
    }

    private var maxFreqBinding: Binding<Float> {
        Binding(
            get: { viewModel.settings.configuration.maximumFrequency },
            set: { viewModel.settings.configuration.maximumFrequency = $0 }
        )
    }

    private var minDBBinding: Binding<Float> {
        Binding(
            get: { viewModel.settings.configuration.minimumDB },
            set: { viewModel.settings.configuration.minimumDB = $0 }
        )
    }

    private var maxDBBinding: Binding<Float> {
        Binding(
            get: { viewModel.settings.configuration.maximumDB },
            set: { viewModel.settings.configuration.maximumDB = $0 }
        )
    }

    private var barStyleBinding: Binding<BarStyle> {
        Binding(
            get: { viewModel.settings.configuration.barStyle },
            set: { viewModel.settings.configuration.barStyle = $0 }
        )
    }

    private var glowBinding: Binding<Bool> {
        Binding(
            get: { viewModel.settings.configuration.barGlowEnabled },
            set: { viewModel.settings.configuration.barGlowEnabled = $0 }
        )
    }

    private var reflectionBinding: Binding<Bool> {
        Binding(
            get: { viewModel.settings.configuration.barReflectionEnabled },
            set: { viewModel.settings.configuration.barReflectionEnabled = $0 }
        )
    }

    private var stereoLayoutBinding: Binding<StereoSpectrumLayout> {
        Binding(
            get: { viewModel.stereoSpectrumLayout },
            set: { viewModel.stereoSpectrumLayout = $0 }
        )
    }

    private var gridBinding: Binding<Bool> {
        Binding(
            get: { viewModel.settings.configuration.showGrid },
            set: { viewModel.settings.configuration.showGrid = $0 }
        )
    }

    private var peakHoldBinding: Binding<Bool> {
        Binding(
            get: { viewModel.settings.configuration.peakHoldEnabled },
            set: { viewModel.settings.configuration.peakHoldEnabled = $0 }
        )
    }

    private var peakHoldStyleBinding: Binding<PeakHoldStyle> {
        Binding(
            get: { viewModel.settings.configuration.peakHoldStyle },
            set: { viewModel.settings.configuration.peakHoldStyle = $0 }
        )
    }

    private var peakHoldTimeBinding: Binding<Float> {
        Binding(
            get: { viewModel.settings.configuration.peakHoldSeconds },
            set: { viewModel.settings.configuration.peakHoldSeconds = $0 }
        )
    }

    private var fpsBinding: Binding<Int> {
        Binding(
            get: { viewModel.settings.configuration.targetFrameRate },
            set: { viewModel.settings.configuration.targetFrameRate = $0 }
        )
    }

    private var smoothingBinding: Binding<Bool> {
        Binding(
            get: { viewModel.settings.configuration.smoothingEnabled },
            set: { viewModel.settings.configuration.smoothingEnabled = $0 }
        )
    }

    private var attackBinding: Binding<Float> {
        Binding(
            get: { viewModel.settings.configuration.attackCoefficient },
            set: { viewModel.settings.configuration.attackCoefficient = $0 }
        )
    }

    private var releaseBinding: Binding<Float> {
        Binding(
            get: { viewModel.settings.configuration.releaseCoefficient },
            set: { viewModel.settings.configuration.releaseCoefficient = $0 }
        )
    }

    private var overlapBinding: Binding<Float> {
        Binding(
            get: { viewModel.settings.configuration.overlap },
            set: { viewModel.settings.configuration.overlap = $0 }
        )
    }
}
