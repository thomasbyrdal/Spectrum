import SwiftUI

struct ControlBarView: View {
    @Bindable var viewModel: SpectrumViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                AudioSourcePicker(viewModel: viewModel)
                ResolutionPicker(viewModel: viewModel)
                Spacer(minLength: 8)
                if viewModel.stereoSpectrumAvailable {
                    stereoChip
                }
                rangeChip
            }
            .frame(height: 36)

            messageRow
                .frame(height: 22)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(SpectrumTheme.panel.opacity(0.92))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(SpectrumTheme.panelStroke)
                .frame(height: 1)
        }
    }

    @ViewBuilder
    private var messageRow: some View {
        if let error = viewModel.errorMessage {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(SpectrumTheme.warning)
                Text(error)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(SpectrumTheme.warning)
                    .lineLimit(1)
                Spacer(minLength: 8)
                permissionButtons
            }
        } else if let disconnected = viewModel.disconnectedMessage {
            Text(disconnected)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(SpectrumTheme.clip)
                .lineLimit(1)
        } else {
            Color.clear
        }
    }

    private var stereoChip: some View {
        HStack(spacing: 8) {
            Text("Show stereo spectrum")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(SpectrumTheme.textSecondary)
                .tracking(0.3)
            Toggle("Show stereo spectrum", isOn: $viewModel.showStereoSpectrum)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(height: 32)
        .background(SpectrumTheme.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var rangeChip: some View {
        HStack(spacing: 6) {
            Text("RANGE")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(SpectrumTheme.textSecondary)
                .tracking(0.8)
            Text(viewModel.displayFrequencyRange)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(SpectrumTheme.textPrimary)
                .lineLimit(1)
            Text("Nyquist limited")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(SpectrumTheme.warning)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(SpectrumTheme.warning.opacity(0.15), in: Capsule())
                .opacity(viewModel.nyquistLimited ? 1 : 0)
                .accessibilityHidden(!viewModel.nyquistLimited)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(height: 32)
        .background(SpectrumTheme.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    @ViewBuilder
    private var permissionButtons: some View {
        if viewModel.errorMessage == AudioCaptureError.microphonePermissionRequired.localizedDescription {
            Button("Open System Settings") {
                viewModel.permissions.openMicrophoneSettings()
            }
            .buttonStyle(.bordered)
            Button("Request Access") {
                viewModel.requestMicrophoneAndRetry()
            }
            .buttonStyle(.borderedProminent)
        } else if viewModel.errorMessage == AudioCaptureError.tapPermissionRequired.localizedDescription {
            Button("Open System Settings") {
                viewModel.permissions.openScreenRecordingSettings()
            }
            .buttonStyle(.bordered)
            Button("Request Access") {
                viewModel.requestScreenCaptureAndRetry()
            }
            .buttonStyle(.borderedProminent)
        }
    }
}
