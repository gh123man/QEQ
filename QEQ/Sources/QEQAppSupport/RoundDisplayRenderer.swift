import CoreGraphics
import CoreText
import Foundation

public struct HardwareSpectrumTrace: Equatable, Sendable {
    public var bins: [UInt8]
    public var red: Double
    public var green: Double
    public var blue: Double
    public init(bins: [UInt8], red: Double, green: Double, blue: Double) {
        self.bins = bins
        self.red = red
        self.green = green
        self.blue = blue
    }
}

public enum HardwareRoundScreen: Equatable, Sendable {
    public enum Page: Equatable, Sendable { case home, menu, music, app, slider }
    case home([UInt8])
    public struct Item: Equatable, Sendable {
        public var label: String
        public var iconKey: String
        public init(_ label: String, iconKey: String) {
            self.label = label
            self.iconKey = iconKey
        }
    }
    case menu(items: [Item], selected: Int)
    case music(player: String, selected: Int, status: String)
    case app(slider: Bool)

    public var page: Page {
        switch self {
        case .home: .home
        case .menu: .menu
        case .music: .music
        case .app(let slider): slider ? .slider : .app
        }
    }
}

final class RoundDisplayRenderer {
    private struct Volume: Equatable {
        var fraction: Double
        var percent: Double

        init?(scene: HardwareDisplayScene) {
            switch scene.roundScreen?.page {
            case .home:
                guard let value = scene.systemPercent else { return nil }
                fraction = Double(value) / 100
                percent = Double(value)
            case .app, .slider:
                guard scene.available else { return nil }
                fraction = scene.roundVolumePosition
                percent = Double(scene.percent)
            default:
                return nil
            }
            fraction = fraction.isFinite ? min(1, max(0, fraction)) : 0
        }

        func interpolated(from start: Self?, progress: Double) -> Self {
            guard let start, progress < 1 else { return self }
            var result = self
            result.fraction = start.fraction + (fraction - start.fraction) * progress
            result.percent = start.percent + (percent - start.percent) * progress
            return result
        }

        var label: String { "\(Int(percent.rounded()))%" }
    }

    private let caps: HardwareDisplayCapabilities
    private let context: CGContext
    private var target: HardwareDisplayScene?
    private var lastPixels: Data?
    private var outgoing: Data?
    private var transitionStart = 0.0
    private var slideAxis = 0
    private var slideDirection = 1
    private var menuFrom = 0.0
    private var menuPosition = 0.0
    private var menuStart = 0.0
    private var visibilityStart = 0.0
    private var visibilityFrom = 0.0
    private var volumeOpacity = 0.0
    private var volumeStart = 0.0
    private var volumeFrom: Volume?
    private(set) var animating = false

    init(_ caps: HardwareDisplayCapabilities) throws {
        guard caps.supported else { throw HardwareDisplayRenderer.RenderError.unsupportedCapabilities }
        self.caps = caps
        guard
            let context = CGContext(
                data: nil, width: caps.width, height: caps.height, bitsPerComponent: 8,
                bytesPerRow: caps.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            )
        else { throw HardwareDisplayRenderer.RenderError.allocation }
        self.context = context
        context.translateBy(x: 0, y: CGFloat(caps.height))
        context.scaleBy(x: CGFloat(caps.width) / 240, y: -CGFloat(caps.height) / 240)
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
    }

    func render(_ content: HardwareDisplayContent, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Data {
        let scene = content.scene
        guard let screen = scene.roundScreen else { preconditionFailure("Round screen required") }
        let previous = target
        let volume = Volume(scene: scene)
        let previousVolume = previous.flatMap(Volume.init)
        if previous?.roundScreen?.page != screen.page {
            outgoing = scene.reduceMotion ? nil : lastPixels
            slideAxis = screen.page == .slider || previous?.roundScreen?.page == .slider ? 1 : 0
            slideDirection =
                previous?.roundScreen?.page == .slider || screen.page == .home
                    || (screen.page == .menu && previous?.roundScreen?.page != .home) ? -1 : 1
            transitionStart = now
            volumeFrom = volume
        } else if previousVolume != volume {
            // Advance the old easing before retargeting so a stream of knob or
            // slider events cannot restart it at the same value every frame.
            let progress = previous?.reduceMotion == true ? 1 : volumeProgress(at: now)
            volumeFrom = previousVolume?.interpolated(from: volumeFrom, progress: progress)
            volumeStart = now
        }
        var menuMoving = false
        if case .menu(let items, let selected) = screen {
            let destination = Double(min(max(0, selected), max(0, items.count - 1)))
            if case .menu(let oldItems, let oldSelected) = previous?.roundScreen, oldItems == items {
                if oldSelected != selected {
                    menuFrom = menuPosition
                    menuStart = now
                }
            } else {
                menuFrom = destination
                menuStart = now - 1
            }
            let progress = scene.reduceMotion ? 1 : Self.travel((now - menuStart) / 0.28)
            menuPosition = menuFrom + (destination - menuFrom) * progress
            menuMoving = progress < 1 && abs(destination - menuPosition) > 0.001
        }
        let visible = scene.roundShowsSystemVolume ? 1.0 : 0.0
        if previous == nil {
            visibilityFrom = visible
            volumeOpacity = visible
        } else if previous?.roundShowsSystemVolume != scene.roundShowsSystemVolume {
            visibilityFrom = volumeOpacity
            visibilityStart = now
        }
        let visibilityProgress = scene.reduceMotion ? 1 : Self.ease((now - visibilityStart) / 0.16)
        volumeOpacity = visibilityFrom + (visible - visibilityFrom) * visibilityProgress
        let visibilityMoving = visibilityProgress < 1 && visibilityFrom != visible
        target = scene
        let progress = scene.reduceMotion ? 1 : volumeProgress(at: now)
        let displayedVolume = volume?.interpolated(from: volumeFrom, progress: progress)
        let pixels = draw(content, screen: screen, volume: displayedVolume)
        let blend = scene.reduceMotion ? 1 : Self.travel((now - transitionStart) / 0.34)
        if blend >= 1 { outgoing = nil }
        let frame = outgoing.map { slide($0, pixels, fraction: blend) } ?? pixels
        lastPixels = frame
        animating =
            visibilityMoving || menuMoving || outgoing != nil
            || progress < 1 && volumeFrom != nil && volume != nil && volumeFrom != volume
        return clipped(frame)
    }

    private func volumeProgress(at now: TimeInterval) -> Double { Self.ease((now - volumeStart) / 0.18) }

    private static func travel(_ fraction: Double) -> Double {
        let x = min(1, max(0, fraction))
        return 1 - pow(1 - x, 3)
    }

    private static func ease(_ fraction: Double) -> Double {
        let x = min(1, max(0, fraction))
        return x * x * (3 - 2 * x)
    }

    private func draw(_ content: HardwareDisplayContent, screen: HardwareRoundScreen, volume: Volume?) -> Data {
        let scene = content.scene
        let frame = CGRect(x: 0, y: 0, width: 240, height: 240)
        let foreground = CGColor(red: 0.95, green: 0.97, blue: 1, alpha: 1)
        let secondary = CGColor(red: 0.64, green: 0.72, blue: 0.80, alpha: 1)
        let teal = CGColor(red: 0.33, green: 0.91, blue: 0.87, alpha: 1)
        func component(_ x: Double) -> Double { x.isFinite ? min(1, max(0, x)) : 0 }
        let accent =
            max(scene.red, scene.green, scene.blue) < 0.25
            ? teal
            : CGColor(
                red: component(scene.red), green: component(scene.green), blue: component(scene.blue), alpha: 1)
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(frame)
        context.saveGState()
        context.setFillColor(CGColor(red: 0.027, green: 0.046, blue: 0.069, alpha: 1))
        context.fill(frame)

        func text(
            _ value: String, _ y: CGFloat, _ size: CGFloat, color: CGColor? = nil,
            bold: Bool = false, x: CGFloat = 120, width: CGFloat = 174
        ) {
            let font = CTFontCreateUIFontForLanguage(bold ? .emphasizedSystem : .system, size, nil)!
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): color ?? foreground,
            ]
            let line = CTLineCreateWithAttributedString(
                NSAttributedString(string: String(value.prefix(128)), attributes: attributes))
            let ellipsis = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attributes))
            let clipped = CTLineCreateTruncatedLine(line, width, .end, ellipsis) ?? line
            let lineWidth = CTLineGetTypographicBounds(clipped, nil, nil, nil)
            context.textPosition = CGPoint(x: x - lineWidth / 2, y: y)
            CTLineDraw(clipped, context)
        }

        func drawRing(_ color: CGColor) {
            context.setLineWidth(6)
            context.setLineCap(.round)
            context.setStrokeColor(CGColor(red: 0.15, green: 0.21, blue: 0.27, alpha: 1))
            context.strokeEllipse(in: frame.insetBy(dx: 10, dy: 10))
            guard let ring = volume?.fraction, ring > 0 else { return }
            context.setStrokeColor(color)
            context.addArc(
                center: CGPoint(x: 120, y: 120), radius: 110, startAngle: -.pi / 2,
                endAngle: -.pi / 2 + 2 * .pi * ring, clockwise: false)
            context.strokePath()
        }

        func highlight(_ rect: CGRect) {
            context.setFillColor(CGColor(red: 0.087, green: 0.28, blue: 0.28, alpha: 1))
            context.addPath(CGPath(roundedRect: rect, cornerWidth: 8, cornerHeight: 8, transform: nil))
            context.fillPath()
        }

        switch screen {
        case .home(let bins):
            // Same dB scale and bin-centered filled/line paths as SpectrumSurface.
            // The plot extends to the edges and is clipped by the physical circle.
            let plot = CGRect(x: 0, y: 68, width: 240, height: 126)
            for level in [0.0, 0.5, 1.0] {
                context.setStrokeColor(secondary.copy(alpha: 0.10)!)
                context.setLineWidth(0.5)
                context.move(to: CGPoint(x: plot.minX, y: plot.maxY - level * plot.height))
                context.addLine(to: CGPoint(x: plot.maxX, y: plot.maxY - level * plot.height))
                context.strokePath()
            }
            let levels = SpectrumPlotValues(values: bins.map { Double($0) / 255 })
            context.setFillColor(accent.copy(alpha: 0.16)!)
            context.addPath(levels.path(in: plot, filled: true))
            context.fillPath()
            for trace in scene.roundSpectrumTraces {
                let color = CGColor(
                    red: component(trace.red), green: component(trace.green),
                    blue: component(trace.blue), alpha: 0.85)
                context.setStrokeColor(color)
                context.setLineWidth(1)
                context.addPath(SpectrumPlotValues(values: trace.bins.map { Double($0) / 255 }).path(in: plot))
                context.strokePath()
            }
            if volumeOpacity > 0 {
                context.saveGState()
                context.setAlpha(volumeOpacity)
                drawRing(teal)
                context.setFillColor(CGColor(red: 0.027, green: 0.046, blue: 0.069, alpha: 0.92))
                context.addPath(
                    CGPath(
                        roundedRect: CGRect(x: 69, y: 89, width: 102, height: 58),
                        cornerWidth: 14, cornerHeight: 14, transform: nil))
                context.fillPath()
                text(volume?.label ?? "—", 130, 36, bold: true)
                context.restoreGState()
            }
        case .menu(let items, let selected):
            text("QEQ", 42, 10, color: secondary)
            for (index, item) in items.enumerated() {
                let distance = Double(index) - menuPosition
                guard abs(distance) < 2.2 else { continue }
                let scale = 1 - 0.31 * min(1, abs(distance))
                let size = 104 * scale
                let x = 120 + distance * 122
                context.saveGState()
                context.setAlpha(1 - 0.54 * min(1, abs(distance)))
                if let icon = content.menuIcons[item.iconKey] {
                    context.translateBy(x: x, y: 114)
                    context.rotate(by: distance * 0.12)
                    context.scaleBy(x: 1, y: -1)
                    context.draw(icon, in: CGRect(x: -size / 2, y: -size / 2, width: size, height: size))
                } else {
                    highlight(CGRect(x: x - size / 2, y: 114 - size / 2, width: size, height: size))
                    text(item.iconKey == "home" ? "⌂" : "♪", 131, 45, x: x, width: size)
                }
                context.restoreGState()
            }
            if items.indices.contains(selected) { text(items[selected].label, 189, 16, bold: true, width: 180) }
            let visible = min(7, items.count)
            let start = min(max(0, selected - 3), max(0, items.count - visible))
            for index in 0..<visible {
                let active = index + start == selected
                context.setFillColor(active ? teal : secondary.copy(alpha: 0.4)!)
                let width: CGFloat = active ? 12 : 4
                context.fillEllipse(
                    in: CGRect(
                        x: 120 + CGFloat(index) * 10 - CGFloat(visible - 1) * 5 - width / 2,
                        y: 205, width: width, height: 4))
            }
        case .music(let player, let selected, let status):
            text("PLAYBACK", 47, 11, color: secondary)
            text(player, 82, 18, bold: true)
            text(status, 104, 11, color: secondary, width: 159)
            let symbols = ["◀◀", "▶ / Ⅱ", "▶▶"]
            for (i, symbol) in symbols.enumerated() {
                let x = CGFloat(74 + i * 46)
                if selected == i { highlight(CGRect(x: x - 21, y: 119, width: 42, height: 34)) }
                text(symbol, 141, 13, x: x, width: 42)
            }
            if selected == 3 { highlight(CGRect(x: 86, y: 164, width: 68, height: 28)) }
            text("Back", 183, 13, color: selected == 3 ? foreground : secondary)
        case .app(let slider):
            drawRing(accent)
            text(scene.label, 57, 16, bold: true, width: 150)
            if let icon = content.icon {
                context.saveGState()
                context.translateBy(x: 74, y: 151)
                context.scaleBy(x: 1, y: -1)
                context.draw(icon, in: CGRect(x: 0, y: 0, width: 92, height: 92))
                context.restoreGState()
            } else {
                text("♪", 134, 42, color: accent)
            }
            text(volume?.label ?? "—", 187, 31, bold: true)
            let status =
                !scene.available
                ? "Unavailable"
                : !scene.enabled
                    ? "Bypassed"
                    : scene.muted
                        ? "Muted"
                        : slider ? (scene.pickup ? "Move to match" : "Slider 1") : "Press to go back"
            text(status, 206, 11, color: secondary)
        }
        context.restoreGState()
        let count = caps.width * caps.height
        let source = context.data!.assumingMemoryBound(to: UInt8.self)
        var pixels = Data(count: count * 2)
        pixels.withUnsafeMutableBytes { bytes in
            let output = bytes.bindMemory(to: UInt16.self)
            for i in 0..<count {
                let offset = i * 4
                output[i] =
                    UInt16(source[offset] >> 3) << 11 | UInt16(source[offset + 1] >> 2) << 5
                    | UInt16(source[offset + 2] >> 3)
            }
        }
        return pixels
    }

    // Move full rectangular surfaces, then apply the physical circular mask. Masking
    // each surface before translation would leave black crescents inside the screen.
    private func slide(_ from: Data, _ to: Data, fraction: Double) -> Data {
        let width = caps.width
        let height = caps.height
        let extent = slideAxis == 0 ? width : height
        let offset = Int((Double(extent) * fraction).rounded()) * slideDirection
        var result = Data(count: to.count)
        from.withUnsafeBytes { oldBytes in
            to.withUnsafeBytes { newBytes in
                result.withUnsafeMutableBytes { outputBytes in
                    let old = oldBytes.bindMemory(to: UInt16.self)
                    let new = newBytes.bindMemory(to: UInt16.self)
                    let output = outputBytes.bindMemory(to: UInt16.self)
                    for y in 0..<height {
                        for x in 0..<width {
                            let coordinate = (slideAxis == 0 ? x : y) + offset
                            let incoming = coordinate < 0 || coordinate >= extent
                            let source = incoming ? coordinate - extent * slideDirection : coordinate
                            let index = slideAxis == 0 ? y * width + source : source * width + x
                            output[y * width + x] = incoming ? new[index] : old[index]
                        }
                    }
                }
            }
        }
        return result
    }

    private func clipped(_ pixels: Data) -> Data {
        guard caps.shape == 1 else { return pixels }
        var result = pixels
        result.withUnsafeMutableBytes { bytes in
            let output = bytes.bindMemory(to: UInt16.self)
            for y in 0..<caps.height {
                let dy = (Double(y) + 0.5) / Double(caps.height) * 2 - 1
                let halfWidth = sqrt(max(0, 1 - dy * dy)) * Double(caps.width) / 2
                let edge = max(0, Int((Double(caps.width) / 2 - halfWidth).rounded(.up)))
                for x in 0..<edge {
                    output[y * caps.width + x] = 0
                    output[y * caps.width + caps.width - 1 - x] = 0
                }
            }
        }
        return result
    }
}
