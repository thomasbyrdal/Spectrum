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
            SpectrumView(data: viewModel.spectrum, configuration: viewModel.configuration)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)
            StatusView(viewModel: viewModel)
                .frame(height: statusHeight)
        }
        .background(SpectrumTheme.background)
        .frame(minWidth: 1080, minHeight: 540)
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
            Spacer()
            HStack(spacing: 8) {
                Circle()
                    .fill(viewModel.isRunning ? SpectrumTheme.running : SpectrumTheme.stopped)
                    .frame(width: 8, height: 8)
                    .shadow(color: viewModel.isRunning ? SpectrumTheme.running.opacity(0.8) : .clear, radius: 4)
                Text(viewModel.isRunning ? "Running" : "Stopped")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(viewModel.isRunning ? SpectrumTheme.running : SpectrumTheme.textSecondary)
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
