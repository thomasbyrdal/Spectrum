import Foundation

/// Capture abstraction. DSP never knows whether samples came from a microphone,
/// a Core Audio Tap, or an internal test generator.
protocol AudioCapture: AnyObject {
    var availableDevices: [AudioDevice] { get }
    var sampleRate: Double { get }
    var channelCount: Int { get }
    var isRunning: Bool { get }

    func start(device: AudioDevice) async throws
    func stop()
}

/// Optional capture that can also target a running process via Core Audio Tap.
protocol ProcessAudioCapture: AudioCapture {
    func startSystemAudio() async throws
    func start(process: AudioProcess) async throws
}
