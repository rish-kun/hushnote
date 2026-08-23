import AppKit
import SwiftUI

/// The listening-tree silhouette supplied for Hushnote, expressed once in a
/// normalized square so every branded surface stays crisp and consistent.
enum HushnoteBrandGeometry {
    static let normalizedBounds = CGRect(x: 0, y: 0, width: 1, height: 1)

    nonisolated static func path(in rect: CGRect) -> CGPath {
        let transform = CGAffineTransform(
            a: rect.width,
            b: 0,
            c: 0,
            d: rect.height,
            tx: rect.minX,
            ty: rect.minY
        )
        let path = CGMutablePath()

        // The canopy: an asymmetric, soft-edged listening cloud.
        path.move(to: CGPoint(x: 0.46, y: 0.76), transform: transform)
        path.addCurve(
            to: CGPoint(x: 0.16, y: 0.55),
            control1: CGPoint(x: 0.29, y: 0.76),
            control2: CGPoint(x: 0.16, y: 0.68),
            transform: transform
        )
        path.addCurve(
            to: CGPoint(x: 0.34, y: 0.31),
            control1: CGPoint(x: 0.16, y: 0.43),
            control2: CGPoint(x: 0.23, y: 0.34),
            transform: transform
        )
        path.addCurve(
            to: CGPoint(x: 0.61, y: 0.16),
            control1: CGPoint(x: 0.37, y: 0.19),
            control2: CGPoint(x: 0.48, y: 0.14),
            transform: transform
        )
        path.addCurve(
            to: CGPoint(x: 0.79, y: 0.34),
            control1: CGPoint(x: 0.70, y: 0.18),
            control2: CGPoint(x: 0.77, y: 0.24),
            transform: transform
        )
        path.addCurve(
            to: CGPoint(x: 0.94, y: 0.57),
            control1: CGPoint(x: 0.89, y: 0.39),
            control2: CGPoint(x: 0.94, y: 0.47),
            transform: transform
        )
        path.addCurve(
            to: CGPoint(x: 0.65, y: 0.77),
            control1: CGPoint(x: 0.94, y: 0.69),
            control2: CGPoint(x: 0.82, y: 0.77),
            transform: transform
        )
        path.closeSubpath()

        // The small flared trunk makes the mark read as a tree at dock size.
        path.move(to: CGPoint(x: 0.47, y: 0.70), transform: transform)
        path.addLine(to: CGPoint(x: 0.65, y: 0.70), transform: transform)
        path.addCurve(
            to: CGPoint(x: 0.68, y: 0.94),
            control1: CGPoint(x: 0.64, y: 0.80),
            control2: CGPoint(x: 0.66, y: 0.87),
            transform: transform
        )
        path.addLine(to: CGPoint(x: 0.43, y: 0.94), transform: transform)
        path.addCurve(
            to: CGPoint(x: 0.47, y: 0.70),
            control1: CGPoint(x: 0.45, y: 0.85),
            control2: CGPoint(x: 0.47, y: 0.78),
            transform: transform
        )
        path.closeSubpath()

        // Even-odd fill turns these slightly organic slots into apertures.
        addListeningAperture(
            to: path,
            rect: CGRect(x: 0.31, y: 0.44, width: 0.105, height: 0.22),
            rotation: 0.08,
            transform: transform
        )
        addListeningAperture(
            to: path,
            rect: CGRect(x: 0.48, y: 0.46, width: 0.105, height: 0.22),
            rotation: 0.08,
            transform: transform
        )

        return path
    }

    private nonisolated static func addListeningAperture(
        to path: CGMutablePath,
        rect: CGRect,
        rotation: CGFloat,
        transform: CGAffineTransform
    ) {
        let aperture = CGPath(
            roundedRect: rect,
            cornerWidth: rect.width / 2,
            cornerHeight: rect.width / 2,
            transform: nil
        )
        let rotated = CGAffineTransform.identity
            .translatedBy(x: rect.midX, y: rect.midY)
            .rotated(by: rotation)
            .translatedBy(x: -rect.midX, y: -rect.midY)
            .concatenating(transform)
        path.addPath(aperture, transform: rotated)
    }
}

struct HushnoteBrandShape: Shape {
    nonisolated func path(in rect: CGRect) -> Path {
        Path(HushnoteBrandGeometry.path(in: rect))
    }
}

struct HushnoteBrandMark: View {
    var color = HushnoteTheme.vermilion

    var body: some View {
        HushnoteBrandShape()
            .fill(color, style: FillStyle(eoFill: true))
            .aspectRatio(1, contentMode: .fit)
            .accessibilityHidden(true)
    }
}

enum HushnoteBrandImages {
    nonisolated static func menuBarTemplate(isRecording: Bool, size: CGFloat = 18) -> NSImage {
        let image = NSImage(size: CGSize(width: size, height: size), flipped: false) { target in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            // Core Graphics image contexts are bottom-up; the shared geometry
            // deliberately follows SwiftUI's top-down view coordinates.
            context.translateBy(x: 0, y: target.height)
            context.scaleBy(x: 1, y: -1)
            let inset = target.insetBy(dx: size * 0.08, dy: size * 0.08)
            context.addPath(HushnoteBrandGeometry.path(in: inset))
            context.setFillColor(NSColor.black.cgColor)
            context.drawPath(using: .eoFill)
            if isRecording {
                let diameter = size * 0.28
                context.fillEllipse(in: CGRect(
                    x: target.maxX - diameter,
                    y: target.minY,
                    width: diameter,
                    height: diameter
                ))
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = isRecording
            ? "Hushnote is recording"
            : "Hushnote"
        return image
    }
}

struct HushnoteBuildInfo: Equatable {
    var shortVersion: String
    var build: String
    var bundleIdentifier: String

    static var current: HushnoteBuildInfo {
        let bundle = Bundle.main
        return HushnoteBuildInfo(
            shortVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development",
            build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "local",
            bundleIdentifier: bundle.bundleIdentifier ?? "dev.rishit.hushnote"
        )
    }

    var versionLabel: String {
        Self.versionLabel(shortVersion: shortVersion, build: build)
    }

    nonisolated static func versionLabel(shortVersion: String, build: String) -> String {
        "Version \(shortVersion) (\(build))"
    }
}

struct AboutHushnoteView: View {
    static let windowID = "about-hushnote"
    private let buildInfo = HushnoteBuildInfo.current

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(HushnoteTheme.ink)
                HushnoteBrandMark()
                    .padding(23)
            }
            .frame(width: 112, height: 112)
            .padding(.bottom, 20)

            Text("Hushnote")
                .font(HushnoteTheme.Font.pageTitle)
            Text(buildInfo.versionLabel)
                .font(.caption.monospacedDigit())
                .foregroundStyle(HushnoteTheme.secondaryInk)
                .padding(.top, 6)
            Text("Private meeting capture and evidence-backed notes, kept close to the conversation.")
                .font(.callout)
                .foregroundStyle(HushnoteTheme.secondaryInk)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 330)
                .padding(.top, 18)
            Text(buildInfo.bundleIdentifier)
                .font(.caption2.monospaced())
                .foregroundStyle(HushnoteTheme.secondaryInk.opacity(0.72))
                .textSelection(.enabled)
                .padding(.top, 18)
        }
        .padding(38)
        .frame(width: 430)
        .paperBackground()
        .accessibilityElement(children: .contain)
    }
}

struct HushnoteAboutCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Hushnote") {
                openWindow(id: AboutHushnoteView.windowID)
            }
        }
    }
}
