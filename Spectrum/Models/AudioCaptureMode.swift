import Foundation

enum AudioCaptureMode: String, CaseIterable, Identifiable, Sendable {
    case testSignal = "Test Signal"
    case physical = "Audio Input"
    case systemAudio = "System Audio"
    case application = "Application"

    var id: String { rawValue }
}

enum TestSignalKind: String, CaseIterable, Identifiable, Sendable {
    case sine1k = "Sine 1 kHz"
    case sine100 = "Sine 100 Hz"
    case sine10k = "Sine 10 kHz"
    case sweep = "Sweep"
    case whiteNoise = "White Noise"
    case pinkNoise = "Pink Noise"
    case multiTone = "Multi-tone"

    var id: String { rawValue }
}

/// Unified picker identity for every source the UI can select.
enum AudioSource: Hashable, Identifiable, Sendable {
    case testSignal(TestSignalKind)
    case physical(AudioDevice)
    case systemAudio
    case application(AudioProcess)

    var id: String {
        switch self {
        case .testSignal(let kind):
            return "test.\(kind.rawValue)"
        case .physical(let device):
            return "device.\(device.uid)"
        case .systemAudio:
            return "system"
        case .application(let process):
            return "process.\(process.objectID)"
        }
    }

    var displayName: String {
        switch self {
        case .testSignal(let kind):
            return "Test Signal — \(kind.rawValue)"
        case .physical(let device):
            return device.name
        case .systemAudio:
            return "System Audio"
        case .application(let process):
            return process.name
        }
    }
}
