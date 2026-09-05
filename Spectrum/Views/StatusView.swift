import SwiftUI

struct StatusView: View {
    @Bindable var viewModel: SpectrumViewModel

    var body: some View {
        HStack(spacing: 18) {
            statusItem("Input", viewModel.statusDeviceName)
            statusItem("Sample Rate", String(format: "%.1f kHz", viewModel.sampleRate / 1000))
            statusItem("Channels", viewModel.channelCount == 1 ? "1" : "\(viewModel.channelCount)")
            statusItem("FFT", "\(viewModel.configuration.fftSize)")
            statusItem("Resolution", String(format: "%.2f Hz", viewModel.frequencyResolution))
            statusItem("CPU", String(format: "%.0f%%", viewModel.cpuUsage * 100))
            statusItem("FPS", String(format: "%.0f fps", viewModel.displayFrameRate))
            Spacer()
            LevelMeterView(
                peak: viewModel.spectrum.peakDBFS,
                rms: viewModel.spectrum.rmsDBFS,
                clipping: viewModel.spectrum.isClipping,
                floor: viewModel.configuration.minimumDB
            )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SpectrumTheme.panel.opacity(0.92))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(SpectrumTheme.panelStroke)
                .frame(height: 1)
        }
    }

    private func statusItem(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .foregroundStyle(SpectrumTheme.textSecondary)
                .tracking(0.7)
            Text(value)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(SpectrumTheme.textPrimary)
                .lineLimit(1)
        }
    }
}

struct LevelMeterView: View {
    let peak: Float
    let rms: Float
    let clipping: Bool
    let floor: Float

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .trailing, spacing: 2) {
                Text("INPUT")
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(SpectrumTheme.textSecondary)
                    .tracking(0.7)
                Text(format(peak))
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(clipping ? SpectrumTheme.clip : SpectrumTheme.accent)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }

            VStack(alignment: .trailing, spacing: 4) {
                meter(value: peak, forceFull: clipping)
                meter(value: rms)
                HStack(spacing: 10) {
                    Text("Peak \(format(peak))")
                    Text("RMS \(format(rms))")
                }
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(SpectrumTheme.textSecondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            }
            .frame(width: 240, alignment: .trailing)
        }
    }

    private static let ledCount = 12

    private func meter(value: Float, forceFull: Bool = false) -> some View {
        let litCount = forceFull ? Self.ledCount : litLEDCount(normalized(value))
        return HStack(spacing: 2) {
            ForEach(0..<Self.ledCount, id: \.self) { index in
                LEDSegment(color: Self.ledColor(at: index), isOn: index < litCount)
            }
        }
        .frame(height: 9)
    }

    private func litLEDCount(_ normalized: Float) -> Int {
        if normalized <= 0 { return 0 }
        return min(Self.ledCount, Int((normalized * Float(Self.ledCount)).rounded(.up)))
    }

    private static func ledColor(at index: Int) -> Color {
        switch index {
        case 0..<5: SpectrumTheme.meterLEDGreen
        case 5..<10: SpectrumTheme.meterLEDYellow
        default: SpectrumTheme.meterLEDRed
        }
    }

    private func normalized(_ db: Float) -> Float {
        let clamped = min(max(db, floor), 0)
        return (clamped - floor) / max(0 - floor, 1)
    }

    private func format(_ db: Float) -> String {
        if db <= floor + 0.1 { return "— dBFS" }
        return String(format: "%+.1f dBFS", db)
    }
}

private struct LEDSegment: View {
    let color: Color
    let isOn: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
            .fill(
                LinearGradient(
                    colors: isOn
                        ? [color, color.opacity(0.72)]
                        : [color.opacity(0.16), color.opacity(0.07)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .overlay {
                if isOn {
                    RoundedRectangle(cornerRadius: 1.2, style: .continuous)
                        .fill(Color.white.opacity(0.28))
                        .padding(.horizontal, 1.6)
                        .padding(.vertical, 2.6)
                        .offset(y: -1.2)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .stroke(Color.black.opacity(0.45), lineWidth: 0.6)
            }
            .shadow(color: isOn ? color.opacity(0.55) : .clear, radius: 1.6)
    }
}
