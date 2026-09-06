import Foundation
import Observation
import OSLog

@MainActor
@Observable
final class SpectrumViewModel {
    var configuration = SpectrumConfiguration()
    var spectrum: SpectrumData
    var source: AudioSource = .testSignal(.sine1k)
    var isRunning = false
    var errorMessage: String?
    var cpuUsage: Double = 0
    var displayFrameRate: Double = 0
    var sampleRate: Double = 48_000
    var channelCount: Int = 1
    var spectrumRight: SpectrumData?
    var showStereoSpectrum: Bool {
        didSet {
            UserDefaults.standard.set(showStereoSpectrum, forKey: Self.stereoPreferenceKey)
            engine.setShowStereoSpectrum(showStereoSpectrum)
        }
    }
    var alwaysOnTop: Bool {
        didSet {
            UserDefaults.standard.set(alwaysOnTop, forKey: Self.alwaysOnTopKey)
        }
    }
    var stereoSpectrumLayout: StereoSpectrumLayout {
        didSet {
            UserDefaults.standard.set(stereoSpectrumLayout.rawValue, forKey: Self.stereoLayoutKey)
        }
    }
    var disconnectedMessage: String?

    var stereoSpectrumAvailable: Bool { channelCount >= 2 }

    var displaysStereoSpectrum: Bool {
        showStereoSpectrum && stereoSpectrumAvailable && spectrumRight != nil
    }

    let devices: AudioDeviceViewModel
    let permissions = PermissionsManager()
    let settings = SettingsViewModel()
    let nowPlaying = NowPlayingController()

    private let engine: AudioEngineManager
    private let cpuMonitor = CPUUsageMonitor()
    private var cpuTimer: Timer?
    private var didStart = false
    private var captureSession = 0
    private var acceptedGeneration: UInt64 = 0
    private var deviceListEpoch = 0
    private var displayFrameTimes: [CFAbsoluteTime] = []

    private static let stereoPreferenceKey = "showStereoSpectrum"
    private static let alwaysOnTopKey = "alwaysOnTop"
    private static let stereoLayoutKey = "stereoSpectrumLayout"

    init() {
        let initial = SpectrumConfiguration()
        let engine = AudioEngineManager(configuration: initial)
        self.configuration = initial
        self.engine = engine
        self.devices = AudioDeviceViewModel(manager: engine.deviceManager)
        self.showStereoSpectrum = UserDefaults.standard.bool(forKey: Self.stereoPreferenceKey)
        self.alwaysOnTop = UserDefaults.standard.bool(forKey: Self.alwaysOnTopKey)
        if let raw = UserDefaults.standard.string(forKey: Self.stereoLayoutKey),
           let layout = StereoSpectrumLayout(rawValue: raw) {
            self.stereoSpectrumLayout = layout
        } else {
            self.stereoSpectrumLayout = .sideBySide
        }
        self.spectrum = SpectrumData.empty(
            barCount: initial.barCount,
            sampleRate: 48_000,
            configuration: initial
        )
        engine.setShowStereoSpectrum(showStereoSpectrum)

        engine.setSpectrumHandler { [weak self] pair in
            Task { @MainActor in
                guard let self else { return }
                guard pair.generation != 0, pair.generation == self.acceptedGeneration else {
                    return
                }
                self.spectrum = pair.left
                self.spectrumRight = pair.right
                self.noteDisplayFrame()
                if abs(self.sampleRate - pair.left.sampleRate) > 0.5 {
                    self.sampleRate = pair.left.sampleRate
                }
            }
        }
        engine.setActivityHandler { [weak self] analyzing in
            Task { @MainActor in
                guard let self else { return }
                self.isRunning = analyzing
                if !analyzing {
                    self.resetDisplayFrameRate()
                }
            }
        }
        settings.configuration = initial
    }

    var frequencyResolution: Double {
        configuration.frequencyResolution(sampleRate: sampleRate)
    }

    var displayFrequencyRange: String {
        let maxF = configuration.displayMaximumFrequency(sampleRate: sampleRate)
        return formatRange(min: configuration.minimumFrequency, max: maxF)
    }

    var nyquistLimited: Bool {
        configuration.maximumFrequency > Float(sampleRate / 2.0) + 0.5
    }

    var statusDeviceName: String {
        source.displayName
    }

    func start() {
        guard !didStart else { return }
        didStart = true
        devices.startListening { [weak self] in
            self?.handleDeviceListChange()
        }
        cpuTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.cpuUsage = self.cpuMonitor.sample()
                self.refreshDisplayFrameRate()
            }
        }
        syncNowPlaying()
        beginCapture()
    }

    func stop() {
        cpuTimer?.invalidate()
        cpuTimer = nil
        devices.stopListening()
        captureSession += 1
        acceptedGeneration = 0
        engine.stop()
        nowPlaying.detach()
        isRunning = false
        didStart = false
        resetDisplayFrameRate()
    }

    func select(_ source: AudioSource) {
        self.source = source
        errorMessage = nil
        disconnectedMessage = nil
        acceptedGeneration = 0
        isRunning = false
        resetDisplayFrameRate()
        spectrum = SpectrumData.empty(
            barCount: configuration.barCount,
            sampleRate: sampleRate,
            configuration: configuration
        )
        spectrumRight = nil
        syncNowPlaying()
        beginCapture()
    }

    func updateConfiguration(_ transform: (inout SpectrumConfiguration) -> Void) {
        let previousBarCount = configuration.barCount
        transform(&configuration)
        settings.configuration = configuration
        engine.applyConfiguration(configuration)
        if configuration.barCount != previousBarCount {
            spectrum = SpectrumData.empty(
                barCount: configuration.barCount,
                sampleRate: sampleRate,
                configuration: configuration
            )
            spectrumRight = SpectrumData.empty(
                barCount: configuration.barCount,
                sampleRate: sampleRate,
                configuration: configuration
            )
        }
    }

    func applySettings() {
        configuration = settings.configuration
        engine.applyConfiguration(configuration)
    }

    func applyPreset(_ preset: SpectrumPreset) {
        settings.applyPreset(preset)
        configuration = settings.configuration
        engine.applyConfiguration(configuration)
    }

    func requestMicrophoneAndRetry() {
        Task {
            let granted = await permissions.requestMicrophone()
            if granted {
                beginCapture()
            } else {
                errorMessage = AudioCaptureError.microphonePermissionRequired.localizedDescription
            }
        }
    }

    func requestScreenCaptureAndRetry() {
        permissions.requestScreenCapture()
        beginCapture()
    }

    private func beginCapture() {
        captureSession += 1
        let session = captureSession
        Task { await startCapture(session: session) }
    }

    private func startCapture(session: Int) async {
        errorMessage = nil
        disconnectedMessage = nil
        let source = self.source

        switch source {
        case .physical:
            permissions.refresh()
            if permissions.microphoneState != .granted {
                let granted = await permissions.requestMicrophone()
                if !granted {
                    guard session == captureSession else { return }
                    errorMessage = AudioCaptureError.microphonePermissionRequired.localizedDescription
                    engine.stop()
                    isRunning = false
                    return
                }
            }
        case .systemAudio, .application:
            permissions.refresh()
            if !permissions.screenCaptureAllowed {
                permissions.requestScreenCapture()
            }
        case .testSignal:
            break
        }

        guard session == captureSession else { return }

        do {
            try await engine.start(source: source)
            guard session == captureSession else { return }
            acceptedGeneration = engine.currentSpectrumGeneration
            sampleRate = engine.currentSampleRate
            channelCount = engine.currentChannelCount
            // Running/Stopped follows audible input, not merely that capture started.
        } catch is CancellationError {
            return
        } catch let error as AudioCaptureError {
            guard session == captureSession else { return }
            isRunning = false
            errorMessage = error.localizedDescription
            AppLog.audio.error("Capture failed: \(error.localizedDescription, privacy: .public)")
        } catch {
            guard session == captureSession else { return }
            isRunning = false
            errorMessage = AudioCaptureError.unableToStart(error.localizedDescription).localizedDescription
            AppLog.audio.error("Capture failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func handleDeviceListChange() {
        devices.refresh()
        guard case .physical(let device) = source else { return }
        guard !devices.deviceStillAvailable(device) else { return }

        deviceListEpoch += 1
        let epoch = deviceListEpoch
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            guard epoch == deviceListEpoch else { return }
            devices.refresh()
            guard case .physical(let current) = source else { return }
            guard !devices.deviceStillAvailable(current) else { return }

            disconnectedMessage = "Audio input disconnected"
            errorMessage = AudioCaptureError.deviceDisconnected.localizedDescription
            if let fallback = devices.defaultPhysicalDevice() {
                source = .physical(fallback)
            } else {
                source = .testSignal(.sine1k)
            }
            syncNowPlaying()
            beginCapture()
        }
    }

    private func syncNowPlaying() {
        if case .application(let process) = source, NowPlayingController.supports(source) {
            nowPlaying.attach(to: process)
        } else {
            nowPlaying.detach()
        }
    }

    private func noteDisplayFrame() {
        displayFrameTimes.append(CFAbsoluteTimeGetCurrent())
        refreshDisplayFrameRate()
    }

    private func refreshDisplayFrameRate() {
        let now = CFAbsoluteTimeGetCurrent()
        let cutoff = now - 1.0
        if let keep = displayFrameTimes.firstIndex(where: { $0 >= cutoff }) {
            if keep > 0 {
                displayFrameTimes.removeFirst(keep)
            }
        } else {
            displayFrameTimes.removeAll(keepingCapacity: true)
        }
        guard let oldest = displayFrameTimes.first, displayFrameTimes.count > 1 else {
            displayFrameRate = 0
            return
        }
        let span = now - oldest
        displayFrameRate = span > 0.05 ? Double(displayFrameTimes.count - 1) / span : 0
    }

    private func resetDisplayFrameRate() {
        displayFrameTimes.removeAll(keepingCapacity: true)
        displayFrameRate = 0
    }

    private func formatRange(min: Float, max: Float) -> String {
        "\(formatFrequency(min)) — \(formatFrequency(max))"
    }

    func formatFrequency(_ value: Float) -> String {
        if value >= 1000 {
            let kilo = value / 1000
            if kilo.rounded() == kilo {
                return "\(Int(kilo)) kHz"
            }
            return String(format: "%.1f kHz", kilo)
        }
        if value.rounded() == value {
            return "\(Int(value)) Hz"
        }
        return String(format: "%.1f Hz", value)
    }
}
