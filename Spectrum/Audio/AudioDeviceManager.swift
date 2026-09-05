import AppKit
import CoreAudio
import Foundation
import OSLog

/// Enumerates Core Audio hardware devices and tap-able processes.
/// Device names are never hard-coded; they come from the system.
final class AudioDeviceManager: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dk.byrdal.Spectrum.devices")
    private var hardwareListener: AudioObjectPropertyListenerBlock?
    private var processListener: AudioObjectPropertyListenerBlock?
    private var disconnectionHandler: ((AudioObjectID) -> Void)?

    func startListening(onChange: @escaping () -> Void, onDeviceDead: @escaping (AudioObjectID) -> Void) {
        disconnectionHandler = onDeviceDead
        addListener(
            selector: kAudioHardwarePropertyDevices,
            stored: &hardwareListener,
            handler: onChange
        )
        addListener(
            selector: kAudioHardwarePropertyProcessObjectList,
            stored: &processListener,
            handler: onChange
        )
    }

    func stopListening() {
        removeListener(selector: kAudioHardwarePropertyDevices, stored: &hardwareListener)
        removeListener(selector: kAudioHardwarePropertyProcessObjectList, stored: &processListener)
        disconnectionHandler = nil
    }

    func inputDevices() -> [AudioDevice] {
        hardwareDevices().compactMap { device in
            let channels = inputChannelCount(device.id)
            guard channels > 0 else { return nil }
            if (try? device.isHidden) == true { return nil }
            let name = (try? device.name) ?? "Audio Device"
            let uid = (try? device.uid) ?? String(device.id)
            let rate = (try? device.actualSampleRate) ?? (try? device.nominalSampleRate) ?? 48_000
            return AudioDevice(
                objectID: device.id,
                uid: uid,
                name: name,
                sampleRate: rate,
                inputChannelCount: channels,
                kind: .physical,
                hasInput: true
            )
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func defaultInput() -> AudioDevice? {
        if let device = try? AudioHardwareSystem.shared.defaultInputDevice {
            return inputDevices().first { $0.objectID == device.id }
        }
        return inputDevices().first
    }

    func processObjectIDs(relatedTo process: AudioProcess) -> [AudioObjectID] {
        var ids: Set<AudioObjectID> = [process.objectID]
        if let bundle = process.bundleID, !bundle.isEmpty {
            for item in audioProcesses() where item.bundleID == bundle {
                ids.insert(item.objectID)
            }
        }
        return Array(ids)
    }

    func device(uid: String) -> AudioDevice? {
        inputDevices().first { $0.uid == uid }
    }

    func isAlive(_ objectID: AudioObjectID) -> Bool {
        guard objectID != 0 else { return true }
        let device = AudioHardwareDevice(id: objectID)
        return (try? device.isAlive) ?? false
    }

    func audioProcesses() -> [AudioProcess] {
        guard let processes = try? AudioHardwareSystem.shared.processes else { return [] }
        return processes.compactMap { process in
            let pid = (try? process.pid) ?? 0
            guard pid != 0, pid != getpid() else { return nil }
            let runningOutput = (try? process.isRunningOutput) ?? false
            let bundleID = try? process.bundleID
            let name = processDisplayName(pid: pid, bundleID: bundleID, fallback: (try? process.name) ?? "Process")
            return AudioProcess(
                objectID: process.id,
                pid: pid,
                bundleID: bundleID,
                name: name,
                isRunningOutput: runningOutput
            )
        }
        .sorted { lhs, rhs in
            if lhs.isRunningOutput != rhs.isRunningOutput {
                return lhs.isRunningOutput && !rhs.isRunningOutput
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private func hardwareDevices() -> [AudioHardwareDevice] {
        (try? AudioHardwareSystem.shared.devices) ?? []
    }

    private func inputChannelCount(_ objectID: AudioObjectID) -> Int {
        let device = AudioHardwareDevice(id: objectID)
        if let buffers = try? device.inputStreamConfiguration {
            let channels = buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
            if channels > 0 { return channels }
        }
        return streamChannelCount(objectID: objectID, scope: kAudioDevicePropertyScopeInput)
    }

    private func streamChannelCount(objectID: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &dataSize)
        guard status == noErr, dataSize > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(dataSize), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        var size = dataSize
        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private func processDisplayName(pid: pid_t, bundleID: String?, fallback: String) -> String {
        if let app = NSRunningApplication(processIdentifier: pid), let name = app.localizedName, !name.isEmpty {
            return name
        }
        if let bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return url.deletingPathExtension().lastPathComponent
        }
        return fallback
    }

    private func addListener(
        selector: AudioObjectPropertySelector,
        stored: inout AudioObjectPropertyListenerBlock?,
        handler: @escaping () -> Void
    ) {
        removeListener(selector: selector, stored: &stored)
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            handler()
        }
        stored = block
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            queue,
            block
        )
        if status != noErr {
            AppLog.audio.error("Failed to add device listener \(selector, privacy: .public): \(status, privacy: .public)")
        }
    }

    private func removeListener(selector: AudioObjectPropertySelector, stored: inout AudioObjectPropertyListenerBlock?) {
        guard let block = stored else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            queue,
            block
        )
        stored = nil
    }
}
