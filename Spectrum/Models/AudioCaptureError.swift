import Foundation

enum AudioCaptureError: LocalizedError, Equatable {
    case noInputDevices
    case unableToStart(String)
    case deviceDisconnected
    case microphonePermissionRequired
    case deviceHasNoInput
    case sampleRateConfigurationFailed
    case systemAudioUnavailable
    case tapPermissionRequired
    case cancelled

    var errorDescription: String? {
        switch self {
        case .noInputDevices:
            return "No audio input devices available."
        case .unableToStart(let reason):
            return reason.isEmpty ? "Unable to start audio capture." : reason
        case .deviceDisconnected:
            return "Audio input disconnected."
        case .microphonePermissionRequired:
            return "Microphone permission required."
        case .deviceHasNoInput:
            return "Selected device does not provide an input stream."
        case .sampleRateConfigurationFailed:
            return "Sample rate could not be configured."
        case .systemAudioUnavailable:
            return "System audio capture is unavailable on this macOS configuration."
        case .tapPermissionRequired:
            return "Screen Recording permission is required to capture system or application audio."
        case .cancelled:
            return "Audio capture was cancelled."
        }
    }
}
