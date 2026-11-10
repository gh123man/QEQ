import Foundation
import QEQAppSupport
import Testing

@Test func metalDisplayUsesNegotiatedGeometryAndDeterministicPixelBytes() throws {
    guard ProcessInfo.processInfo.environment["QEQ_HARDWARE_TESTS"] != "0" else { return }
    var scene = HardwareDisplayScene(label: "Music", percent: 56, systemPercent: 42)
    scene.reduceMotion = true
    let content = HardwareDisplayContent(scene: scene, icon: nil, iconKey: "music")
    for caps in [
        HardwareDisplayCapabilities(), HardwareDisplayCapabilities(width: 320, height: 180, orientation: 1, shape: 0),
    ] {
        let renderer = try MetalRoundDisplayRenderer(caps)
        let first = try renderer.render(content, now: 1)
        #expect(first.count == caps.width * caps.height * 2)
        #expect(try renderer.render(content, now: 2) == first)
        if caps.shape == 1 { #expect(first[0] == 0 && first[1] == 0) }
    }
    #expect(throws: MetalRoundDisplayRenderer.Failure.self) {
        try MetalRoundDisplayRenderer(HardwareDisplayCapabilities(width: 0))
    }
    #expect(throws: MetalRoundDisplayRenderer.Failure.self) {
        try MetalRoundDisplayRenderer(HardwareDisplayCapabilities(format: 2))
    }
}
