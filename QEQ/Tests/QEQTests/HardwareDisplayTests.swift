import Foundation
import Testing
import QEQAppSupport

@Test @MainActor func hardwareRasterUsesNegotiatedGeometryAndExactPixelBytes() throws {
    let scene = HardwareDisplayScene(label: "Music", percent: 56, systemPercent: 42)
    for c in [HardwareDisplayCapabilities(), HardwareDisplayCapabilities(width: 320, height: 180, orientation: 1, shape: 0)] {
        let first = try HardwareDisplayRenderer.render(scene, capabilities: c)
        let second = try HardwareDisplayRenderer.render(scene, capabilities: c)
        #expect(first.count == 32 + c.width * c.height * 2)
        #expect(Array(first.prefix(4)) == Array("QRAS".utf8))
        #expect(Int(first[4]) + Int(first[5]) * 256 == c.width)
        #expect(Int(first[6]) + Int(first[7]) * 256 == c.height)
        #expect(first[8] == 1 && first[9] == c.orientation && first[10] == c.shape)
        #expect(first.dropFirst(32) == second.dropFirst(32))
        if c.shape == 1 { #expect(first[32] == 0 && first[33] == 0) }
    }
    #expect(throws: HardwareDisplayRenderer.RenderError.self) {
        try HardwareDisplayRenderer.render(scene, capabilities: HardwareDisplayCapabilities(width: 0))
    }
    #expect(throws: HardwareDisplayRenderer.RenderError.self) {
        try HardwareDisplayRenderer.render(scene, capabilities: HardwareDisplayCapabilities(format: 2))
    }
}
