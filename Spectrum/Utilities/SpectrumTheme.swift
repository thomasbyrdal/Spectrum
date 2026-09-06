import SwiftUI

enum SpectrumTheme {
    static let background = Color(red: 0.055, green: 0.06, blue: 0.075)
    static let panel = Color(red: 0.09, green: 0.10, blue: 0.12)
    static let panelStroke = Color.white.opacity(0.08)
    static let gridMajor = Color.white.opacity(0.14)
    static let gridMinor = Color.white.opacity(0.06)
    static let textPrimary = Color(red: 0.90, green: 0.92, blue: 0.94)
    static let textSecondary = Color(red: 0.62, green: 0.66, blue: 0.70)
    static let accent = Color(red: 0.22, green: 0.82, blue: 0.78)
    static let warning = Color(red: 0.98, green: 0.72, blue: 0.22)
    static let clip = Color(red: 0.95, green: 0.28, blue: 0.28)
    static let running = Color(red: 0.35, green: 0.88, blue: 0.45)
    static let stopped = Color(red: 0.95, green: 0.28, blue: 0.28)
    static let barFill = Color(red: 0.25, green: 0.92, blue: 0.78)
    static let peakMarker = Color.white.opacity(0.85)
    static let meterLEDGreen = Color(red: 0.18, green: 0.92, blue: 0.32)
    static let meterLEDYellow = Color(red: 1.0, green: 0.84, blue: 0.10)
    static let meterLEDRed = Color(red: 1.0, green: 0.16, blue: 0.14)

    static func barColor(
        normalizedFrequency: Double,
        normalizedLevel: Double = 0,
        style: BarStyle
    ) -> Color {
        switch style {
        case .solid:
            return barFill
        case .gradient:
            let hue = 0.55 - normalizedFrequency * 0.52
            return Color(hue: hue, saturation: 0.85, brightness: 0.95)
        case .blueGradient:
            let hue = 0.62 - normalizedFrequency * 0.10
            return Color(hue: hue, saturation: 0.82, brightness: 0.55 + 0.40 * normalizedFrequency)
        case .greenGradient:
            let hue = 0.38 - normalizedFrequency * 0.10
            return Color(hue: hue, saturation: 0.85, brightness: 0.50 + 0.42 * normalizedFrequency)
        case .redGradient:
            let hue = (0.98 + normalizedFrequency * 0.08).truncatingRemainder(dividingBy: 1)
            return Color(hue: hue, saturation: 0.88, brightness: 0.52 + 0.43 * normalizedFrequency)
        case .heat:
            return heatColor(normalizedLevel: normalizedLevel)
        }
    }

    static func peakHoldRectColor(
        normalizedFrequency: Double,
        normalizedLevel: Double = 0,
        style: BarStyle
    ) -> Color {
        switch style {
        case .solid:
            return Color(red: 0.10, green: 0.38, blue: 0.32)
        case .gradient:
            let hue = 0.55 - normalizedFrequency * 0.52
            return Color(hue: hue, saturation: 0.80, brightness: 0.42)
        case .blueGradient:
            let hue = 0.62 - normalizedFrequency * 0.10
            return Color(hue: hue, saturation: 0.80, brightness: 0.32)
        case .greenGradient:
            let hue = 0.38 - normalizedFrequency * 0.10
            return Color(hue: hue, saturation: 0.82, brightness: 0.30)
        case .redGradient:
            let hue = (0.98 + normalizedFrequency * 0.08).truncatingRemainder(dividingBy: 1)
            return Color(hue: hue, saturation: 0.85, brightness: 0.30)
        case .heat:
            return heatColor(normalizedLevel: normalizedLevel, brightness: 0.32)
        }
    }

    static func barGlowColor(
        normalizedFrequency: Double,
        normalizedLevel: Double,
        style: BarStyle
    ) -> Color {
        barColor(
            normalizedFrequency: normalizedFrequency,
            normalizedLevel: normalizedLevel,
            style: style
        )
    }

    static func barShading(
        normalizedFrequency: Double,
        normalizedLevel: Double = 0,
        style: BarStyle,
        in rect: CGRect
    ) -> GraphicsContext.Shading {
        let top = barColor(
            normalizedFrequency: normalizedFrequency,
            normalizedLevel: normalizedLevel,
            style: style
        )
        switch style {
        case .solid, .gradient, .heat:
            return .color(top.opacity(0.92))
        case .blueGradient:
            return verticalGradient(
                in: rect,
                bottom: Color(hue: 0.65, saturation: 0.88, brightness: 0.22),
                top: top
            )
        case .greenGradient:
            return verticalGradient(
                in: rect,
                bottom: Color(hue: 0.40, saturation: 0.90, brightness: 0.18),
                top: top
            )
        case .redGradient:
            return verticalGradient(
                in: rect,
                bottom: Color(hue: 0.98, saturation: 0.90, brightness: 0.20),
                top: top
            )
        }
    }

    static func heatColor(normalizedLevel: Double, brightness: Double = 0.95) -> Color {
        let t = min(max(normalizedLevel, 0), 1)
        let hue = 0.66 - t * 0.66
        let sat = 0.78 + 0.12 * t
        let bright = min(max(brightness * (0.55 + 0.45 * t), 0.15), 1)
        return Color(hue: hue, saturation: sat, brightness: bright)
    }

    private static func verticalGradient(in rect: CGRect, bottom: Color, top: Color) -> GraphicsContext.Shading {
        .linearGradient(
            Gradient(colors: [bottom.opacity(0.95), top]),
            startPoint: CGPoint(x: rect.midX, y: rect.maxY),
            endPoint: CGPoint(x: rect.midX, y: rect.minY)
        )
    }
}
