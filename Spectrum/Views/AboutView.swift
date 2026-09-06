import SwiftUI

struct AboutView: View {
    private let imageSide: CGFloat = 600

    var body: some View {
        VStack(spacing: 14) {
            Image("SpectrumIcon")
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: imageSide, height: imageSide)

            Text(versionLine)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(SpectrumTheme.textSecondary)

            Text(AboutPanel.copyright)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(SpectrumTheme.textSecondary)
        }
        .padding(.horizontal, 28)
        .padding(.top, 16)
        .padding(.bottom, 22)
        .background(SpectrumTheme.background)
    }

    private var versionLine: String {
        let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Spectrum"
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(name) \(version) (\(build))"
    }
}
