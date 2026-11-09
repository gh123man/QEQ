import CoreGraphics
import CoreText
import Foundation
import Metal

/// Offscreen, queue-confined round UI. CoreText/CG only rasterize cached sprites;
/// Metal owns every frame's spectrum, lighting, layout, transitions and RGB565 packing.
final class MetalRoundDisplayRenderer {
    static let minimumTextSize: Float = 14
    private enum Asset {
        case text(String, CGFloat, Bool, CGFloat)
        case icon(CGImage)
    }
    private struct Element {
        var id: String
        var key: String
        var asset: Asset
        var rect: SIMD4<Float>
        var tint = SIMD4<Float>(repeating: 1)
        var clip = SIMD4<Float>(0, 0, 240, 240)
        var rotation: Float = 0
        var edgeFade: Float = 0
    }
    private struct Frame {
        var elements: [Element] = []
        // Home opacity/scale, system volume backdrop, ring opacity.
        var effects = SIMD4<Float>(0, 1, 0, 0)
        var ring = SIMD4<Float>(0, 110, 0, 0)
        var accent = SIMD4<Float>(0.32, 0.89, 0.80, 1)
        var halo = SIMD4<Float>(120, 88, 0, 0)
    }
    private struct Sprite {
        var rect: SIMD4<Float>
        var clip: SIMD4<Float>
        var tint: SIMD4<Float>
        var info: SIMD4<Float>
    }
    private struct Parameters {
        var geometry: SIMD4<UInt32>
        var effects: SIMD4<Float>
        var ring: SIMD4<Float>
        var accent: SIMD4<Float>
        var halo: SIMD4<Float>
    }
    private struct Cached {
        var slice: Int
        var stamp: Int
    }
    private let caps: HardwareDisplayCapabilities
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private let atlas: MTLTexture
    private let output: MTLBuffer
    private let spriteBuffer: MTLBuffer
    private var cache: [String: Cached] = [:]
    private var stamp = 0
    private var previous: HardwareDisplayContent?
    private var visible = Frame()
    private var outgoing: Frame?
    private var transitionStart = 0.0
    private var entering = true
    private var menuPosition: Float = 0
    private var menuFrom: Float = 0
    private var menuStart = 0.0
    private var fraction: Float = 0
    private var percent: Float = 0
    private var systemVisibility: Float = 0
    private var lastTime: Double?
    private var history = Array(repeating: Float(0), count: 4 * 64)
    private var spectrumInitialized = false
    private(set) var animating = false
    private(set) var needsFullRefresh = false
    private var pageMoving = false
    private(set) var rasterizedLayers = 0
    private(set) var renderedFrames = 0
    private(set) var elementRects: [String: SIMD4<Float>] = [:]
    private(set) var displayedVolumeFraction: Float = 0

    init(_ caps: HardwareDisplayCapabilities) throws {
        guard caps.supported else { throw HardwareDisplayRenderer.RenderError.unsupportedCapabilities }
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw MetalHardwareDisplayRenderer.Failure.unavailable
        }
        self.caps = caps
        self.queue = queue
        let library = try device.makeLibrary(source: Self.shader, options: nil)
        guard let kernel = library.makeFunction(name: "roundUI") else {
            throw MetalHardwareDisplayRenderer.Failure.unavailable
        }
        pipeline = try device.makeComputePipelineState(function: kernel)
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type2DArray
        descriptor.pixelFormat = .rgba8Unorm
        descriptor.width = 256
        descriptor.height = 128
        descriptor.arrayLength = 96
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead
        guard let atlas = device.makeTexture(descriptor: descriptor),
            let output = device.makeBuffer(length: caps.width * caps.height * 2, options: .storageModeShared),
            let sprites = device.makeBuffer(length: 96 * MemoryLayout<Sprite>.stride, options: .storageModeShared)
        else { throw MetalHardwareDisplayRenderer.Failure.allocation }
        self.atlas = atlas
        self.output = output
        spriteBuffer = sprites
    }

    func render(_ content: HardwareDisplayContent, now: Double = ProcessInfo.processInfo.systemUptime) throws -> Data {
        guard let screen = content.scene.roundScreen else { preconditionFailure("Round screen required") }
        let scene = content.scene
        let oldScreen = previous?.scene.roundScreen
        let changedPage = identity(content) != previous.map(identity)
        let dt = Float(min(0.1, max(0, now - (lastTime ?? now))))
        lastTime = now
        let reduced = scene.reduceMotion
        let isHome = screen.page == .home
        let targetFraction = Self.unit(isHome ? Double(scene.systemPercent ?? 0) / 100 : scene.roundVolumePosition)
        let targetPercent = Float(isHome ? scene.systemPercent ?? 0 : scene.percent)
        if previous == nil || changedPage || reduced {
            fraction = targetFraction
            percent = targetPercent
        } else {
            let progress = 1 - exp(-dt / 0.045)
            fraction += (targetFraction - fraction) * progress
            percent += (targetPercent - percent) * progress
            if abs(fraction - targetFraction) < 0.0005 { fraction = targetFraction }
            if abs(percent - targetPercent) < 0.05 { percent = targetPercent }
        }
        let systemTarget: Float = isHome && scene.roundShowsSystemVolume ? 1 : 0
        if previous == nil || reduced {
            systemVisibility = systemTarget
        } else {
            systemVisibility += (systemTarget - systemVisibility) * (1 - exp(-dt / 0.055))
            if abs(systemVisibility - systemTarget) < 0.005 { systemVisibility = systemTarget }
        }
        var menuMoving = false
        if let carousel = screen.carousel {
            let destination = Float(min(max(0, carousel.selected), max(0, carousel.items.count - 1)))
            if oldScreen?.carousel?.key != carousel.key {
                menuPosition = destination
                menuFrom = destination
                menuStart = now - 1
            } else if oldScreen?.carousel?.selected != carousel.selected {
                menuFrom = menuPosition
                menuStart = now
            }
            let p = reduced ? 1 : Self.travel(Float((now - menuStart) / 0.25))
            menuPosition = menuFrom + (destination - menuFrom) * p
            menuMoving = p < 1 && abs(destination - menuPosition) > 0.001
        }
        let destination = makeFrame(content)
        if changedPage {
            outgoing = previous == nil || reduced ? nil : visible
            transitionStart = now
            entering = screen.page.navigationDepth > (oldScreen?.page.navigationDepth ?? 0)
        }
        let transition = reduced ? 1 : Self.travel(Float((now - transitionStart) / 0.34))
        visible = outgoing.map { blend($0, destination, progress: transition) } ?? destination
        if transition >= 1 { outgoing = nil }
        // Repair at page boundaries, not after every rotary detent or volume
        // overlay; a redundant full-frame write there would itself cause stalls.
        let nextPageMoving = outgoing != nil
        needsFullRefresh = pageMoving && !nextPageMoving || changedPage && reduced
        pageMoving = nextPageMoving
        let spectrumMoving = updateSpectrum(content, dt: dt)
        animating =
            outgoing != nil || menuMoving || systemVisibility != systemTarget
            || abs(fraction - targetFraction) > 0.0005 || abs(percent - targetPercent) > 0.05
            || (isHome && spectrumMoving && !reduced)
        previous = content
        elementRects = Dictionary(visible.elements.map { ($0.id, $0.rect) }, uniquingKeysWith: { _, last in last })
        displayedVolumeFraction = visible.ring.x
        return try compose(visible, content: content)
    }

    private func identity(_ content: HardwareDisplayContent) -> String {
        guard let screen = content.scene.roundScreen else { return "" }
        switch screen {
        case .appActions(let id, _, _, _): return "actions." + id
        case .slots(let id, _, _, _): return "slots." + id
        case .app(let slider): return "app.\(slider)." + content.iconKey
        default: return String(describing: screen.page)
        }
    }
    private static func unit(_ value: Double) -> Float { Float(value.isFinite ? min(1, max(0, value)) : 0) }
    private static func travel(_ value: Float) -> Float { 1 - pow(1 - min(1, max(0, value)), 3) }

    private func makeFrame(_ content: HardwareDisplayContent) -> Frame {
        let scene = content.scene
        let screen = scene.roundScreen!
        var frame = Frame()
        let white = SIMD4<Float>(0.95, 0.98, 1, 1)
        let secondary = SIMD4<Float>(0.64, 0.74, 0.79, 1)
        let appID = content.iconKey
        func text(
            _ id: String, _ value: String, _ y: Float, _ size: Float, width: Float = 174,
            bold: Bool = false, color: SIMD4<Float>? = nil, x: Float = 120
        ) {
            guard !value.isEmpty else { return }
            let size = max(Self.minimumTextSize, size)
            let height = size * 1.5
            frame.elements.append(
                Element(
                    id: id, key: "text.\(value).\(size).\(bold).\(width)",
                    asset: .text(String(value.prefix(128)), CGFloat(size), bold, CGFloat(width)),
                    rect: SIMD4(x - width / 2, y - height / 2, width, height), tint: color ?? white))
        }
        func icon(_ id: String, _ image: CGImage?, _ rect: SIMD4<Float>) {
            if let image {
                frame.elements.append(Element(id: "icon." + id, key: "icon." + id, asset: .icon(image), rect: rect))
            } else {
                text("icon." + id, "♪", rect.y + rect.w / 2, rect.w * 0.65, width: rect.z, x: rect.x + rect.z / 2)
            }
        }
        let isApp = [.appActions, .slots, .app, .slider].contains(screen.page)
        if isApp {
            frame.accent = SIMD4(Self.unit(scene.red), Self.unit(scene.green), Self.unit(scene.blue), 1)
            if max(frame.accent.x, frame.accent.y, frame.accent.z) < 0.25 { frame.accent = SIMD4(0.32, 0.89, 0.80, 1) }
            frame.ring.x = scene.available ? fraction : 0
            frame.effects.w = 1
            frame.halo.z = 0.16
        }
        switch screen {
        case .home:
            frame.effects = SIMD4(1, 1, systemVisibility, systemVisibility)
            frame.ring = SIMD4(fraction, 110 + 26 * (1 - systemVisibility), 0, 0)
            if systemVisibility > 0 {
                text("system.value", "\(Int(percent.rounded()))%", 137, 34, width: 120, bold: true)
                frame.elements[frame.elements.count - 1].tint.w = systemVisibility
            }
        case .menu, .appActions, .slots:
            let carousel = screen.carousel!
            let compact = screen.page != .menu
            if compact {
                text("app.title." + appID, carousel.title, 32, 13, width: 144, bold: true)
                icon(appID, content.icon, SIMD4(82, 48, 76, 76))
                text("app.percent", scene.available ? "\(Int(percent.rounded()))%" : "—", 140, 19, bold: true)
            }
            for (index, item) in carousel.items.enumerated() {
                let distance = Float(index) - menuPosition
                guard abs(distance) < 2.6 else { continue }
                let size: Float = (compact ? 48 : 104) * (1 - 0.18 * min(1, abs(distance)))
                let x: Float = 120 + distance * (compact ? 56 : 122)
                let y: Float = compact ? 172 : 114
                icon(item.iconKey, content.menuIcons[item.iconKey], SIMD4(x - size / 2, y - size / 2, size, size))
                let i = frame.elements.count - 1
                frame.elements[i].tint.w = (1 - 0.54 * min(1, abs(distance))) * (item.enabled ? 1 : 0.3)
                frame.elements[i].edgeFade = 1
            }
            if carousel.items.indices.contains(carousel.selected) {
                let item = carousel.items[carousel.selected]
                text(
                    "carousel.label", item.label, compact ? 201 : 184, compact ? 14 : 16, width: compact ? 144 : 180,
                    bold: true, color: item.enabled ? white : secondary)
                text(
                    "carousel.detail", item.detail, compact ? 218 : 204, 14, width: compact ? 132 : 174,
                    color: secondary)
            }
            if !compact {
                let count = min(7, carousel.items.count)
                let start = min(max(0, carousel.selected - 3), max(0, carousel.items.count - count))
                for i in 0..<count {
                    text(
                        "dot.\(i)", "•", 210, i + start == carousel.selected ? 17 : 12, width: 10,
                        color: i + start == carousel.selected ? frame.accent : secondary * SIMD4(1, 1, 1, 0.4),
                        x: 120 + Float(i) * 10 - Float(count - 1) * 5)
                }
            }
        case .app(let slider):
            text("app.title." + appID, scene.label, 50, 16, width: 150, bold: true)
            icon(appID, content.icon, SIMD4(74, 64, 92, 92))
            frame.halo.y = 110
            text("app.percent", scene.available ? "\(Int(percent.rounded()))%" : "—", 180, 31, bold: true)
            let status =
                !scene.available
                ? "Unavailable"
                : !scene.enabled
                    ? "Bypassed"
                    : scene.muted
                        ? "Muted"
                        : slider && scene.pickup ? "Pickup" : ""
            text("app.status", scene.roundSliderHint.map { "Use slider \($0)" } ?? status, 204, 11, color: secondary)
        case .music(let player, let selected, let status):
            text("music.heading", "PLAYBACK", 43, 11, color: secondary)
            text("music.player", player, 77, 18, bold: true)
            text("music.status", status, 100, 11, width: 159, color: secondary)
            for (i, symbol) in ["↩", "◀◀", "▶ / Ⅱ", "▶▶"].enumerated() {
                text(
                    "music.action.\(i)", symbol, 139, 18,
                    width: 46, bold: selected == i, color: selected == i ? frame.accent : secondary,
                    x: Float(48 + i * 48))
            }
            text("music.selection", ["Back", "Previous", "Play / Pause", "Next"][min(3, max(0, selected))], 183, 14)
        }
        return frame
    }

    private func blend(_ from: Frame, _ to: Frame, progress p: Float) -> Frame {
        guard p < 1 else { return to }
        guard p > 0 else { return from }
        var result = Frame()
        result.effects = from.effects + (to.effects - from.effects) * p
        result.ring = from.ring + (to.ring - from.ring) * p
        result.accent = from.accent + (to.accent - from.accent) * p
        result.halo = from.halo + (to.halo - from.halo) * p
        // The spectrum falls back while navigation advances, and rises on return.
        if from.effects.x > to.effects.x {
            result.effects.y = 1 - 0.12 * p
        } else if to.effects.x > from.effects.x {
            result.effects.y = 0.88 + 0.12 * p
        }
        let old = Dictionary(from.elements.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let newIDs = Set(to.elements.map(\.id))
        func transformed(_ element: Element, scale: Float, opacity: Float, offset: Float) -> Element {
            var e = element
            e.rect = SIMD4(
                120 + (e.rect.x - 120) * scale, 120 + (e.rect.y - 120) * scale + offset,
                e.rect.z * scale, e.rect.w * scale)
            e.tint.w *= opacity
            return e
        }
        for target in to.elements {
            if let source = old[target.id] {
                var e = target
                e.rect = source.rect + (target.rect - source.rect) * p
                e.clip = source.clip + (target.clip - source.clip) * p
                e.rotation = source.rotation + (target.rotation - source.rotation) * p
                e.edgeFade = source.edgeFade + (target.edgeFade - source.edgeFade) * p
                e.tint = source.tint + (target.tint - source.tint) * p
                if source.key != target.key {
                    var fading = source
                    fading.rect = e.rect
                    fading.clip = e.clip
                    fading.tint.w *= 1 - p
                    result.elements.append(fading)
                    e.tint.w *= p
                }
                result.elements.append(e)
            } else {
                result.elements.append(
                    transformed(
                        target, scale: entering ? 1 + 0.24 * (1 - p) : 0.88 + 0.12 * p,
                        opacity: p, offset: entering ? -12 * (1 - p) : 0))
            }
        }
        for source in from.elements where !newIDs.contains(source.id) {
            result.elements.append(
                transformed(
                    source, scale: entering ? 1 - 0.12 * p : 1 + 0.24 * p,
                    opacity: 1 - p, offset: entering ? 0 : -12 * p))
        }
        return result
    }

    private func resample(_ bins: [UInt8]) -> [Float] {
        guard !bins.isEmpty else { return Array(repeating: 0, count: 64) }
        return (0..<64).map { i in
            let x = Float(i) / 63 * Float(bins.count - 1)
            let a = Int(x)
            let b = min(a + 1, bins.count - 1)
            return (Float(bins[a]) + (Float(bins[b]) - Float(bins[a])) * (x - Float(a))) / 255
        }
    }
    private func updateSpectrum(_ content: HardwareDisplayContent, dt: Float) -> Bool {
        guard case .home(let bins) = content.scene.roundScreen else { return false }
        let values = resample(bins)
        var moving = false
        for layer in 0..<4 {
            for i in 0..<64 {
                let index = layer * 64 + i
                let target = layer == 0 ? values[i] : history[(layer - 1) * 64 + i]
                let speed: Float = layer == 0 ? (target > history[index] ? 0.025 : 0.10) : 0.065
                if !spectrumInitialized || content.scene.reduceMotion {
                    history[index] = target
                } else {
                    history[index] += (target - history[index]) * (1 - exp(-dt / speed))
                }
                if abs(history[index] - target) < 0.001 { history[index] = target } else { moving = true }
            }
        }
        spectrumInitialized = true
        return moving
    }

    private func texture(_ element: Element, protected: Set<String>) throws -> Int {
        if var item = cache[element.key] {
            item.stamp = stamp
            cache[element.key] = item
            return item.slice
        }
        let slice: Int
        if cache.count < 96 {
            slice = cache.count
        } else {
            guard
                let victim = cache.filter({ !protected.contains($0.key) }).min(by: { $0.value.stamp < $1.value.stamp })
            else {
                throw MetalHardwareDisplayRenderer.Failure.allocation
            }
            slice = victim.value.slice
            cache.removeValue(forKey: victim.key)
        }
        guard
            let context = CGContext(
                data: nil, width: 256, height: 128, bitsPerComponent: 8, bytesPerRow: 256 * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
        else { throw MetalHardwareDisplayRenderer.Failure.allocation }
        switch element.asset {
        case .icon(let image): context.draw(image, in: CGRect(x: 0, y: 0, width: 256, height: 128))
        case .text(let value, let size, let bold, let width):
            // Raster dimensions are based on the asset, not its animated rectangle.
            let height = size * 1.5
            context.translateBy(x: 0, y: 128)
            context.scaleBy(x: 256 / max(1, width), y: -128 / height)
            context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
            let font = CTFontCreateUIFontForLanguage(bold ? .emphasizedSystem : .system, size, nil)!
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1),
            ]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: value, attributes: attributes))
            let ellipsis = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attributes))
            let clipped = CTLineCreateTruncatedLine(line, width, .end, ellipsis) ?? line
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            let length = CTLineGetTypographicBounds(clipped, &ascent, &descent, nil)
            context.textPosition = CGPoint(x: (width - length) / 2, y: (height + ascent - descent) / 2)
            CTLineDraw(clipped, context)
        }
        atlas.replace(
            region: MTLRegionMake2D(0, 0, 256, 128), mipmapLevel: 0, slice: slice,
            withBytes: context.data!, bytesPerRow: 256 * 4, bytesPerImage: 256 * 128 * 4)
        cache[element.key] = Cached(slice: slice, stamp: stamp)
        rasterizedLayers += 1
        return slice
    }

    private func compose(_ frame: Frame, content: HardwareDisplayContent) throws -> Data {
        stamp += 1
        let elements = Array(frame.elements.filter { $0.tint.w > 0.001 }.prefix(96))
        let protected = Set(elements.map(\.key))
        let sprites = try elements.map { element in
            Sprite(
                rect: element.rect, clip: element.clip, tint: element.tint,
                info: SIMD4(Float(try texture(element, protected: protected)), element.rotation, element.edgeFade, 0))
        }
        sprites.withUnsafeBytes { bytes in
            if let base = bytes.baseAddress { spriteBuffer.contents().copyMemory(from: base, byteCount: bytes.count) }
        }
        var bins = history
        var colors: [SIMD4<Float>] = []
        for index in 0..<4 {
            if content.scene.roundSpectrumTraces.indices.contains(index) {
                let trace = content.scene.roundSpectrumTraces[index]
                bins += resample(trace.bins)
                colors.append(SIMD4(Self.unit(trace.red), Self.unit(trace.green), Self.unit(trace.blue), 0.35))
            } else {
                bins += Array(repeating: 0, count: 64)
                colors.append(.zero)
            }
        }
        var parameters = Parameters(
            geometry: SIMD4(UInt32(caps.width), UInt32(caps.height), UInt32(sprites.count), UInt32(caps.shape)),
            effects: frame.effects, ring: frame.ring, accent: frame.accent, halo: frame.halo)
        guard let commands = queue.makeCommandBuffer(), let encoder = commands.makeComputeCommandEncoder() else {
            throw MetalHardwareDisplayRenderer.Failure.allocation
        }
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(atlas, index: 0)
        encoder.setBuffer(output, offset: 0, index: 0)
        encoder.setBytes(&parameters, length: MemoryLayout<Parameters>.stride, index: 1)
        encoder.setBuffer(spriteBuffer, offset: 0, index: 2)
        bins.withUnsafeBytes { encoder.setBytes($0.baseAddress!, length: $0.count, index: 3) }
        colors.withUnsafeBytes { encoder.setBytes($0.baseAddress!, length: $0.count, index: 4) }
        encoder.dispatchThreads(
            MTLSize(width: caps.width, height: caps.height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 16, height: 8, depth: 1))
        encoder.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        guard commands.status == .completed else { throw MetalHardwareDisplayRenderer.Failure.gpu }
        renderedFrames += 1
        return Data(bytes: output.contents(), count: caps.width * caps.height * 2)
    }

    private static let shader = """
        #include <metal_stdlib>
        using namespace metal;
        struct Sprite { float4 rect; float4 clip; float4 tint; float4 info; };
        struct Params { uint4 geometry; float4 effects; float4 ring; float4 accent; float4 halo; };
        float spectrum(constant float *bins, uint layer, float x) {
            float sample = clamp(x / 240.0 * 63.0, 0.0, 63.0);
            uint a = uint(sample), b = min(a + 1, 63u);
            return mix(bins[layer * 64 + a], bins[layer * 64 + b], fract(sample));
        }
        float roundedBox(float2 p, float2 extent, float radius) {
            float2 q = abs(p) - extent + radius;
            return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - radius;
        }
        kernel void roundUI(texture2d_array<float> atlas [[texture(0)]], device ushort *pixels [[buffer(0)]],
                            constant Params &p [[buffer(1)]], device const Sprite *sprites [[buffer(2)]],
                            constant float *bins [[buffer(3)]], constant float4 *traceColors [[buffer(4)]],
                            uint2 gid [[thread_position_in_grid]]) {
            if (gid.x >= p.geometry.x || gid.y >= p.geometry.y) return;
            float2 q = (float2(gid) + 0.5) * float2(240.0 / p.geometry.x, 240.0 / p.geometry.y);
            float radius = length(q - 120.0);
            float3 color = float3(0.016, 0.035, 0.053);
            float3 teal = float3(0.32, 0.89, 0.80);
            if (p.effects.x > 0.001) {
                float2 s = (q - 120.0) / p.effects.y + 120.0;
                float3 luminous = float3(0);
                float3 fillColor = float3(0);
                // Real spectrum bins on the app's horizontal dB scale. Trails carry
                // recent samples, never invented motion or random particles.
                for (int layer = 3; layer >= 0; --layer) {
                    float level = spectrum(bins, layer, s.x);
                    float y = 194.0 - level * 126.0 + layer * 3.0;
                    float d = abs(s.y - y);
                    float strength = layer == 0 ? 1.0 : 0.12;
                    float line = exp(-d*d / (layer == 0 ? 1.1 : 2.0));
                    float bloom = layer == 0 ? 0.32 * exp(-d*d/32.0) + 0.12 * exp(-d*d/320.0) : 0.0;
                    // Anchor the fill to the screen, not the moving crest. The
                    // bottom stays visually continuous and byte-identical while
                    // only the luminous edge/history need USB updates.
                    float fill = smoothstep(y-1.0, y+1.0, s.y) * (0.08 + 0.15 * clamp((240.0-s.y)/155.0,0.0,1.0));
                    luminous += teal * (line * strength + bloom);
                    fillColor += teal * fill * (layer == 0 ? 1.0 : 0.12);
                }
                // RGB565 has only 32 red/blue levels. A shared luminance palette
                // keeps the glow coherent and creates compressible color runs.
                luminous = teal * (round(luminous.g / teal.g * 31.0) / 31.0);
                luminous += fillColor;
                for (uint layer = 0; layer < 4; ++layer) {
                    float y = 194.0 - spectrum(bins, layer + 4, s.x) * 126.0;
                    luminous += traceColors[layer].rgb * traceColors[layer].a * exp(-pow(s.y-y,2.0)/1.5);
                }
                color += luminous * p.effects.x;
            }
            color += p.accent.rgb * p.halo.z * exp(-dot(q-p.halo.xy,q-p.halo.xy)/3300.0);
            if (p.effects.w > 0.001) {
                float d = abs(radius-p.ring.y);
                color = mix(color, float3(0.10,0.19,0.22), (1.0-smoothstep(2.0,3.0,d))*p.effects.w);
                float angle = atan2(q.x-120.0,120.0-q.y);
                if (angle < 0) angle += 2*M_PI_F;
                float end = p.ring.x * 2*M_PI_F;
                if (angle <= end && p.ring.x > 0) {
                    float core = 1.0-smoothstep(1.5,2.5,d);
                    color = mix(color,p.accent.rgb,core*p.effects.w);
                    color += p.accent.rgb * (0.25*exp(-d*d/22.0)) * p.effects.w;
                }
                if (p.ring.x > 0) {
                    float2 tip = 120.0 + float2(sin(end),-cos(end))*p.ring.y;
                    color += float3(0.6,0.8,0.8)*exp(-dot(q-tip,q-tip)/6.0)*p.effects.w;
                }
            }
            if (p.effects.z > 0.001) {
                float scale = 1.0 + 0.20*(1-p.effects.z);
                float2 v = (q-120.0)/scale+120.0;
                float box = 1.0-smoothstep(-0.5,0.5,roundedBox(v-float2(120,116),float2(53,48),22));
                color = mix(color,float3(0.025,0.065,0.09),box*0.94*p.effects.z);
                // Speaker pictogram stays vector sharp, including during arrival.
                float speaker = (v.x>=101 && v.x<=108 && v.y>=90 && v.y<=102) ||
                    (v.x>108 && v.x<=117 && abs(v.y-96)<=6+(v.x-108)*0.7) ? 1.0 : 0.0;
                float2 wave = v-float2(117,96);
                if (wave.x>2 && abs(atan2(wave.y,wave.x))<0.8) {
                    float arc = min(abs(length(wave)-13),abs(length(wave)-20));
                    speaker=max(speaker,1.0-smoothstep(0.8,1.8,arc));
                }
                color=mix(color,float3(0.95,0.98,1),speaker*p.effects.z);
            }
            constexpr sampler linearSampler(coord::normalized, address::clamp_to_zero, filter::linear);
            for (uint i=0;i<p.geometry.z;++i) {
                Sprite e=sprites[i];
                if (q.x<e.clip.x || q.y<e.clip.y || q.x>e.clip.x+e.clip.z || q.y>e.clip.y+e.clip.w) continue;
                float2 center=e.rect.xy+e.rect.zw*0.5;
                float2 local=q-center;
                float cs=cos(e.info.y), sn=sin(e.info.y);
                local=float2(cs*local.x+sn*local.y,-sn*local.x+cs*local.y);
                float2 uv=local/e.rect.zw+0.5;
                if (any(uv<0.0) || any(uv>1.0)) continue;
                float4 texel=atlas.sample(linearSampler,uv,uint(e.info.x));
                float sideDistance=sqrt(max(0.0,14400.0-pow(q.y-120.0,2.0)))-abs(q.x-120.0);
                texel*=mix(1.0,smoothstep(4.0,34.0,sideDistance),e.info.z);
                color=texel.rgb*e.tint.rgb*e.tint.a+color*(1-texel.a*e.tint.a);
            }
            // Fixed spatial dithering softens RGB565 gradient bands without
            // temporal noise that would defeat unchanged-tile compression.
            const float bayer[16]={0,8,2,10,12,4,14,6,3,11,1,9,15,7,13,5};
            float dither=p.effects.x>0.001 ? 0.0 : (bayer[(gid.y%4)*4+gid.x%4]+0.5)/16.0-0.5;
            float3 levels=float3(31,63,31);
            uint3 rgb=uint3(round(clamp(color+dither/levels,0.0,1.0)*levels));
            if (p.geometry.w==1 && radius>120) rgb=uint3(0);
            pixels[gid.y*p.geometry.x+gid.x]=ushort((rgb.r<<11)|(rgb.g<<5)|rgb.b);
        }
        """
}
