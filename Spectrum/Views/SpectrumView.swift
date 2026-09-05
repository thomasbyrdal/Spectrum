import SwiftUI

// This is where the fun happens...
//
struct SpectrumView: View, Equatable {
    let data: SpectrumData
    let configuration: SpectrumConfiguration

    var body: some View {
        Canvas { context, size in
            let plot = plotRect(in: size)
            if configuration.showGrid {
                drawGrid(context: context, plot: plot)
            }
            drawBars(context: context, plot: plot)
            drawFrequencyAxis(context: context, plot: plot, canvasSize: size)
            drawDecibelAxis(context: context, plot: plot)
        }
        .background(SpectrumTheme.background)
    }

    private func plotRect(in size: CGSize) -> CGRect {
        CGRect(x: 56, y: 16, width: max(size.width - 72, 10), height: max(size.height - 48, 10))
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
        let slot = plot.width / CGFloat(count)
        let gap: CGFloat = slot > 3 ? min(1.0, slot * 0.22) : 0
        let barWidth = max(slot - gap, 0.5)

        for index in 0..<count {
            let t = Double(index) / Double(max(count - 1, 1))
            let db = data.magnitudesDB[index]
            let height = barHeight(db: db, plot: plot)
            let x = plot.minX + CGFloat(index) * slot + gap / 2
            let y = plot.maxY - height
            let rect = CGRect(x: x, y: y, width: barWidth, height: max(height, 1))
            let corner = min(barWidth / 4, 1.5)
            let peakEnabled = configuration.peakHoldEnabled && index < data.peakMagnitudesDB.count
            let peakDB = peakEnabled ? data.peakMagnitudesDB[index] : 0

            if peakEnabled, configuration.peakHoldStyle == .rect {
                drawPeakHoldRect(
                    context: context,
                    x: x,
                    barTop: y,
                    barWidth: barWidth,
                    corner: corner,
                    peakDB: peakDB,
                    plot: plot,
                    normalizedFrequency: t
                )
            }

            context.fill(
                Path(roundedRect: rect, cornerRadius: corner),
                with: SpectrumTheme.barShading(normalizedFrequency: t, style: configuration.barStyle, in: rect)
            )

            if peakEnabled, configuration.peakHoldStyle == .bar {
                drawPeakHoldBar(context: context, x: x, barWidth: barWidth, peakDB: peakDB, plot: plot)
            }
        }
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
                    style: configuration.barStyle
                ).opacity(0.75)
                //).opacity(0.88)
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
