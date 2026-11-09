import CoreGraphics
import Foundation
import Testing

@testable import QEQAppSupport

@Test func metalRoundCachesSpritesAndConnectsTheSelectedApp() throws {
    guard ProcessInfo.processInfo.environment["QEQ_HARDWARE_TESTS"] != "0" else { return }
    let renderer = try MetalRoundDisplayRenderer(HardwareDisplayCapabilities())
    let context = CGContext(
        data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 128,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
    let icon = context.makeImage()!
    var scene = HardwareDisplayScene(label: "Music", percent: 65, systemPercent: nil)
    scene.roundVolumePosition = 0.65
    scene.roundScreen = .menu(items: [.init("Music", iconKey: "music")], selected: 0)
    var content = HardwareDisplayContent(scene: scene, icon: icon, iconKey: "music", menuIcons: ["music": icon])
    let menu = try renderer.render(content, now: 1)
    let cached = renderer.rasterizedLayers
    #expect(try renderer.render(content, now: 1.5) == menu)
    #expect(renderer.rasterizedLayers == cached)
    #expect(menu.count == 240 * 240 * 2 && menu[0] == 0 && menu[1] == 0)
    let start = renderer.elementRects["icon.music"]!
    content.scene.roundScreen = .appActions(
        appID: "music", title: "Music", items: [.init("Boost", iconKey: "boost")], selected: 0)
    #expect(try renderer.render(content, now: 2) == menu)
    _ = try renderer.render(content, now: 2.1)
    let moving = renderer.elementRects["icon.music"]!
    #expect(moving.z < start.z && moving.z > 76)
    #expect(moving.y < start.y && moving.y > 48)
    #expect(renderer.animating)
    _ = try renderer.render(content, now: 2.5)
    #expect(renderer.needsFullRefresh)
    _ = try renderer.render(content, now: 2.6)
    #expect(!renderer.needsFullRefresh)
    #expect(renderer.elementRects["icon.music"] == SIMD4<Float>(82, 48, 76, 76))
    #expect(!renderer.animating)
    content.scene.roundScreen = .app(slider: false)
    let beforeVolume = try renderer.render(content, now: 3)
    _ = try renderer.render(content, now: 3.1)
    #expect(abs(renderer.displayedVolumeFraction - 0.65) < 0.001)
    #expect(renderer.elementRects["icon.music"]!.z > 76)
    // Reverse an in-progress transition without jumping back to either endpoint.
    let interrupted = renderer.elementRects["icon.music"]!
    content.scene.roundScreen = .menu(items: [.init("Music", iconKey: "music")], selected: 0)
    _ = try renderer.render(content, now: 3.1)
    #expect(renderer.elementRects["icon.music"] == interrupted)
    content.scene.reduceMotion = true
    #expect(try renderer.render(content, now: 3.2) != beforeVolume)
    #expect(!renderer.animating)
    // Churn beyond the atlas capacity: current sprites must survive LRU eviction.
    content.scene.roundScreen = .app(slider: false)
    for i in 0..<220 {
        content.scene.percent = i
        content.scene.roundVolumePosition = Double(i) / 220
        _ = try renderer.render(content, now: Double(i + 4))
    }
    let last = try renderer.render(content, now: 230)
    let count = renderer.rasterizedLayers
    #expect(try renderer.render(content, now: 231) == last)
    #expect(renderer.rasterizedLayers == count)
}

@Test func metalRoundSpectrumSettlesAndHomeRingOnlyAppearsDuringAdjustment() throws {
    guard ProcessInfo.processInfo.environment["QEQ_HARDWARE_TESTS"] != "0" else { return }
    let renderer = try MetalRoundDisplayRenderer(HardwareDisplayCapabilities())
    var scene = HardwareDisplayScene(label: "", percent: 0, systemPercent: 65)
    scene.roundScreen = .home(Array(repeating: 20, count: 32))
    var content = HardwareDisplayContent(scene: scene, icon: nil, iconKey: "round")
    let quiet = try renderer.render(content, now: 1)
    #expect(!renderer.animating)
    content.scene.roundScreen = .home(Array(repeating: 180, count: 32))
    let loud = try renderer.render(content, now: 1.04)
    #expect(loud != quiet && renderer.animating)
    for i in 1...100 { _ = try renderer.render(content, now: 1.04 + Double(i) / 30) }
    #expect(!renderer.animating)
    let settled = try renderer.render(content, now: 5)
    #expect(try renderer.render(content, now: 5.1) == settled)
    content.scene.roundShowsSystemVolume = true
    _ = try renderer.render(content, now: 5.15)
    #expect(renderer.animating)
    content.scene.reduceMotion = true
    let volume = try renderer.render(content, now: 5.2)
    #expect(volume != settled && !renderer.animating)
    content.scene.roundShowsSystemVolume = false
    #expect(try renderer.render(content, now: 5.3) == settled)
    let landscape = try MetalRoundDisplayRenderer(HardwareDisplayCapabilities(width: 320, height: 180, shape: 0))
    #expect(try landscape.render(content, now: 1).count == 320 * 180 * 2)
}
