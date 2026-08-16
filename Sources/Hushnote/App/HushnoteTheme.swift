import SwiftUI

enum HushnoteTheme {
    static let paper = Color(red: 0.965, green: 0.949, blue: 0.918)
    static let paperRaised = Color(red: 0.985, green: 0.975, blue: 0.951)
    static let ink = Color(red: 0.105, green: 0.102, blue: 0.094)
    static let secondaryInk = Color(red: 0.34, green: 0.325, blue: 0.292)
    static let vermilion = Color(red: 0.84, green: 0.20, blue: 0.105)
    static let moss = Color(red: 0.20, green: 0.34, blue: 0.25)
    static let rule = Color(red: 0.77, green: 0.73, blue: 0.65)

    static let sidebarWidth: CGFloat = 248
    static let contentMaxWidth: CGFloat = 940
}

struct PaperBackground: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content.background {
            if colorScheme == .dark {
                Color(nsColor: .windowBackgroundColor)
            } else {
                HushnoteTheme.paper
                    .overlay(alignment: .topLeading) {
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

