import CoreAudio
import Foundation
import OSLog

/// Captures system-wide or per-process output using Core Audio Taps (macOS 14.2+).
///
/// Matches the working AudioCap/Recap recipe:
///   CATapDescription.uuid → process tap → private aggregate (default output + tap) → IOProc
final class SystemAudioCapture: ProcessAudioCapture, @unchecked Sendable {
    private var tapID: AudioObjectID = 0
    private var aggregateID: AudioObjectID = 0
    private let hal: HALInputCapture
    private let deviceManager: AudioDeviceManager
    private var installGeneration: UInt64 = 0

    private(set) var sampleRate: Double = 48_000
    private(set) var channelCount: Int = 2
    private(set) var isRunning = false

    var availableDevices: [AudioDevice] {
        [AudioDevice.systemAudio(sampleRate: sampleRate)]
    }

    init(ringBuffer: AudioRingBuffer, bufferProcessor: AudioBufferProcessor, deviceManager: AudioDeviceManager) {
        self.hal = HALInputCapture(processor: bufferProcessor, ringBuffer: ringBuffer)
        self.deviceManager = deviceManager
    }

    func start(device: AudioDevice) async throws {
        switch device.kind {
        case .systemAudio:
            try await startSystemAudio()
        case .application:
            throw AudioCaptureError.unableToStart("Use start(process:) for application capture.")
        default:
            throw AudioCaptureError.deviceHasNoInput
        }
    }

    func startSystemAudio() async throws {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        configureTapDescription(description, name: "Spectrum System Audio")
        try await installTap(description)
    }

    func start(process: AudioProcess) async throws {
        let relatedIDs = deviceManager.processObjectIDs(relatedTo: process)
        let description = CATapDescription(stereoMixdownOfProcesses: relatedIDs)
        configureTapDescription(description, name: "Spectrum Tap — \(process.name)")
        if #available(macOS 26.0, *), let bundleID = process.bundleID, !bundleID.isEmpty {
            description.bundleIDs = [bundleID]
        }
        try await installTap(description)
    }

    private func configureTapDescription(_ description: CATapDescription, name: String) {
        description.name = name
        description.uuid = UUID()
        description.muteBehavior = .unmuted
        description.stream = nil
        if #available(macOS 26.0, *) {
            description.isProcessRestoreEnabled = true
        }
    }

    func stop() {
        installGeneration &+= 1
        hal.stop()
        destroyTapResources()
        isRunning = false
    }

    private func installTap(_ description: CATapDescription) async throws {
        stop()
        let generation = installGeneration

        guard let output = try AudioHardwareSystem.shared.defaultOutputDevice else {
            throw AudioCaptureError.systemAudioUnavailable
        }

        var createdTapID: AudioObjectID = 0
        let tapStatus = AudioHardwareCreateProcessTap(description, &createdTapID)
        guard tapStatus == noErr, createdTapID != 0 else {
            AppLog.audio.error("AudioHardwareCreateProcessTap failed \(tapStatus, privacy: .public)")
            throw AudioCaptureError.tapPermissionRequired
        }
        tapID = createdTapID

        let outputUID = try output.uid
        let tapUID = description.uuid.uuidString
        let tapFormat = readTapFormat(createdTapID)

        let composition: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Spectrum Tap Aggregate",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: tapUID
                ]
            ]
        ]

        var createdAggregateID: AudioObjectID = 0
        let aggregateStatus = AudioHardwareCreateAggregateDevice(composition as CFDictionary, &createdAggregateID)
        guard aggregateStatus == noErr, createdAggregateID != 0 else {
            destroyTapResources()
            AppLog.audio.error("AudioHardwareCreateAggregateDevice failed \(aggregateStatus, privacy: .public)")
            throw AudioCaptureError.systemAudioUnavailable
        }
        aggregateID = createdAggregateID

        let ready = await waitUntilAlive(createdAggregateID)
        guard generation == installGeneration else {
            throw CancellationError()
        }
        guard ready else {
            destroyTapResources()
            throw AudioCaptureError.systemAudioUnavailable
        }

        do {
            try await MainActor.run {
                try self.hal.start(deviceID: createdAggregateID, format: tapFormat)
            }
        } catch {
            destroyTapResources()
            throw error
        }

        guard generation == installGeneration else {
            hal.stop()
            destroyTapResources()
            throw CancellationError()
        }

        sampleRate = hal.sampleRate
        channelCount = hal.capturedChannelCount
        isRunning = true
    }

    private func readTapFormat(_ tapID: AudioObjectID) -> AudioStreamBasicDescription? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd)
        guard status == noErr, asbd.mChannelsPerFrame > 0, asbd.mSampleRate > 0 else {
            return nil
        }
        return asbd
    }

    private func waitUntilAlive(_ deviceID: AudioObjectID) async -> Bool {
        for _ in 0..<20 {
            if isDeviceAlive(deviceID) { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return isDeviceAlive(deviceID)
    }

    private func isDeviceAlive(_ deviceID: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var alive: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &alive) == noErr && alive != 0
    }

    private func destroyTapResources() {
        if aggregateID != 0 {
            let status = AudioHardwareDestroyAggregateDevice(aggregateID)
            if status != noErr {
                AppLog.audio.error("Failed to destroy aggregate: \(status, privacy: .public)")
            }
            aggregateID = 0
        }
        if tapID != 0 {
            let status = AudioHardwareDestroyProcessTap(tapID)
            if status != noErr {
                AppLog.audio.error("Failed to destroy process tap: \(status, privacy: .public)")
            }
            tapID = 0
        }
    }
}
