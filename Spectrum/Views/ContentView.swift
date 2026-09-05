import SwiftUI

struct ContentView: View {
    @Bindable var viewModel: SpectrumViewModel

    private let headerHeight: CGFloat = 52
    private let controlBarHeight: CGFloat = 86
    private let statusHeight: CGFloat = 72

    var body: some View {
        VStack(spacing: 0) {
            header
                .frame(height: headerHeight)
            ControlBarView(viewModel: viewModel)
                .frame(height: controlBarHeight)
            SpectrumDisplayView(
                left: viewModel.spectrum,
                right: viewModel.displaysStereoSpectrum ? viewModel.spectrumRight : nil,
                configuration: viewModel.configuration
            )
            .equatable()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .layoutPriority(1)
            StatusView(viewModel: viewModel)
                .frame(height: statusHeight)
        }
        .background(SpectrumTheme.background)
        .frame(minWidth: 1080, minHeight: 540)
        .background(WindowTitleSync(title: viewModel.nowPlaying.windowTitle))
        .onAppear { viewModel.start() }
        .onDisappear { viewModel.stop() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("Spectrum")
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundStyle(SpectrumTheme.textPrimary)
            Text("Real-time analyzer")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(SpectrumTheme.textSecondary)
            Spacer(minLength: 12)
            if viewModel.nowPlaying.isAvailable {
                MarqueeText(text: viewModel.nowPlaying.displayTitle)
                NowPlayingTransportButtons(controller: viewModel.nowPlaying)
            }
            HStack(spacing: 8) {
                Circle()
                    .fill(viewModel.isRunning ? SpectrumTheme.running : SpectrumTheme.stopped)
                    .frame(width: 8, height: 8)
                    .shadow(color: viewModel.isRunning ? SpectrumTheme.running.opacity(0.8) : .clear, radius: 4)
                Text(viewModel.isRunning ? "Running" : "Stopped")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(viewModel.isRunning ? SpectrumTheme.running : SpectrumTheme.stopped)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.white.opacity(0.04), in: Capsule())
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(SpectrumTheme.panel)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(SpectrumTheme.panelStroke)
                .frame(height: 1)
        }
    }
}

struct NowPlayingTransportButtons: View {
    var controller: NowPlayingController

    var body: some View {
        HStack(spacing: 6) {
            transportButton("backward.end.fill", "Previous", action: controller.previous)
            transportButton("play.fill", "Play", action: controller.play)
            transportButton("stop.fill", "Stop", action: controller.stop)
            transportButton("forward.end.fill", "Next", action: controller.next)
        }
    }

    private func transportButton(_ systemName: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 28, height: 22)
        }
        .buttonStyle(.plain)
        .foregroundStyle(SpectrumTheme.textPrimary)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.white.opacity(0.10))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color.white.opacity(0.22), lineWidth: 1)
        }
        .help(label)
        .accessibilityLabel(label)
    }
}

/// SwiftUI's navigation title often does not refresh on macOS when the track changes.
private struct WindowTitleSync: NSViewRepresentable {
    let title: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.isHidden = true
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            nsView.window?.title = title
        }
    }
}
