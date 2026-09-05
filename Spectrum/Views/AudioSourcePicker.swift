import AppKit
import SwiftUI

struct AudioSourcePicker: View {
    @Bindable var viewModel: SpectrumViewModel
    @State private var menuGeneration = 0

    var body: some View {
        Menu {
            let _ = menuGeneration
            let devices = viewModel.devices.livePhysicalDevices()
            let processes = viewModel.devices.liveRunningProcesses()

            Picker("Input", selection: sourceBinding) {
                Section("Test Signal") {
                    ForEach(TestSignalKind.allCases) { kind in
                        Text("Test Signal — \(kind.rawValue)")
                            .tag(AudioSource.testSignal(kind))
                    }
                }

                if !devices.isEmpty {
                    Section("Audio Input") {
                        ForEach(devices) { device in
                            Text("\(device.name)  ·  \(device.sampleRateDisplay)")
                                .tag(AudioSource.physical(device))
                        }
                    }
                }

                Section("System Audio") {
                    Text("System Audio")
                        .tag(AudioSource.systemAudio)
                    ForEach(processes) { process in
                        Text(process.name)
                            .tag(AudioSource.application(process))
                    }
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()

            if devices.isEmpty {
                Section("Audio Input") {
                    Text("No input devices")
                }
            }
        } label: {
            pickerLabel(title: "Input", value: viewModel.source.displayName)
                .background {
                    MenuOpenRefreshHook {
                        viewModel.devices.refresh()
                        menuGeneration += 1
                    }
                }
        }
        .menuStyle(.borderlessButton)
        .tint(SpectrumTheme.textPrimary)
    }

    private var sourceBinding: Binding<AudioSource> {
        Binding(
            get: { viewModel.source },
            set: { viewModel.select($0) }
        )
    }
}

struct ResolutionPicker: View {
    @Bindable var viewModel: SpectrumViewModel

    var body: some View {
        HStack(spacing: 8) {
            compactMenu(title: "Bars", value: "\(viewModel.configuration.barCount)") {
                Picker("Bars", selection: barCountBinding) {
                    ForEach(BarCount.allCases) { count in
                        Text("\(count.rawValue)").tag(count.rawValue)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }

            compactMenu(title: "FFT", value: "\(viewModel.configuration.fftSize)") {
                Picker("FFT", selection: fftSizeBinding) {
                    ForEach(FFTSize.allCases) { size in
                        Text(size.label).tag(size.rawValue)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }

            compactMenu(title: "Window", value: viewModel.configuration.windowFunction.rawValue) {
                Picker("Window", selection: windowBinding) {
                    ForEach(WindowFunction.allCases) { window in
                        Text(window.rawValue).tag(window)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }

            compactMenu(title: "Style", value: viewModel.configuration.barStyle.rawValue) {
                Picker("Style", selection: barStyleBinding) {
                    ForEach(BarStyle.allCases) { style in
                        Text(style.rawValue).tag(style)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }

            compactMenu(title: "Peak", value: viewModel.configuration.peakHoldMode.rawValue) {
                Picker("Peak", selection: peakHoldModeBinding) {
                    ForEach(PeakHoldMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
        }
    }

    private var barCountBinding: Binding<Int> {
        Binding(
            get: { viewModel.configuration.barCount },
            set: { newValue in
                viewModel.updateConfiguration { $0.barCount = newValue }
            }
        )
    }

    private var fftSizeBinding: Binding<Int> {
        Binding(
            get: { viewModel.configuration.fftSize },
            set: { newValue in
                viewModel.updateConfiguration { $0.fftSize = newValue }
            }
        )
    }

    private var windowBinding: Binding<WindowFunction> {
        Binding(
            get: { viewModel.configuration.windowFunction },
            set: { newValue in
                viewModel.updateConfiguration { $0.windowFunction = newValue }
            }
        )
    }

    private var barStyleBinding: Binding<BarStyle> {
        Binding(
            get: { viewModel.configuration.barStyle },
            set: { newValue in
                viewModel.updateConfiguration { $0.barStyle = newValue }
            }
        )
    }

    private var peakHoldModeBinding: Binding<PeakHoldMode> {
        Binding(
            get: { viewModel.configuration.peakHoldMode },
            set: { newValue in
                viewModel.updateConfiguration { $0.peakHoldMode = newValue }
            }
        )
    }
}

func pickerLabel(title: String, value: String) -> some View {
    HStack(spacing: 8) {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(SpectrumTheme.textSecondary)
            .tracking(0.8)
        Text(value)
            .font(.system(size: 12, weight: .medium, design: .default))
            .foregroundStyle(SpectrumTheme.textPrimary)
            .lineLimit(1)
        Image(systemName: "chevron.down")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(SpectrumTheme.textSecondary)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 7)
    .frame(height: 32)
    .background(SpectrumTheme.panel, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    .overlay(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .stroke(SpectrumTheme.panelStroke, lineWidth: 1)
    )
}

func compactMenu<Content: View>(title: String, value: String, @ViewBuilder content: () -> Content) -> some View {
    Menu {
        content()
    } label: {
        pickerLabel(title: title, value: value)
    }
    .menuStyle(.borderlessButton)
    .tint(SpectrumTheme.textPrimary)
}

/// Runs `onOpen` on mouse-down inside the Input control, before the menu is built.
private struct MenuOpenRefreshHook: NSViewRepresentable {
    var onOpen: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.install(view: view, onOpen: onOpen)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.view = nsView
        context.coordinator.onOpen = onOpen
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.teardown()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        var onOpen: () -> Void = {}
        weak var view: NSView?
        private var monitor: Any?

        func install(view: NSView, onOpen: @escaping () -> Void) {
            self.view = view
            self.onOpen = onOpen
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                self?.handleMouseDown(event)
                return event
            }
        }

        func handleMouseDown(_ event: NSEvent) {
            guard let view, event.window === view.window else { return }
            let point = view.convert(event.locationInWindow, from: nil)
            guard view.bounds.contains(point) else { return }
            onOpen()
        }

        func teardown() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }
    }
}
