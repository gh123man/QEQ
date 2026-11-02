import AppKit
import Testing

@testable import QEQAppSupport

@MainActor
private func sampleIcon(_ pixel: (Int, Int) -> NSColor) -> NSImage {
    let context = CGContext(
        data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 128,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    for y in 0..<32 {
        for x in 0..<32 {
            context.setFillColor(pixel(x, y).usingColorSpace(.sRGB)!.cgColor)
            context.fill(CGRect(x: x, y: y, width: 1, height: 1))
        }
    }
    return NSImage(cgImage: context.makeImage()!, size: NSSize(width: 32, height: 32))
}

@Test @MainActor func iconSpectrumColorFindsGreenAmongNeutralPixels() throws {
    let icon = sampleIcon { _, y in
        if y < 10 { return .white }
        if y < 22 { return .black }
        return NSColor(srgbRed: 0.1, green: 0.75, blue: 0.3, alpha: 1)
    }
    let color = try #require(AppSpectrumColors.dominantColor(in: icon)?.usingColorSpace(.sRGB))
    #expect(color.greenComponent > color.redComponent * 2)
    #expect(color.greenComponent > color.blueComponent * 1.5)
    #expect(color.brightnessComponent >= 0.79)
}

@Test @MainActor func iconSpectrumColorIgnoresTransparentMarginsAndKeepsBlueHue() throws {
    let icon = sampleIcon { x, _ in
        x < 24 ? NSColor.red.withAlphaComponent(0.1) : NSColor(srgbRed: 0.1, green: 0.4, blue: 0.95, alpha: 1)
    }
    let color = try #require(AppSpectrumColors.dominantColor(in: icon)?.usingColorSpace(.sRGB))
    #expect(color.blueComponent > color.greenComponent * 1.5)
    #expect(color.blueComponent > color.redComponent * 2)
    #expect(AppSpectrumColors.dominantColor(in: sampleIcon { _, _ in .white }) == nil)
}

@Test @MainActor func spectrumColorsSurviveAppReorderingAndCacheIconSampling() {
    let colors = AppSpectrumColors()
    let green = sampleIcon { _, _ in .green }
    var reads = 0
    func icon() -> NSImage {
        reads += 1
        return green
    }
    let first = colors.color(for: "music", icon: icon())
    _ = colors.color(for: "meeting", icon: nil)
    #expect(colors.color(for: "music", icon: icon()) == first)
    #expect(reads == 1)
    // A new instance (relaunch) and a different discovery order preserve colors.
    let restarted = AppSpectrumColors()
    #expect(restarted.color(for: "meeting", icon: nil) == colors.color(for: "meeting", icon: nil))
    #expect(restarted.color(for: "music", icon: green) == first)
    #expect(restarted.color(for: "missing", icon: nil) != restarted.color(for: "meeting", icon: nil))
}
