import SwiftUI

struct SpectrumDisplayView: View, Equatable {
    let left: SpectrumData
    let right: SpectrumData?
    let configuration: SpectrumConfiguration
    var layout: StereoSpectrumLayout = .sideBySide

    var body: some View {
        if let right {
            switch layout {
            case .sideBySide:
                HStack(spacing: 0) {
                    SpectrumView(data: left, configuration: configuration, channelLabel: "L")
                    stereoDivider(vertical: true)
                    SpectrumView(data: right, configuration: configuration, channelLabel: "R")
                }
            case .stacked:
                VStack(spacing: 0) {
                    SpectrumView(data: right, configuration: configuration, channelLabel: "R")
                    stereoDivider(vertical: false)
                    SpectrumView(data: left, configuration: configuration, channelLabel: "L")
                }
            }
        } else {
            SpectrumView(data: left, configuration: configuration)
        }
    }

    private func stereoDivider(vertical: Bool) -> some View {
        Rectangle()
            .fill(SpectrumTheme.panelStroke)
            .frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
    }
}

// This is where the fun happens...
//
struct SpectrumView: View, Equatable {
    let data: SpectrumData
    let configuration: SpectrumConfiguration
    var channelLabel: String? = nil

    var body: some View {
        Canvas { context, size in
            let plot = plotRect(in: size)
            if configuration.showGrid {
                drawGrid(context: context, plot: plot)
            }
            drawBars(context: context, plot: plot)
            drawFrequencyAxis(context: context, plot: plot, canvasSize: size)
            drawDecibelAxis(context: context, plot: plot)
            drawChannelLabel(context: context, plot: plot)
        }
        .background(SpectrumTheme.background)
    }

    private func drawChannelLabel(context: GraphicsContext, plot: CGRect) {
        guard let channelLabel, !channelLabel.isEmpty else { return }
        let resolved = context.resolve(
            Text(channelLabel)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundColor(SpectrumTheme.textSecondary)
        )
        context.draw(
            resolved,
            at: CGPoint(x: plot.minX + 8, y: plot.minY + 10),
            anchor: .leading
        )
    }

    private func plotRect(in size: CGSize) -> CGRect {
        CGRect(x: 56, y: 16, width: max(size.width - 72, 10), height: max(size.height - 48, 10))
    }

    private func barPlot(in plot: CGRect) -> CGRect {
        guard configuration.barReflectionEnabled else { return plot }
        return CGRect(x: plot.minX, y: plot.minY, width: plot.width, height: max(plot.height - 16, 10))
    }

    private func normalizedLevel(_ db: Float) -> Double {
        let minDB = configuration.minimumDB
        let maxDB = configuration.maximumDB
        let clamped = min(max(db, minDB), maxDB)
        return Double((clamped - minDB) / max(maxDB - minDB, 1))
    }

    private var displayMin: Float { configuration.minimumFrequency }
    private var displayMax: Float {
        min(configuration.maximumFrequency, data.nyquist > 0 ? data.nyquist : configuration.maximumFrequency)
    }

    private func drawGrid(context: GraphicsContext, plot: CGRect) {
        let majors = FrequencyAxis.majorTicks(min: displayMin, max: displayMax)
        let minors = FrequencyAxis.minorTicks(min: displayMin, max: displayMax)

        for frequency in minors where !majors.contains(frequency) {
            let x = xPosition(frequency: frequency, plot: plot)
            var path = Path()
            path.move(to: CGPoint(x: x, y: plot.minY))
            path.addLine(to: CGPoint(x: x, y: plot.maxY))
            context.stroke(path, with: .color(SpectrumTheme.gridMinor), lineWidth: 1)
        }

        for frequency in majors {
            let x = xPosition(frequency: frequency, plot: plot)
            var path = Path()
            path.move(to: CGPoint(x: x, y: plot.minY))
            path.addLine(to: CGPoint(x: x, y: plot.maxY))
            context.stroke(path, with: .color(SpectrumTheme.gridMajor), lineWidth: 1)
        }

        let dbMin = configuration.minimumDB
        let dbMax = configuration.maximumDB
        let steps = [0, -6, -12, -24, -36, -48, -60, -72, -84, -96, -108, -120].filter { $0 <= dbMax && $0 >= dbMin }
        for db in steps {
            let y = yPosition(db: Float(db), plot: plot)
            var path = Path()
            path.move(to: CGPoint(x: plot.minX, y: y))
            path.addLine(to: CGPoint(x: plot.maxX, y: y))
            let color = db == 0 ? SpectrumTheme.gridMajor : SpectrumTheme.gridMinor
            context.stroke(path, with: .color(color), lineWidth: db == 0 ? 1 : 0.8)
        }
    }

    private func drawBars(context: GraphicsContext, plot: CGRect) {
        let count = data.magnitudesDB.count
        guard count > 0 else { return }
        let bars = barPlot(in: plot)
        let slot = bars.width / CGFloat(count)
        let gap: CGFloat = slot > 3 ? min(1.0, slot * 0.22) : 0
        let barWidth = max(slot - gap, 0.5)

        for index in 0..<count {
            let t = Double(index) / Double(max(count - 1, 1))
            let db = data.magnitudesDB[index]
            let level = normalizedLevel(db)
            let height = barHeight(db: db, plot: bars)
            let x = bars.minX + CGFloat(index) * slot + gap / 2
            let y = bars.maxY - height
            let rect = CGRect(x: x, y: y, width: barWidth, height: max(height, 1))
            let corner = min(barWidth / 4, 1.5)
            let peakEnabled = configuration.peakHoldEnabled && index < data.peakMagnitudesDB.count
            let peakDB = peakEnabled ? data.peakMagnitudesDB[index] : 0

            if configuration.barGlowEnabled {
                drawBarGlow(
                    context: context,
                    rect: rect,
                    corner: corner,
                    normalizedFrequency: t,
                    normalizedLevel: level
                )
            }

            if peakEnabled, configuration.peakHoldStyle == .rect {
                drawPeakHoldRect(
                    context: context,
                    x: x,
                    barTop: y,
                    barWidth: barWidth,
                    corner: corner,
                    peakDB: peakDB,
                    plot: bars,
                    normalizedFrequency: t
                )
            }

            context.fill(
                Path(roundedRect: rect, cornerRadius: corner),
                with: SpectrumTheme.barShading(
                    normalizedFrequency: t,
                    normalizedLevel: level,
                    style: configuration.barStyle,
                    in: rect
                )
            )

            if configuration.barReflectionEnabled {
                drawBarReflection(
                    context: context,
                    x: x,
                    barWidth: barWidth,
                    height: height,
                    corner: corner,
                    baseline: bars.maxY,
                    floorY: plot.maxY,
                    normalizedFrequency: t,
                    normalizedLevel: level
                )
            }

            if peakEnabled, configuration.peakHoldStyle == .bar {
                drawPeakHoldBar(context: context, x: x, barWidth: barWidth, peakDB: peakDB, plot: bars)
            }
        }
    }

    private func drawBarGlow(
        context: GraphicsContext,
        rect: CGRect,
        corner: CGFloat,
        normalizedFrequency: Double,
        normalizedLevel: Double
    ) {
        guard normalizedLevel > 0.08 else { return }
        let strength = min(max((normalizedLevel - 0.08) / 0.92, 0), 1)
        let inflate = 1.6 + CGFloat(strength) * 3.2
        let glowRect = rect.insetBy(dx: -inflate * 0.35, dy: -inflate)
        let color = SpectrumTheme.barGlowColor(
            normalizedFrequency: normalizedFrequency,
            normalizedLevel: normalizedLevel,
            style: configuration.barStyle
        )
        context.fill(
            Path(roundedRect: glowRect, cornerRadius: corner + inflate * 0.4),
            with: .color(color.opacity(0.12 + 0.22 * strength))
        )
    }

    private func drawBarReflection(
        context: GraphicsContext,
        x: CGFloat,
        barWidth: CGFloat,
        height: CGFloat,
        corner: CGFloat,
        baseline: CGFloat,
        floorY: CGFloat,
        normalizedFrequency: Double,
        normalizedLevel: Double
    ) {
        let reflectionHeight = min(height * 0.18, max(floorY - baseline, 0))
        guard reflectionHeight > 0.6, normalizedLevel > 0.04 else { return }
        let rect = CGRect(x: x, y: baseline, width: barWidth, height: reflectionHeight)
        let color = SpectrumTheme.barColor(
            normalizedFrequency: normalizedFrequency,
            normalizedLevel: normalizedLevel,
            style: configuration.barStyle
        )
        context.fill(
            Path(roundedRect: rect, cornerRadius: corner),
            with: .color(color.opacity(0.18))
        )
    }

    private func drawPeakHoldBar(
        context: GraphicsContext,
        x: CGFloat,
        barWidth: CGFloat,
        peakDB: Float,
        plot: CGRect
    ) {
        let peakY = yPosition(db: peakDB, plot: plot)
        var marker = Path()
        marker.move(to: CGPoint(x: x, y: peakY))
        marker.addLine(to: CGPoint(x: x + barWidth, y: peakY))
        context.stroke(marker, with: .color(SpectrumTheme.peakMarker), lineWidth: 1.4)
    }

    private func drawPeakHoldRect(
        context: GraphicsContext,
        x: CGFloat,
        barTop: CGFloat,
        barWidth: CGFloat,
        corner: CGFloat,
        peakDB: Float,
        plot: CGRect,
        normalizedFrequency: Double
    ) {
        let peakY = yPosition(db: peakDB, plot: plot)
        let holdHeight = barTop - peakY
        guard holdHeight > 0.5 else { return }
        let rect = CGRect(x: x, y: peakY, width: barWidth, height: holdHeight)
        context.fill(
            Path(roundedRect: rect, cornerRadius: corner),
            with: .color(
                SpectrumTheme.peakHoldRectColor(
                    normalizedFrequency: normalizedFrequency,
                    normalizedLevel: normalizedLevel(peakDB),
                    style: configuration.barStyle
                ).opacity(0.75)
            )
        )
    }

    private func drawFrequencyAxis(context: GraphicsContext, plot: CGRect, canvasSize: CGSize) {
        let majors = FrequencyAxis.majorTicks(min: displayMin, max: displayMax)
        for frequency in majors {
            let x = xPosition(frequency: frequency, plot: plot)
            let label = FrequencyAxis.label(frequency)
            let resolved = context.resolve(
                Text(label)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(SpectrumTheme.textSecondary)
            )
            let textSize = resolved.measure(in: CGSize(width: 80, height: 20))
            context.draw(
                resolved,
                at: CGPoint(x: x, y: plot.maxY + 14),
                anchor: .center
            )
            _ = textSize
            _ = canvasSize
        }
    }

    private func drawDecibelAxis(context: GraphicsContext, plot: CGRect) {
        let labels: [Float] = [0, -12, -24, -48, -72, -96, -120].filter {
            $0 <= configuration.maximumDB && $0 >= configuration.minimumDB
        }
        for db in labels {
            let y = yPosition(db: db, plot: plot)
            let text = db == 0 ? "0 dB" : "\(Int(db))"
            let resolved = context.resolve(
                Text(text)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(SpectrumTheme.textSecondary)
            )
            context.draw(resolved, at: CGPoint(x: plot.minX - 8, y: y), anchor: .trailing)
        }
    }

    private func xPosition(frequency: Float, plot: CGRect) -> CGFloat {
        let t = FrequencyMapper.logPosition(
            frequency: frequency,
            minFrequency: displayMin,
            maxFrequency: displayMax
        )
        return plot.minX + CGFloat(t) * plot.width
    }

    private func yPosition(db: Float, plot: CGRect) -> CGFloat {
        let minDB = configuration.minimumDB
        let maxDB = configuration.maximumDB
        let clamped = min(max(db, minDB), maxDB)
        let t = (clamped - minDB) / max(maxDB - minDB, 1)
        return plot.maxY - CGFloat(t) * plot.height
    }

    private func barHeight(db: Float, plot: CGRect) -> CGFloat {
        let minDB = configuration.minimumDB
        let maxDB = configuration.maximumDB
        let clamped = min(max(db, minDB), maxDB)
        let t = (clamped - minDB) / max(maxDB - minDB, 1)
        return CGFloat(t) * plot.height
    }
}

enum FrequencyAxis {
    static func majorTicks(min: Float, max: Float) -> [Float] {
        let candidates: [Float] = [
            10, 20, 50, 100, 200, 500,
            1_000, 2_000, 5_000, 10_000, 20_000, 25_000
        ]
        return candidates.filter { $0 >= min * 0.98 && $0 <= max * 1.02 }
    }

    static func minorTicks(min: Float, max: Float) -> [Float] {
        let candidates: [Float] = [
            10, 15, 20, 30, 40, 50, 60, 70, 80, 90,
            100, 150, 200, 300, 400, 500, 600, 700, 800, 900,
            1_000, 1_500, 2_000, 3_000, 4_000, 5_000, 6_000, 7_000, 8_000, 9_000,
            10_000, 12_000, 15_000, 20_000, 25_000
        ]
        return candidates.filter { $0 >= min && $0 <= max }
    }

    static func label(_ frequency: Float) -> String {
        if frequency >= 1000 {
            let kilo = frequency / 1000
            if abs(kilo.rounded() - kilo) < 0.05 {
                return "\(Int(kilo.rounded())) kHz"
            }
            return String(format: "%.1f kHz", kilo)
        }
        return "\(Int(frequency)) Hz"
    }
}
