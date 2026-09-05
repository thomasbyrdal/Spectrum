import Foundation
import Observation

@MainActor
@Observable
final class AudioDeviceViewModel {
    private let manager: AudioDeviceManager

    var physicalDevices: [AudioDevice] = []
    var processes: [AudioProcess] = []
    var statusMessage: String?

    init(manager: AudioDeviceManager) {
        self.manager = manager
        refresh()
    }

    func refresh() {
        physicalDevices = manager.inputDevices()
        processes = manager.audioProcesses()
        if physicalDevices.isEmpty {
            statusMessage = "No audio input devices available."
        } else {
            statusMessage = nil
        }
    }

    /// Live Core Audio snapshot for the Input menu. Call this when the menu opens
    /// so idle processes are not left over from the last enumeration.
    func livePhysicalDevices() -> [AudioDevice] {
        manager.inputDevices()
    }

    func liveRunningProcesses() -> [AudioProcess] {
        manager.audioProcesses().filter(\.isRunningOutput)
    }

    func startListening(onChange: @escaping () -> Void) {
        manager.startListening(
            onChange: {
                Task { @MainActor in
                    self.refresh()
                    onChange()
                }
            },
            onDeviceDead: { _ in
                Task { @MainActor in
                    self.refresh()
                    onChange()
                }
            }
        )
    }

    func stopListening() {
        manager.stopListening()
    }

    func defaultPhysicalDevice() -> AudioDevice? {
        manager.defaultInput() ?? physicalDevices.first
    }

    func deviceStillAvailable(_ device: AudioDevice) -> Bool {
        manager.device(uid: device.uid) != nil
    }
}
