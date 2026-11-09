import CoreGraphics
import CoreText
import Foundation
import Metal

/// Immutable CGImage snapshots may cross queues; NSImage/AppKit objects never do.
struct HardwareDisplayContent: @unchecked Sendable, Equatable {
    var scene: HardwareDisplayScene
    var icon: CGImage?
    var iconKey: String
    var menuIcons: [String: CGImage] = [:]
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.scene == rhs.scene && lhs.iconKey == rhs.iconKey }
}

/// Queue-confined offscreen renderer. No CAMetalLayer/drawable or display-link loop is needed
/// for an external panel: Metal composes cached text/icon layers directly into shared RGB565.
public final class MetalHardwareDisplayRenderer {
    public enum Failure: Error { case unavailable, allocation, gpu }
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private let layers: MTLTexture
    private let output: MTLBuffer
    private let capabilities: HardwareDisplayCapabilities
    private let layerHeight: Int
    private var previousKeys = Array(repeating: "", count: 7)
    private var textCache: [String: Data] = [:]
    public private(set) var renderedFrames = 0
    public private(set) var rasterizedLayers = 0
    private struct Parameters {
        var width: UInt32
        var height: UInt32
        var shape: UInt32
        var layerHeight: UInt32
        var accent: SIMD4<Float>
    }
    public init(capabilities: HardwareDisplayCapabilities) throws {
        guard capabilities.supported else { throw HardwareDisplayRenderer.RenderError.unsupportedCapabilities }
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw Failure.unavailable
        }
        self.device = device
        commandQueue = queue
        self.capabilities = capabilities
        let library = try device.makeLibrary(source: Self.shader, options: nil)
        guard let kernel = library.makeFunction(name: "compose") else { throw Failure.unavailable }
        pipeline = try device.makeComputePipelineState(function: kernel)
        layerHeight = Int(ceil(Double(capabilities.height) * 70 / 240))
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type2DArray
        descriptor.pixelFormat = .rgba8Unorm
        descriptor.width = capabilities.width
        descriptor.height = layerHeight
        descriptor.arrayLength = 7
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor),
            let buffer = device.makeBuffer(
                length: capabilities.width * capabilities.height * 2, options: .storageModeShared)
        else { throw Failure.allocation }
        layers = texture
        output = buffer
    }

    public func render(_ scene: HardwareDisplayScene, icon: CGImage? = nil, iconKey: String = "") throws -> Data {
        func component(_ value: Double) -> Float { Float(value.isFinite ? min(1, max(0, value)) : 0) }
        let accent = SIMD4<Float>(component(scene.red), component(scene.green), component(scene.blue), 1)
        let gray = SIMD4<Float>(0.827, 0.827, 0.827, 1)
        let white = SIMD4<Float>(repeating: 1)
        let status = !scene.available ? "UNAVAILABLE" : !scene.enabled ? "BYPASSED" : scene.muted ? "MUTED" : "VOLUME"
        let items: [(String, Double, Bool, SIMD4<Float>)] = [
            ("QEQ", 15, true, accent), ("♪", 25, false, accent),
            (String(scene.label.prefix(128)), 14, true, white),
            (scene.available ? "\(scene.percent)%" : "—", 43, true, white),
            (status, 11, false, scene.muted ? SIMD4<Float>(1, 0.58, 0, 1) : gray),
            (scene.systemPercent.map { "SYSTEM  \($0)%" } ?? "SYSTEM  —", 16, false, white),
            (scene.pickup ? "Move slider to match" : "QEQ hardware", 10, false, gray),
        ]
        for (index, item) in items.enumerated() {
            let key = index == 1 && icon != nil ? "icon:\(iconKey)" : "\(item.0)|\(item.1)|\(item.2)|\(item.3)"
            guard key != previousKeys[index] else { continue }
            let data: Data
            if index == 1, let icon {
                data = try rasterIcon(icon)
            } else if let cached = textCache[key] {
                data = cached
            } else {
                data = try rasterText(item.0, size: item.1, bold: item.2, color: item.3)
                if textCache.count >= 64 { textCache.removeAll(keepingCapacity: true) }
                textCache[key] = data
            }
            data.withUnsafeBytes { bytes in
                layers.replace(
                    region: MTLRegionMake2D(0, 0, capabilities.width, layerHeight), mipmapLevel: 0,
                    slice: index, withBytes: bytes.baseAddress!, bytesPerRow: capabilities.width * 4,
                    bytesPerImage: data.count)
            }
            rasterizedLayers += 1
            previousKeys[index] = key
        }
        guard let commands = commandQueue.makeCommandBuffer(), let encoder = commands.makeComputeCommandEncoder() else {
            throw Failure.allocation
        }
        var parameters = Parameters(
            width: UInt32(capabilities.width), height: UInt32(capabilities.height),
            shape: UInt32(capabilities.shape), layerHeight: UInt32(layerHeight), accent: accent)
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(layers, index: 0)
        encoder.setBuffer(output, offset: 0, index: 0)
        encoder.setBytes(&parameters, length: MemoryLayout<Parameters>.stride, index: 1)
        encoder.dispatchThreads(
            MTLSize(width: capabilities.width, height: capabilities.height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 16, height: 8, depth: 1))
        encoder.endEncoding()
        commands.commit()
        // Only the display's background worker waits; the app/main/audio actors never block on GPU/USB.
        commands.waitUntilCompleted()
        guard commands.status == .completed else { throw Failure.gpu }
        renderedFrames += 1
        return Data(bytes: output.contents(), count: capabilities.width * capabilities.height * 2)
    }

    private func context() throws -> CGContext {
        guard
            let context = CGContext(
                data: nil, width: capabilities.width, height: layerHeight,
                bitsPerComponent: 8, bytesPerRow: capabilities.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
        else { throw Failure.allocation }
        return context
    }
    private func rasterText(_ text: String, size: Double, bold: Bool, color: SIMD4<Float>) throws -> Data {
        let context = try context()
        let scaleX = Double(capabilities.width) / 240
        let scaleY = Double(capabilities.height) / 240
        context.translateBy(x: 0, y: CGFloat(layerHeight))
        context.scaleBy(x: scaleX, y: -scaleY)
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        let base = CTFontCreateUIFontForLanguage(bold ? .emphasizedSystem : .system, size, nil)!
        let cgColor = CGColor(
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
            components: [CGFloat(color.x), CGFloat(color.y), CGFloat(color.z), 1])!
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): base,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): cgColor,
        ]
        let original = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        let ellipsis = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attributes))
        let line = CTLineCreateTruncatedLine(original, 184, .end, ellipsis) ?? original
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let width = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        context.textPosition = CGPoint(x: (240 - width) / 2, y: ascent + 1)
        CTLineDraw(line, context)
        return Data(bytes: context.data!, count: capabilities.width * layerHeight * 4)
    }
    private func rasterIcon(_ image: CGImage) throws -> Data {
        let context = try context()
        context.translateBy(x: 0, y: CGFloat(layerHeight))
        context.scaleBy(x: Double(capabilities.width) / 240, y: -Double(capabilities.height) / 240)
        // CoreGraphics images use an opposite Y axis to the display's top-left coordinates.
        context.translateBy(x: 104, y: 32)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(x: 0, y: 0, width: 32, height: 32))
        return Data(bytes: context.data!, count: capabilities.width * layerHeight * 4)
    }

    private static let shader = """
        #include <metal_stdlib>
        using namespace metal;
        struct Parameters { uint width; uint height; uint shape; uint layerHeight; float4 accent; };
        kernel void compose(texture2d_array<float, access::read> layers [[texture(0)]],
                            device ushort *pixels [[buffer(0)]], constant Parameters &p [[buffer(1)]],
                            uint2 gid [[thread_position_in_grid]]) {
            if (gid.x >= p.width || gid.y >= p.height) return;
            float2 point = (float2(gid) + 0.5) * float2(240.0 / p.width, 240.0 / p.height);
            float distance = length(point - float2(120));
            float3 color = float3(0.035, 0.045, 0.065);
            float edge = 240.0 / min(p.width, p.height);
            float ring = 1.0 - smoothstep(1.0, 1.0 + edge, abs(distance - 115.0));
            color = mix(color, p.accent.rgb, ring);
            const float positions[7] = {23,46,80,99,150,175,204};
            for (uint layer = 0; layer < 7; ++layer) {
                int y = int(gid.y) - int(round(positions[layer] * p.height / 240.0));
                if (y >= 0 && y < int(p.layerHeight)) {
                    float4 sprite = layers.read(uint2(gid.x, uint(y)), layer);
                    color = sprite.rgb + color * (1.0 - sprite.a);
                }
            }
            if (p.shape == 1 && distance > 120.0) color = float3(0);
            uint3 rgb = uint3(round(clamp(color, 0.0, 1.0) * 255.0));
            pixels[gid.y * p.width + gid.x] = ushort(((rgb.r >> 3) << 11) | ((rgb.g >> 2) << 5) | (rgb.b >> 3));
        }
        """
}
