import SwiftUI
import UIKit

/// The brand inside the app, the same as on healthaccessmcp.com: IBM Plex Sans Condensed for the wordmark, titles and
/// headlines (bundled, SIL Open Font License, Resources/Fonts/OFL.txt), the system font for everything you read, the
/// access blue as the accent, the cool ground behind the lists and the orange signal only where you are needed.
enum Brand {
    static let semibold = "IBMPlexSansCond-SemiBold"
    static let bold = "IBMPlexSansCond-Bold"

    /// Navigation titles in Plex Sans Condensed, large and inline. Called once at launch.
    static func applyAppearance() {
        let appearance = UINavigationBarAppearance()
        appearance.configureWithTransparentBackground()
        appearance.backgroundColor = .clear
        let large = UIFontMetrics(forTextStyle: .largeTitle).scaledFont(for: UIFont(name: bold, size: 36) ?? .boldSystemFont(ofSize: 34))
        let inline = UIFontMetrics(forTextStyle: .headline).scaledFont(for: UIFont(name: semibold, size: 19) ?? .boldSystemFont(ofSize: 17))
        appearance.largeTitleTextAttributes = [.font: large]
        appearance.titleTextAttributes = [.font: inline]
        let scrolled = UINavigationBarAppearance()
        scrolled.configureWithDefaultBackground()
        scrolled.largeTitleTextAttributes = [.font: large]
        scrolled.titleTextAttributes = [.font: inline]
        UINavigationBar.appearance().standardAppearance = scrolled
        UINavigationBar.appearance().compactAppearance = scrolled
        UINavigationBar.appearance().scrollEdgeAppearance = appearance
    }
}

extension Font {
    /// Plex Sans Condensed at `size`, scaling with Dynamic Type like `style`.
    static func brand(_ size: CGFloat, bold: Bool = true, relativeTo style: Font.TextStyle = .title) -> Font {
        .custom(bold ? Brand.bold : Brand.semibold, size: size, relativeTo: style)
    }
}

extension Color {
    /// #F3F5F6 light, #0B0F11 dark: the ground behind every list.
    static let ground = Color("Ground")
}

/// The wordmark: the mark on its tile, "Health Access" in Plex Sans Condensed Bold and "MCP" small, spaced, in the
/// accent, on the same baseline. The top of the Export tab, as on the site's navigation bar.
struct Wordmark: View {
    var size: CGFloat = 34

    var body: some View {
        HStack(alignment: .center, spacing: size * 0.35) {
            MarkTile(size: size * 1.25)
            HStack(alignment: .firstTextBaseline, spacing: size * 0.22) {
                Text("Health Access")
                    .font(.brand(size, relativeTo: .largeTitle))
                    .foregroundStyle(Color.primary)
                Text("MCP")
                    .font(.brand(size * 0.42, bold: false, relativeTo: .caption))
                    .tracking(size * 0.06)
                    .foregroundStyle(Color.accentColor)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Health Access MCP")
        .accessibilityAddTraits(.isHeader)
    }
}

/// The brand ground behind a list instead of the system grey.
struct BrandGround: ViewModifier {
    func body(content: Content) -> some View {
        content.scrollContentBackground(.hidden).background(Color.ground)
    }
}

extension View {
    func brandGround() -> some View { modifier(BrandGround()) }
}
