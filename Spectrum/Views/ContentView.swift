import AppKit
import SwiftUI

struct ContentView: View {
    @Bindable var viewModel: SpectrumViewModel
    @State private var isKeyWindow = true

    private let headerHeight: CGFloat = 52
    private let controlBarHeight: CGFloat = 86
    private let statusHeight: CGFloat = 72

    private var showChrome: Bool {
        isKeyWindow
    }

    var body: some View {
        VStack(spacing: 0) {
            if showChrome {
                header
                    .frame(height: headerHeight)
                ControlBarView(viewModel: viewModel)
                    .frame(height: controlBarHeight)
            }
            SpectrumDisplayView(
                left: viewModel.spectrum,
                right: viewModel.displaysStereoSpectrum ? viewModel.spectrumRight : nil,
                configuration: viewModel.configuration,
                layout: viewModel.stereoSpectrumLayout
            )
            .equatable()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .layoutPriority(1)
            if showChrome {
                StatusView(viewModel: viewModel)
                    .frame(height: statusHeight)
            }
        }
        .background(SpectrumTheme.background)
        .frame(minWidth: 1080, minHeight: 540)
        .background(WindowTitleSync(title: viewModel.nowPlaying.windowTitle))
        .background(
            WindowAlwaysOnTopSync(
                enabled: viewModel.alwaysOnTop,
                isKeyWindow: $isKeyWindow,
                hideChrome: !showChrome
            )
        )
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
                if let artwork = viewModel.nowPlaying.artworkImage {
                    AlbumArtChip(image: artwork)
                }
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

private struct AlbumArtChip: View {
    let image: NSImage

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fill)
            .frame(width: 22, height: 22)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(Color.white.opacity(0.18), lineWidth: 0.8)
            }
            .accessibilityHidden(true)
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

private struct WindowAlwaysOnTopSync: NSViewRepresentable {
    let enabled: Bool
    @Binding var isKeyWindow: Bool
    let hideChrome: Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.isHidden = true
        context.coordinator.install(isKeyWindow: $isKeyWindow)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.isKeyWindow = $isKeyWindow
        context.coordinator.window = nsView.window
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            context.coordinator.window = window
            AlwaysOnTopSupport.registerMainWindow(window)
            window.level = enabled ? .floating : .normal
            context.coordinator.applyHUD(window, hideChrome: hideChrome)
            let key = window.isKeyWindow
            if isKeyWindow != key {
                isKeyWindow = key
            }
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.teardown()
        if let window = nsView.window {
            coordinator.applyHUD(window, hideChrome: false)
            window.level = .normal
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        var isKeyWindow: Binding<Bool> = .constant(true)
        weak var window: NSWindow?
        private var observers: [NSObjectProtocol] = []

        func install(isKeyWindow: Binding<Bool>) {
            self.isKeyWindow = isKeyWindow
            guard observers.isEmpty else { return }
            let center = NotificationCenter.default
            observers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] notification in
                self?.handleKeyChange(notification, isKey: true)
            })
            observers.append(center.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { [weak self] notification in
                self?.handleKeyChange(notification, isKey: false)
            })
        }

        private func handleKeyChange(_ notification: Notification, isKey: Bool) {
            guard let window = notification.object as? NSWindow else { return }
            guard window === self.window else { return }
            isKeyWindow.wrappedValue = isKey
        }

        func applyHUD(_ window: NSWindow, hideChrome: Bool) {
            if hideChrome {
                window.titleVisibility = .hidden
                window.titlebarAppearsTransparent = true
                if !window.styleMask.contains(.fullSizeContentView) {
                    window.styleMask.insert(.fullSizeContentView)
                }
                window.standardWindowButton(.closeButton)?.isHidden = true
                window.standardWindowButton(.miniaturizeButton)?.isHidden = true
                window.standardWindowButton(.zoomButton)?.isHidden = true
            } else {
                window.titleVisibility = .visible
                window.titlebarAppearsTransparent = false
                window.styleMask.remove(.fullSizeContentView)
                window.standardWindowButton(.closeButton)?.isHidden = false
                window.standardWindowButton(.miniaturizeButton)?.isHidden = false
                window.standardWindowButton(.zoomButton)?.isHidden = false
            }
        }

        func teardown() {
            for observer in observers {
                NotificationCenter.default.removeObserver(observer)
            }
            observers.removeAll()
        }
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
