import CoreAudio
import Foundation

/// A selectable audio endpoint. Physical devices come from Core Audio;
/// test-signal, system-audio, and per-process sources are first-class too.
struct AudioDevice: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case physical
        case testSignal
        case systemAudio
        case application(pid: pid_t)
    }

    /// Core Audio object ID. Synthetic sources use `0`.
    let objectID: AudioObjectID
    let uid: String
    let name: String
    let sampleRate: Double
    let inputChannelCount: Int
    let kind: Kind
    /// `true` when the device currently exposes at least one input stream.
    let hasInput: Bool

    var id: String { uid }

    var sampleRateDisplay: String {
        String(format: "%.1f kHz", sampleRate / 1000.0)
    }

    var channelDisplay: String {
        inputChannelCount == 1 ? "1 channel" : "\(inputChannelCount) channels"
    }

    static func testSignal(sampleRate: Double = 48_000) -> AudioDevice {
        AudioDevice(
            objectID: 0,
            uid: "spectrum.test-signal",
            name: "Test Signal",
            sampleRate: sampleRate,
            inputChannelCount: 1,
            kind: .testSignal,
            hasInput: true
        )
    }

    static func systemAudio(sampleRate: Double = 48_000) -> AudioDevice {
        AudioDevice(
            objectID: 0,
            uid: "spectrum.system-audio",
            name: "System Audio",
            sampleRate: sampleRate,
            inputChannelCount: 2,
            kind: .systemAudio,
            hasInput: true
        )
    }
}

/// A running (or recently running) process that Core Audio can tap.
struct AudioProcess: Identifiable, Hashable, Sendable {
    let objectID: AudioObjectID
    let pid: pid_t
    let bundleID: String?
    let name: String
    let isRunningOutput: Bool

    var id: AudioObjectID { objectID }

    var displayName: String {
        if let bundleID, !bundleID.isEmpty {
            return "\(name)  ·  \(bundleID)"
        }
        return name
    }
}
