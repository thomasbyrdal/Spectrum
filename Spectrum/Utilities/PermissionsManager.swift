import AppKit
import AVFAudio
import CoreGraphics
import Foundation
import Observation
import OSLog

@MainActor
@Observable
final class PermissionsManager {
    enum MicrophoneState: String {
        case granted = "Granted"
        case denied = "Denied"
        case required = "Required"
        case undetermined = "Not requested"
    }

    private(set) var microphoneState: MicrophoneState = .undetermined
    private(set) var screenCaptureAllowed = false

    init() {
        refresh()
    }

    func refresh() {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            microphoneState = .granted
        case .denied:
            microphoneState = .denied
        case .undetermined:
            fallthrough
        @unknown default:
            microphoneState = .undetermined
        }
        screenCaptureAllowed = CGPreflightScreenCaptureAccess()
    }

    func requestMicrophone() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                Task { @MainActor in
                    self.microphoneState = granted ? .granted : .denied
                    AppLog.permissions.info("Microphone permission: \(granted, privacy: .public)")
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    @discardableResult
    func requestScreenCapture() -> Bool {
        let allowed = CGRequestScreenCaptureAccess()
        screenCaptureAllowed = allowed || CGPreflightScreenCaptureAccess()
        return screenCaptureAllowed
    }

    func openMicrophoneSettings() {
        openPrivacyPane("Privacy_Microphone")
    }

    func openScreenRecordingSettings() {
        openPrivacyPane("Privacy_ScreenCapture")
    }

    private func openPrivacyPane(_ pane: String) {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")
        if let url {
            NSWorkspace.shared.open(url)
        }
    }
}
