import AppKit
import Darwin
import QEQAppSupport

@MainActor
func compareRenderers(directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let caps = HardwareDisplayCapabilities()
    let metal = try MetalHardwareDisplayRenderer(capabilities: caps)
    let appPath = "/System/Applications/Music.app"
    let image = NSWorkspace.shared.icon(forFile: appPath)
    var rect = CGRect(x: 0, y: 0, width: 64, height: 64)
    let icon = image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    var scene = HardwareDisplayScene(label: "Music", percent: 50, systemPercent: 64, red: 0.95, green: 0.2, blue: 0.35)
    func cpu() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }
    func measure(_ body: (HardwareDisplayScene) throws -> Data) throws -> [String: Double] {
        for i in 0..<20 {
            scene.percent = i
            _ = try body(scene)
        }
        let cpuStart = cpu()
        let wallStart = ProcessInfo.processInfo.systemUptime
        for i in 0..<500 {
            scene.percent = i % 101
            _ = try autoreleasepool { try body(scene) }
        }
        return [
            "frames": 500, "cpu_ms_per_frame": (cpu() - cpuStart) * 1000 / 500,
            "wall_ms_per_frame": (ProcessInfo.processInfo.systemUptime - wallStart) * 1000 / 500,
        ]
    }
    let reference = try measure { try HardwareDisplayRenderer.render($0, capabilities: caps, icon: image) }
    let gpu = try measure { try metal.render($0, icon: icon, iconKey: "Music") }
    scene.percent = 50
    let pixels = try metal.render(scene, icon: icon, iconKey: "Music")
    var rgba = Data(count: caps.width * caps.height * 4)
    rgba.withUnsafeMutableBytes { bytes in
        let target = bytes.bindMemory(to: UInt8.self)
        for i in 0..<(caps.width * caps.height) {
            let value = UInt16(pixels[i * 2]) | UInt16(pixels[i * 2 + 1]) << 8
            target[i * 4] = UInt8((value >> 11) * 255 / 31)
            target[i * 4 + 1] = UInt8(((value >> 5) & 63) * 255 / 63)
            target[i * 4 + 2] = UInt8((value & 31) * 255 / 31)
            target[i * 4 + 3] = 255
        }
    }
    let provider = CGDataProvider(data: rgba as CFData)!
    let cg = CGImage(
        width: caps.width, height: caps.height, bitsPerComponent: 8, bitsPerPixel: 32,
        bytesPerRow: caps.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider,
        decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    let bitmap = NSBitmapImageRep(cgImage: cg)
    try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("metal.png"))
    let result: [String: Any] = [
        "reference": reference, "metal": gpu,
        "metal_rasterized_layers": metal.rasterizedLayers,
        "note":
            "Process CPU includes driver work; warmed release builds, 500 changing scenes. No USB hardware or physical display latency measured.",
    ]
    let json = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
    try json.write(to: directory.appendingPathComponent("renderers.json"))
    print(String(decoding: json, as: UTF8.self))
}
