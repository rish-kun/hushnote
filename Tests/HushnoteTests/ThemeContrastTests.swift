import AppKit
import Testing
@testable import Hushnote

/// `PaperBackground` was the only scheme-aware token in the theme; every
/// foreground was a fixed light-mode sRGB literal. On the dark window
/// background `ink` computed to 1.04:1 -- so the *selected* workspace tab, the
/// one drawn in `ink`, was effectively invisible while the unselected tabs used
/// `.secondary`, which adapts, and stayed legible. Selection read as disabled.
/// `moss` on speaker names and `secondaryInk` sat near 2:1.
@Suite("Theme contrast")
struct ThemeContrastTests {
    // MARK: The helper itself

    /// The two anchors of WCAG 2.1: the maximum ratio is black against white,
    /// and a colour against itself has no contrast at all.
    @Test("Relative luminance is anchored at black and white")
    func luminanceAnchors() {
        #expect(WCAGContrast.relativeLuminance(PaletteColor(red: 0, green: 0, blue: 0)) == 0)
        #expect(WCAGContrast.relativeLuminance(PaletteColor(red: 1, green: 1, blue: 1)) == 1)
    }

    @Test("Contrast is symmetric and bounded by 21:1 and 1:1")
    func ratioAnchors() {
        let black = PaletteColor(red: 0, green: 0, blue: 0)
        let white = PaletteColor(red: 1, green: 1, blue: 1)

        #expect(abs(WCAGContrast.ratio(black, white) - 21) < 0.01)
        #expect(abs(WCAGContrast.ratio(white, black) - 21) < 0.01)
        #expect(abs(WCAGContrast.ratio(white, white) - 1) < 0.000_1)
    }

    /// A midpoint with a published value, so the gamma expansion is checked and
    /// not just the endpoints. #767676 is the lightest grey that still clears
    /// 4.5:1 against white -- the canonical WCAG worked example.
    @Test("The gamma curve matches the published mid-grey threshold")
    func gammaCurveIsCorrect() {
        let grey = PaletteColor(red: 0x76 / 255, green: 0x76 / 255, blue: 0x76 / 255)
        let white = PaletteColor(red: 1, green: 1, blue: 1)

        let ratio = WCAGContrast.ratio(grey, white)
        #expect(ratio >= 4.5)
        #expect(ratio < 4.6)
    }

    // MARK: The palette

    /// Body and caption text, against both surfaces it can be drawn on, in both
    /// appearances. This is the assertion the fix exists for.
    @Test(
        "Every text token clears AA against every surface it is drawn on",
        arguments: [ColorAppearance.light, .dark]
    )
    func textTokensClearAA(appearance: ColorAppearance) {
        let surfaces: [HushnoteTheme.Token] = [.paper, .paperRaised]
        let text: [HushnoteTheme.Token] = [.ink, .secondaryInk, .vermilionInk, .moss]

        for foreground in text {
            for surface in surfaces {
                let ratio = WCAGContrast.ratio(
                    HushnoteTheme.palette(foreground, appearance),
                    HushnoteTheme.palette(surface, appearance)
                )
                #expect(
                    ratio >= 4.5,
                    "\(foreground) on \(surface) in \(appearance) is \(ratio):1"
                )
            }
        }
    }

    /// A filled control carries a white label. If the fill is legible against
    /// the page but the label is not legible against the fill, the button is
    /// still unreadable -- which is what a naively inverted `ink` would do to
    /// every prominent button in dark mode.
    @Test(
        "A filled control is legible, and so is the label on it",
        arguments: [ColorAppearance.light, .dark]
    )
    func filledControlsAreLegible(appearance: ColorAppearance) {
        let white = PaletteColor(red: 1, green: 1, blue: 1)

        for fill in [HushnoteTheme.Token.vermilion, .inkFill] {
            let fillColor = HushnoteTheme.palette(fill, appearance)

            let labelRatio = WCAGContrast.ratio(white, fillColor)
            #expect(labelRatio >= 4.5, "white on \(fill) in \(appearance) is \(labelRatio):1")

            let edgeRatio = WCAGContrast.ratio(
                fillColor,
                HushnoteTheme.palette(.paper, appearance)
            )
            #expect(edgeRatio >= 3, "\(fill) against the page in \(appearance) is \(edgeRatio):1")
        }
    }

    /// The light palette is the design, and it is not up for renegotiation --
    /// with one measured exception. `vermilion` as small text was 4.32:1 on
    /// paper, which never cleared AA in light mode either. The brand fill keeps
    /// its exact value; only the ink variant moves.
    @Test("The light palette is unchanged")
    func lightPaletteIsPreserved() {
        #expect(HushnoteTheme.palette(.paper, .light) == PaletteColor(red: 0.965, green: 0.949, blue: 0.918))
        #expect(HushnoteTheme.palette(.paperRaised, .light) == PaletteColor(red: 0.985, green: 0.975, blue: 0.951))
        #expect(HushnoteTheme.palette(.ink, .light) == PaletteColor(red: 0.105, green: 0.102, blue: 0.094))
        #expect(HushnoteTheme.palette(.secondaryInk, .light) == PaletteColor(red: 0.34, green: 0.325, blue: 0.292))
        #expect(HushnoteTheme.palette(.vermilion, .light) == PaletteColor(red: 0.84, green: 0.20, blue: 0.105))
        #expect(HushnoteTheme.palette(.moss, .light) == PaletteColor(red: 0.20, green: 0.34, blue: 0.25))
        #expect(HushnoteTheme.palette(.rule, .light) == PaletteColor(red: 0.77, green: 0.73, blue: 0.65))
    }

    /// A palette that is only a data table proves nothing: the app would still
    /// render fixed light colours. Resolve the real `NSColor` in each appearance
    /// and check it lands on the palette value.
    @Test(
        "The tokens the views use actually resolve per appearance",
        arguments: [ColorAppearance.light, .dark]
    )
    func tokensResolveThroughAppKit(appearance: ColorAppearance) {
        let name: NSAppearance.Name = appearance == .dark ? .darkAqua : .aqua

        for token in HushnoteTheme.Token.allCases {
            let expected = HushnoteTheme.palette(token, appearance)
            var resolved = PaletteColor(red: -1, green: -1, blue: -1)

            NSAppearance(named: name)?.performAsCurrentDrawingAppearance {
                guard let srgb = HushnoteTheme.nsColor(token).usingColorSpace(.sRGB) else { return }
                resolved = PaletteColor(
                    red: Double(srgb.redComponent),
                    green: Double(srgb.greenComponent),
                    blue: Double(srgb.blueComponent)
                )
            }

            #expect(abs(resolved.red - expected.red) < 0.005, "\(token) red in \(appearance)")
            #expect(abs(resolved.green - expected.green) < 0.005, "\(token) green in \(appearance)")
            #expect(abs(resolved.blue - expected.blue) < 0.005, "\(token) blue in \(appearance)")
        }
    }
}
