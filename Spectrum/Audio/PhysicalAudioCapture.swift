import CoreAudio
import Foundation

/// Captures a physical Core Audio input device via an IOProc.
final class PhysicalAudioCapture: AudioCapture, @unchecked Sendable {
    private let deviceManager: AudioDeviceManager
    private let hal: HALInputCapture

    private(set) var sampleRate: Double = 48_000
    private(set) var channelCount: Int = 1
    private(set) var isRunning = false

    var availableDevices: [AudioDevice] {
        deviceManager.inputDevices()
    }

    init(ringBuffer: AudioRingBuffer, bufferProcessor: AudioBufferProcessor, deviceManager: AudioDeviceManager) {
        self.deviceManager = deviceManager
        self.hal = HALInputCapture(processor: bufferProcessor, ringBuffer: ringBuffer)
    }

    func start(device: AudioDevice) async throws {
        stop()
        guard device.hasInput, device.kind == .physical else {
            throw AudioCaptureError.deviceHasNoInput
        }
        guard deviceManager.isAlive(device.objectID) else {
            throw AudioCaptureError.deviceDisconnected
        }

        try await MainActor.run {
            try self.hal.start(deviceID: device.objectID)
        }
        sampleRate = hal.sampleRate
        channelCount = hal.capturedChannelCount
        isRunning = true
    }

    func stop() {
        hal.stop()
        isRunning = false
    }
}
