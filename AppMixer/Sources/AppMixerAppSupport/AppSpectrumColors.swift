import AppKit

/// UI-only icon sampling, cached by app identity rather than playback/list order.
@MainActor
public final class AppSpectrumColors {
    private var colors: [String: NSColor] = [:]

    public init() {}

    public func color(for id: String, icon: @autoclosure () -> NSImage?) -> NSColor {
        if let color = colors[id] { return color }
        let color = icon().flatMap { Self.dominantColor(in: $0) } ?? Self.fallbackColor(for: id)
        colors[id] = color
        return color
    }

    static func fallbackColor(for id: String) -> NSColor {
        // Swift's Hasher changes seed between launches. FNV-1a keeps this stable.
        let hash = id.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
        return NSColor(calibratedHue: CGFloat(hash % 360) / 360, saturation: 0.7, brightness: 0.9, alpha: 1)
    }

    static func dominantColor(in icon: NSImage) -> NSColor? {
        let size = 32
        guard let image = icon.cgImage(forProposedRect: nil, context: nil, hints: nil),
            let space = CGColorSpace(name: CGColorSpace.sRGB)
        else { return nil }
        var rgba = [UInt8](repeating: 0, count: size * size * 4)
        let rendered = rgba.withUnsafeMutableBytes { bytes in
            guard
                let context = CGContext(
                    data: bytes.baseAddress, width: size, height: size, bitsPerComponent: 8,
                    bytesPerRow: size * 4, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
            else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
            return true
        }
        guard rendered else { return nil }

        let count = 36
        var weights = [CGFloat](repeating: 0, count: count)
        var pixels: [(hue: CGFloat, saturation: CGFloat, brightness: CGFloat, weight: CGFloat)] = []
        for offset in stride(from: 0, to: rgba.count, by: 4) {
            let alpha = CGFloat(rgba[offset + 3]) / 255
            guard alpha > 0.5 else { continue }
            let color = NSColor(
                srgbRed: CGFloat(rgba[offset]) / (255 * alpha),
                green: CGFloat(rgba[offset + 1]) / (255 * alpha),
                blue: CGFloat(rgba[offset + 2]) / (255 * alpha), alpha: 1)
            let hue = color.hueComponent
            let saturation = color.saturationComponent
            let brightness = color.brightnessComponent
            // Ignore transparent margins, black outlines, and white glyphs.
            guard saturation > 0.2, brightness > 0.2 else { continue }
            let weight = alpha * saturation * saturation
            weights[min(count - 1, Int(hue * CGFloat(count)))] += weight
            pixels.append((hue, saturation, brightness, weight))
        }
        guard !pixels.isEmpty else { return nil }
        // Include neighboring hue bins so gradients do not lose to a flat accent.
        func score(_ index: Int) -> CGFloat {
            weights[(index + count - 1) % count] + weights[index] + weights[(index + 1) % count]
        }
        let winner = (0..<count).max { score($0) < score($1) }!
        let center = (CGFloat(winner) + 0.5) / CGFloat(count)
        var hueOffset: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var total: CGFloat = 0
        for pixel in pixels {
            var distance = pixel.hue - center
            if distance > 0.5 { distance -= 1 }
            if distance < -0.5 { distance += 1 }
            guard abs(distance) <= 1.5 / CGFloat(count) else { continue }
            hueOffset += distance * pixel.weight
            saturation += pixel.saturation * pixel.weight
            brightness += pixel.brightness * pixel.weight
            total += pixel.weight
        }
        guard total > 0 else { return nil }
        let hue = (center + hueOffset / total + 1).truncatingRemainder(dividingBy: 1)
        return NSColor(
            calibratedHue: hue, saturation: min(0.95, max(0.65, saturation / total)),
            brightness: max(0.8, brightness / total), alpha: 1)
    }
}
