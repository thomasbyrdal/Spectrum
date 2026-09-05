import SwiftUI

/// Single-line label that slowly shuttles overflow text left, then right.
struct MarqueeText: View {
    let text: String
    var font: Font = .system(size: 12, weight: .medium)
    var color: Color = SpectrumTheme.textPrimary
    var maxWidth: CGFloat = 360

    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
    @State private var offset: CGFloat = 0

    private var overflows: Bool {
        containerWidth > 0 && textWidth > containerWidth + 1
    }

    var body: some View {
        Text(text)
            .font(font)
            .foregroundStyle(color)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .background(WidthProbe<TextWidthKey>())
            .offset(x: offset)
            .frame(maxWidth: maxWidth, alignment: overflows ? .leading : .trailing)
            .clipped()
            .background(WidthProbe<ContainerWidthKey>())
            .onPreferenceChange(TextWidthKey.self) { textWidth = $0 }
            .onPreferenceChange(ContainerWidthKey.self) { containerWidth = $0 }
            .task(id: animationToken) {
                await runMarquee()
            }
            .accessibilityLabel(text)
    }

    private var animationToken: String {
        "\(text)|\(Int(textWidth.rounded()))|\(Int(containerWidth.rounded()))"
    }

    private func runMarquee() async {
        offset = 0
        guard overflows else { return }

        let distance = textWidth - containerWidth
        let travel = max(Double(distance / Self.pointsPerSecond), 1.2)

        while !Task.isCancelled {
            withAnimation(.linear(duration: travel)) {
                offset = -distance
            }
            try? await Task.sleep(for: .seconds(travel))
            guard !Task.isCancelled else { return }

            try? await Task.sleep(for: Self.pause)
            guard !Task.isCancelled else { return }

            withAnimation(.linear(duration: travel)) {
                offset = 0
            }
            try? await Task.sleep(for: .seconds(travel))
            guard !Task.isCancelled else { return }

            try? await Task.sleep(for: Self.pause)
        }
    }

    private static let pointsPerSecond: CGFloat = 28
    private static let pause: Duration = .seconds(10)
}

private struct TextWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct ContainerWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct WidthProbe<Key: PreferenceKey>: View where Key.Value == CGFloat {
    var body: some View {
        GeometryReader { proxy in
            Color.clear.preference(key: Key.self, value: proxy.size.width)
        }
    }
}
