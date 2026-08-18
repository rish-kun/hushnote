import AppKit
import SwiftUI

/// An sRGB colour held as components, so contrast can be reasoned about without
/// going through a resolved `NSColor` and a display colour space.
struct PaletteColor: Equatable, Sendable {
    var red: Double
    var green: Double
    var blue: Double
}

enum ColorAppearance: CaseIterable, Sendable {
    case light
    case dark
}

/// WCAG 2.1 relative luminance and contrast. A pure function, which is the only
/// reason the palette below can be held to a threshold at all.
enum WCAGContrast {
    nonisolated static func relativeLuminance(_ color: PaletteColor) -> Double {
        func linear(_ channel: Double) -> Double {
            channel <= 0.03928 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(color.red)
            + 0.7152 * linear(color.green)
            + 0.0722 * linear(color.blue)
    }

    nonisolated static func ratio(_ a: PaletteColor, _ b: PaletteColor) -> Double {
        let first = relativeLuminance(a)
        let second = relativeLuminance(b)
        return (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }
}

enum HushnoteTheme {
    /// Every colour the app draws with. Split by role rather than by hue: the
    /// accent used as a filled surface and the accent used as small text cannot
    /// be the same value and both clear AA.
    enum Token: CaseIterable, Sendable {
        /// The page.
        case paper
        /// A surface lifted off the page.
        case paperRaised
        /// Primary text.
        case ink
        /// Supporting text.
        case secondaryInk
        /// The recording accent as a filled surface, carrying a white label.
        case vermilion
        /// The recording accent as text or a symbol.
        case vermilionInk
        /// Evidence and timestamps.
        case moss
        /// Hairlines. Decorative, and deliberately quiet.
        case rule
        /// A neutral filled control carrying a white label.
        case inkFill
    }

    /// The authored value of a token in a given appearance.
    ///
    /// The light column is the design as it stands, with one measured
    /// exception: `vermilionInk` is a shade deeper than the brand `vermilion`,
    /// because the brand value is 4.32:1 on paper and was never AA as small
    /// text — in light mode either. The fill keeps the exact brand colour.
    nonisolated static func palette(_ token: Token, _ appearance: ColorAppearance) -> PaletteColor {
        switch appearance {
        case .light:
            switch token {
            case .paper: PaletteColor(red: 0.965, green: 0.949, blue: 0.918)
            case .paperRaised: PaletteColor(red: 0.985, green: 0.975, blue: 0.951)
            case .ink: PaletteColor(red: 0.105, green: 0.102, blue: 0.094)
            case .secondaryInk: PaletteColor(red: 0.34, green: 0.325, blue: 0.292)
            case .vermilion: PaletteColor(red: 0.84, green: 0.20, blue: 0.105)
            case .vermilionInk: PaletteColor(red: 0.80, green: 0.18, blue: 0.09)
            case .moss: PaletteColor(red: 0.20, green: 0.34, blue: 0.25)
            case .rule: PaletteColor(red: 0.77, green: 0.73, blue: 0.65)
            case .inkFill: PaletteColor(red: 0.105, green: 0.102, blue: 0.094)
            }
        case .dark:
            switch token {
            case .paper: PaletteColor(red: 0.1176, green: 0.1176, blue: 0.1176)
            case .paperRaised: PaletteColor(red: 0.163, green: 0.160, blue: 0.153)
            case .ink: PaletteColor(red: 0.925, green: 0.918, blue: 0.902)
            case .secondaryInk: PaletteColor(red: 0.70, green: 0.685, blue: 0.655)
            // The fill keeps the brand value in both appearances: it is the one
            // colour the app uses to mean "recording", and a white label stays
            // legible on it either way.
            case .vermilion: PaletteColor(red: 0.84, green: 0.20, blue: 0.105)
            case .vermilionInk: PaletteColor(red: 0.98, green: 0.44, blue: 0.32)
            case .moss: PaletteColor(red: 0.56, green: 0.76, blue: 0.60)
            case .rule: PaletteColor(red: 0.32, green: 0.31, blue: 0.29)
            case .inkFill: PaletteColor(red: 0.44, green: 0.43, blue: 0.40)
            }
        }
    }

    /// The token as an appearance-aware `NSColor`. AppKit resolves the provider
    /// whenever the effective appearance changes, so a view holding this colour
    /// follows the system without observing anything.
    nonisolated static func nsColor(_ token: Token) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let value = palette(token, isDark ? .dark : .light)
            return NSColor(
                srgbRed: value.red,
                green: value.green,
                blue: value.blue,
                alpha: 1
            )
        }
    }

    nonisolated static func color(_ token: Token) -> Color {
        Color(nsColor: nsColor(token))
    }

    static let paper = color(.paper)
    static let paperRaised = color(.paperRaised)
    static let ink = color(.ink)
    static let secondaryInk = color(.secondaryInk)
    static let vermilion = color(.vermilion)
    static let vermilionInk = color(.vermilionInk)
    static let moss = color(.moss)
    static let rule = color(.rule)
    static let inkFill = color(.inkFill)

    /// The typographic scale. Every one of these was an inline literal, and the
    /// same serif heading was written out three times at two different sizes.
    enum Font {
        /// The name of a screen.
        static let pageTitle = SwiftUI.Font.system(size: 31, weight: .semibold, design: .serif)
        /// The name of a meeting inside its live workspace, where the chrome
        /// above it is already doing some of the work.
        static let workspaceTitle = SwiftUI.Font.system(size: 21, weight: .semibold, design: .serif)
        /// A section within a page.
        static let sectionTitle = SwiftUI.Font.system(size: 24, weight: .semibold, design: .serif)
        /// A heading inside a section.
        static let subsectionTitle = SwiftUI.Font.system(size: 19, weight: .semibold, design: .serif)
        /// Prose the user reads at length: notes, transcript, summary.
        static let reading = SwiftUI.Font.system(size: 17, design: .serif)
        static let readingLarge = SwiftUI.Font.system(size: 18, design: .serif)
        /// An empty state's headline.
        static let emptyStateTitle = SwiftUI.Font.system(size: 20, weight: .medium, design: .serif)
    }

    static let sidebarWidth: CGFloat = 248
    static let contentMaxWidth: CGFloat = 940
    /// The measure the transcript is set to. Narrower than a page, because a
    /// line of prose that runs the full width of a window is read by hopping
    /// rather than by scanning: this is around 70 characters of
    /// `Font.reading`, which is where the eye finds the next line without
    /// looking for it.
    static let transcriptMeasure: CGFloat = 660
}

extension View {
    /// The standard page measure and margin. Repeated five times by hand, with
    /// one page silently using a different width.
    func pageChrome() -> some View {
        frame(maxWidth: HushnoteTheme.contentMaxWidth, alignment: .leading)
            .padding(38)
    }
}

struct PaperBackground: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content.background {
            HushnoteTheme.paper
                .overlay(alignment: .topLeading) {
                    // The ruled sheet is a light-mode conceit. On a dark page the
                    // same lines read as banding rather than paper.
                    if colorScheme != .dark {
                        Canvas { context, size in
                            var path = Path()
                            stride(from: CGFloat(32), through: size.height, by: 32).forEach { y in
                                path.move(to: CGPoint(x: 0, y: y))
                                path.addLine(to: CGPoint(x: size.width, y: y))
                            }
                            context.stroke(path, with: .color(HushnoteTheme.ink.opacity(0.022)), lineWidth: 0.5)
                        }
                        .allowsHitTesting(false)
                    }
                }
        }
    }
}

extension View {
    func paperBackground() -> some View { modifier(PaperBackground()) }
}
