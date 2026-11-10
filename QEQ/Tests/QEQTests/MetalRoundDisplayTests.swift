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
    _ = try renderer.render(content, now: 2.6)
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
    #expect(try renderer.render(content, now: 5.15) == settled)
    let arriving = try renderer.render(content, now: 5.30)
    #expect(arriving != settled && renderer.animating)
    let volume = try renderer.render(content, now: 5.45)
    #expect(volume != arriving && !renderer.animating)
    content.scene.roundShowsSystemVolume = false
    #expect(try renderer.render(content, now: 7.60) == volume)
    let leaving = try renderer.render(content, now: 7.75)
    #expect(leaving != volume && leaving != settled && renderer.animating)
    #expect(try renderer.render(content, now: 7.90) == settled)
    #expect(!renderer.animating)
    content.scene.reduceMotion = true
    content.scene.roundShowsSystemVolume = true
    #expect(try renderer.render(content, now: 8.10) == volume)
    content.scene.roundShowsSystemVolume = false
    #expect(try renderer.render(content, now: 8.20) == settled)
    #expect(!renderer.animating)
    let landscape = try MetalRoundDisplayRenderer(HardwareDisplayCapabilities(width: 320, height: 180, shape: 0))
    #expect(try landscape.render(content, now: 1).count == 320 * 180 * 2)
}

@Test func metalCarouselRetargetsVisibleGeometryAndKeepsAppHeaderStable() throws {
    guard ProcessInfo.processInfo.environment["QEQ_HARDWARE_TESTS"] != "0" else { return }
    let renderer = try MetalRoundDisplayRenderer(HardwareDisplayCapabilities())
    let items: [HardwareRoundScreen.Item] = [
        .init("Music", iconKey: "music"), .init("Spotify", iconKey: "spotify"),
        .init("Visualizer", iconKey: "visualizer"),
    ]
    var scene = HardwareDisplayScene(label: "Music", percent: 50, systemPercent: 50)
    scene.roundVolumePosition = 0.5
    scene.roundScreen = .menu(items: items, selected: 0)
    var content = HardwareDisplayContent(scene: scene, icon: nil, iconKey: "music")
    _ = try renderer.render(content, now: 1)
    content.scene.roundScreen = .menu(items: items, selected: 2)
    _ = try renderer.render(content, now: 2)
    _ = try renderer.render(content, now: 2.1)
    let moving = renderer.elementRects.filter { $0.key.hasPrefix("icon.") }
    content.scene.roundScreen = .menu(items: items, selected: 0)
    _ = try renderer.render(content, now: 2.1)
    #expect(renderer.elementRects.filter { $0.key.hasPrefix("icon.") } == moving)
    _ = try renderer.render(content, now: 2.5)
    #expect(!renderer.animating)
    content.scene.reduceMotion = true
    for slots in [false, true] {
        func page(_ selected: Int) -> HardwareRoundScreen {
            slots
                ? .slots(appID: "music", title: "Music", items: items, selected: selected)
                : .appActions(appID: "music", title: "Music", items: items, selected: selected)
        }
        content.scene.roundScreen = page(0)
        let first = try renderer.render(content, now: 3)
        content.scene.roundScreen = page(1)
        let second = try renderer.render(content, now: 4)
        #expect(first.prefix(240 * 150 * 2) == second.prefix(240 * 150 * 2))
        #expect(first != second && !renderer.animating)
        content.scene.roundVolumePosition = 1
        #expect(try renderer.render(content, now: 5) != second)
        content.scene.roundVolumePosition = 0.5
    }
}

@Test func metalSliderOverlayFadesAnUnfocusedAppInPlace() throws {
    guard ProcessInfo.processInfo.environment["QEQ_HARDWARE_TESTS"] != "0" else { return }
    let renderer = try MetalRoundDisplayRenderer(HardwareDisplayCapabilities())
    let context = CGContext(
        data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 128,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
    let icon = context.makeImage()!
    let items: [HardwareRoundScreen.Item] = [
        .init("Music", iconKey: "music"), .init("Spotify", iconKey: "spotify"),
        .init("RuneLite", iconKey: "runelite"),
    ]
    var scene = HardwareDisplayScene(label: "RuneLite", percent: 50, systemPercent: nil)
    scene.roundVolumePosition = 0.5
    scene.roundScreen = .menu(items: items, selected: 1)
    var content = HardwareDisplayContent(
        scene: scene, icon: icon, iconKey: "runelite", menuIcons: ["music": icon, "spotify": icon, "runelite": icon])
    let menu = try renderer.render(content, now: 1)
    // Check both neighbors near the circular edge in the actual RGB565 output.
    for x in [8, 231] {
        let pixel = (114 * 240 + x) * 2
        let red = menu[pixel + 1] >> 3
        #expect(red >= 10)
    }
    let side = renderer.elementRects["icon.runelite"]!
    content.scene.roundScreen = .app(slider: true)
    #expect(try renderer.render(content, now: 2) == menu)
    let fading = try renderer.render(content, now: 2.1)
    let center = SIMD4<Float>(74, 64, 92, 92)
    #expect(renderer.elementRects["icon.runelite"] == center)
    let settled = try renderer.render(content, now: 2.5)
    #expect(fading != menu && fading != settled)
    content.scene.roundScreen = .menu(items: items, selected: 1)
    _ = try renderer.render(content, now: 3)
    _ = try renderer.render(content, now: 3.1)
    #expect(renderer.elementRects["icon.runelite"] == side)
    #expect(try renderer.render(content, now: 3.5) == menu)
    content.iconKey = "spotify"
    content.scene.roundScreen = .app(slider: true)
    _ = try renderer.render(content, now: 4)
    _ = try renderer.render(content, now: 4.1)
    let moving = renderer.elementRects["icon.spotify"]!
    #expect(moving.z > center.z && moving.z < 104)
}
