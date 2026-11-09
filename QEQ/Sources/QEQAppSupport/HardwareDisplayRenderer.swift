import AppKit

/// Wire pixels use logical, post-orientation coordinates and RGB565 LE.
public struct HardwareDisplayCapabilities: Codable, Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var format: Int
    public var orientation: Int
    public var shape: Int
    public init(width: Int = 240, height: Int = 240, format: Int = 1, orientation: Int = 0, shape: Int = 1) {
        self.width = width
        self.height = height
        self.format = format
        self.orientation = orientation
        self.shape = shape
    }
    public var supported: Bool {
        (1...1024).contains(width) && (1...1024).contains(height) && format == 1 && (0...3).contains(orientation)
            && (0...1).contains(shape) && ((width + 31) / 32) * ((height + 31) / 32) <= 1024
    }
}

public struct HardwareDisplayScene: Equatable, Sendable {
    public var label: String
    public var percent: Int
    public var systemPercent: Int?
    public var available: Bool
    public var muted: Bool
    public var enabled: Bool
    public var pickup: Bool
    public var red: Double
    public var green: Double
    public var blue: Double
    public var roundScreen: HardwareRoundScreen?
    public var roundShowsSystemVolume = false
    public var roundSpectrumTraces: [HardwareSpectrumTrace] = []
    public var roundVolumePosition = 1.0
    public var roundSliderHint: Int?
    public var reduceMotion = false
    public init(
        label: String, percent: Int, systemPercent: Int?, available: Bool = true,
        muted: Bool = false, enabled: Bool = true, pickup: Bool = false,
        red: Double = 0.3, green: Double = 0.65, blue: Double = 1
    ) {
        self.label = label
        self.percent = percent
        self.systemPercent = systemPercent
        self.available = available
        self.muted = muted
        self.enabled = enabled
        self.pickup = pickup
        self.red = red
        self.green = green
        self.blue = blue
    }
}

/// CPU reference renderer retained for comparison benchmarks; live output uses Metal.
@MainActor
public enum HardwareDisplayRenderer {
    public enum RenderError: Error { case unsupportedCapabilities, allocation }
    public static func render(
        _ scene: HardwareDisplayScene, capabilities c: HardwareDisplayCapabilities,
        icon: NSImage? = nil
    ) throws -> Data {
        guard c.supported else { throw RenderError.unsupportedCapabilities }
        let started = DispatchTime.now().uptimeNanoseconds
        guard
            let context = CGContext(
                data: nil, width: c.width, height: c.height, bitsPerComponent: 8,
                bytesPerRow: c.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            let bytes = context.data?.assumingMemoryBound(to: UInt8.self)
        else { throw RenderError.allocation }
        context.setFillColor(NSColor.black.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: c.width, height: c.height))
        context.translateBy(x: 0, y: CGFloat(c.height))
        context.scaleBy(x: CGFloat(c.width) / 240, y: -CGFloat(c.height) / 240)
        if c.shape == 1 {
            context.addEllipse(in: CGRect(x: 0, y: 0, width: 240, height: 240))
            context.clip()
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        defer { NSGraphicsContext.restoreGraphicsState() }
        func component(_ x: Double) -> Double { x.isFinite ? min(1, max(0, x)) : 0 }
        let accent = NSColor(
            srgbRed: component(scene.red), green: component(scene.green), blue: component(scene.blue), alpha: 1)
        context.setFillColor(NSColor(srgbRed: 0.035, green: 0.045, blue: 0.065, alpha: 1).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 240, height: 240))
        context.setStrokeColor(accent.cgColor)
        context.setLineWidth(3)
        context.strokeEllipse(in: CGRect(x: 5, y: 5, width: 230, height: 230))
        func text(_ value: String, y: CGFloat, size: CGFloat, color: NSColor = .white, weight: NSFont.Weight = .medium)
        {
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            style.lineBreakMode = .byTruncatingTail
            (value as NSString).draw(
                in: CGRect(x: 28, y: y, width: 184, height: size * 1.5),
                withAttributes: [
                    .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color,
                    .paragraphStyle: style,
                ])
        }
        text("QEQ", y: 23, size: 15, color: accent, weight: .bold)
        if let icon {
            icon.draw(
                in: CGRect(x: 104, y: 46, width: 32, height: 32), from: .zero, operation: .sourceOver, fraction: 1,
                respectFlipped: true, hints: nil)
        } else {
            text("♪", y: 45, size: 25, color: accent)
        }
        text(scene.label, y: 80, size: 14, weight: .semibold)
        text(scene.available ? "\(scene.percent)%" : "—", y: 99, size: 43, weight: .semibold)
        text(
            !scene.available ? "UNAVAILABLE" : !scene.enabled ? "BYPASSED" : scene.muted ? "MUTED" : "VOLUME",
            y: 150, size: 11, color: scene.muted ? .systemOrange : .lightGray)
        text(scene.systemPercent.map { "SYSTEM  \($0)%" } ?? "SYSTEM  —", y: 175, size: 16)
        text(scene.pickup ? "Move slider to match" : "QEQ hardware", y: 204, size: 10, color: .lightGray)
        var pixels = Data(capacity: c.width * c.height * 2)
        for i in 0..<(c.width * c.height) {
            let rgb =
                UInt16(bytes[i * 4] >> 3) << 11 | UInt16(bytes[i * 4 + 1] >> 2) << 5 | UInt16(bytes[i * 4 + 2] >> 3)
            pixels.append(UInt8(truncatingIfNeeded: rgb))
            pixels.append(UInt8(truncatingIfNeeded: rgb >> 8))
        }
        var result = Data("QRAS".utf8)
        func integer<T: FixedWidthInteger>(_ value: T) {
            var le = value.littleEndian
            withUnsafeBytes(of: &le) { result.append(contentsOf: $0) }
        }
        integer(UInt16(c.width))
        integer(UInt16(c.height))
        result.append(contentsOf: [UInt8(c.format), UInt8(c.orientation), UInt8(c.shape), 0])
        integer(started)
        integer(DispatchTime.now().uptimeNanoseconds - started)
        integer(UInt32(0))
        result.append(pixels)
        return result
    }
}
