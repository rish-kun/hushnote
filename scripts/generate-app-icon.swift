import AppKit
import Foundation

@main
enum GenerateAppIcon {
    private static let outputs: [(name: String, pixels: Int)] = [
        ("icon_16x16.png", 16),
        ("icon_16x16@2x.png", 32),
        ("icon_32x32.png", 32),
        ("icon_32x32@2x.png", 64),
        ("icon_128x128.png", 128),
        ("icon_128x128@2x.png", 256),
        ("icon_256x256.png", 256),
        ("icon_256x256@2x.png", 512),
        ("icon_512x512.png", 512),
        ("icon_512x512@2x.png", 1_024),
    ]

    /// The artwork's own tile colour. Pixels along the antialiased corner edge
    /// are blends of black into this, so unmasking them means fading toward it.
    private static let tile = (red: 252, green: 245, blue: 235)

    /// The corner wedges are painted opaque black; the tile is far brighter than
    /// this, so the flood fill stops exactly where the rounded edge begins.
    private static let outsideThreshold = 200

    static func main() throws {
        guard CommandLine.arguments.count == 4 else {
            throw GeneratorError.usage
        }
        let source = URL(fileURLWithPath: CommandLine.arguments[1])
        let directory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        let icns = URL(fileURLWithPath: CommandLine.arguments[3])
        let master = try maskedArtwork(at: source)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for output in outputs {
            try render(master, pixels: output.pixels, to: directory.appendingPathComponent(output.name))
        }
        try writeICNS(from: directory, to: icns)
    }

    /// The supplied artwork has no alpha channel: its rounded tile sits on
    /// opaque black corners. Baked into an icon those corners would render as a
    /// black square behind the tile. The corner curve is continuous rather than
    /// a circular radius, so clipping to a `roundedRect` of any guessed radius
    /// leaves slivers; instead the transparency is recovered from the pixels.
    /// A flood fill from the four corners reaches only the black wedges — the
    /// ink apertures are walled off by the vermilion mark around them — and each
    /// pixel it visits fades toward the tile colour in proportion to its own
    /// brightness, which preserves the artwork's antialiasing.
    private static func maskedArtwork(at source: URL) throws -> CGImage {
        guard let loaded = NSBitmapImageRep(data: try Data(contentsOf: source)) else {
            throw GeneratorError.source
        }
        let width = loaded.pixelsWide
        let height = loaded.pixelsHigh
        var pixels = try straightRGBA(from: loaded, width: width, height: height)

        var visited = [Bool](repeating: false, count: width * height)
        var stack = [0, width - 1, (height - 1) * width, width * height - 1]
        func brightness(_ index: Int) -> Int {
            let base = index * 4
            return max(Int(pixels[base]), max(Int(pixels[base + 1]), Int(pixels[base + 2])))
        }
        while let index = stack.popLast() {
            if visited[index] || brightness(index) >= outsideThreshold { continue }
            visited[index] = true
            let x = index % width
            let y = index / width
            if x > 0 { stack.append(index - 1) }
            if x < width - 1 { stack.append(index + 1) }
            if y > 0 { stack.append(index - width) }
            if y < height - 1 { stack.append(index + width) }
        }

        for index in 0..<(width * height) where visited[index] {
            let coverage = min(255, brightness(index) * 255 / tile.red)
            let base = index * 4
            // The buffer is premultiplied, so the tile colour scales by coverage.
            pixels[base] = UInt8(tile.red * coverage / 255)
            pixels[base + 1] = UInt8(tile.green * coverage / 255)
            pixels[base + 2] = UInt8(tile.blue * coverage / 255)
            pixels[base + 3] = UInt8(coverage)
        }

        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: width * 4,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: true,
                  intent: .defaultIntent
              )
        else { throw GeneratorError.bitmap }
        return image
    }

    /// Normalizes whatever layout the source PNG happens to use into one known
    /// 8-bit RGBA buffer the mask can address directly.
    private static func straightRGBA(
        from source: NSBitmapImageRep,
        width: Int,
        height: Int
    ) throws -> [UInt8] {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: width * 4,
            bitsPerPixel: 32
        ) else { throw GeneratorError.bitmap }

        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { throw GeneratorError.bitmap }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        source.draw(in: CGRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()

        guard let data = rep.bitmapData else { throw GeneratorError.bitmap }
        return [UInt8](UnsafeBufferPointer(start: data, count: width * height * 4))
    }

    private static func render(_ artwork: CGImage, pixels: Int, to destination: URL) throws {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixels,
            pixelsHigh: pixels,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { throw GeneratorError.bitmap }

        let context = NSGraphicsContext(bitmapImageRep: bitmap)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let cg = context?.cgContext else { throw GeneratorError.bitmap }

        let canvas = CGRect(x: 0, y: 0, width: pixels, height: pixels)
        cg.clear(canvas)
        cg.interpolationQuality = .high
        // The same inset the code-drawn icon used, so the artwork lands at the
        // framing the Dock already showed for Hushnote.
        cg.draw(artwork, in: canvas.insetBy(dx: CGFloat(pixels) * 0.075, dy: CGFloat(pixels) * 0.075))

        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw GeneratorError.encoding
        }
        try data.write(to: destination, options: .atomic)
    }

    /// A modern ICNS is a small big-endian container whose image entries are
    /// PNG payloads. Writing it directly avoids relying on `iconutil`, whose
    /// iconset validation has varied between Command Line Tools releases.
    private static func writeICNS(from directory: URL, to destination: URL) throws {
        // The OSTypes are Apple's, verified against what `iconutil -c icns`
        // emits for this very iconset. Three details are load-bearing.
        //
        // `icp4`/`icp5`/`icp6` are not these sizes. macOS reads `icp6` as
        // 48x48, so feeding it the 64px `@2x` render produced an entry the
        // Dock resolved at the wrong scale; round-tripping the old file back
        // through `iconutil -c iconset` returned an `icon_48x48.png`.
        //
        // Every `@2x` render needs its own type. `ic11`/`ic12`/`ic13`/`ic14`
        // are the retina lookups, and without them a Retina Dock finds no
        // representation at the sizes it asks for and falls back to the
        // generic application icon. The old table omitted all four and
        // discarded three of the ten renders unused.
        //
        // 256px and 512px each appear twice on purpose. `ic08`/`ic09` answer
        // the 1x lookup and `ic13`/`ic14` the 2x lookup for the size below;
        // Apple's own writer duplicates the payload rather than aliasing.
        let entries: [(type: String, filename: String)] = [
            ("ic04", "icon_16x16.png"),
            ("ic11", "icon_16x16@2x.png"),
            ("ic05", "icon_32x32.png"),
            ("ic12", "icon_32x32@2x.png"),
            ("ic07", "icon_128x128.png"),
            ("ic13", "icon_128x128@2x.png"),
            ("ic08", "icon_256x256.png"),
            ("ic14", "icon_256x256@2x.png"),
            ("ic09", "icon_512x512.png"),
            ("ic10", "icon_512x512@2x.png"),
        ]

        var body = Data()
        for entry in entries {
            let png = try Data(contentsOf: directory.appendingPathComponent(entry.filename))
            body.append(contentsOf: entry.type.utf8)
            appendUInt32(UInt32(png.count + 8), to: &body)
            body.append(png)
        }

        var container = Data("icns".utf8)
        appendUInt32(UInt32(body.count + 8), to: &container)
        container.append(body)
        try container.write(to: destination, options: .atomic)
    }

    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }
}

enum GeneratorError: Error, LocalizedError {
    case usage
    case source
    case bitmap
    case encoding

    var errorDescription: String? {
        switch self {
        case .usage: "Usage: generate-app-icon <source.png> <output.iconset> <output.icns>"
        case .source: "Could not read the icon source artwork."
        case .bitmap: "Could not allocate the icon bitmap."
        case .encoding: "Could not encode the icon as PNG."
        }
    }
}
