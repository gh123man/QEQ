import AppKit
import AppMixerAppSupport
import AppMixerCore
import QuartzCore
import SwiftUI

/// Render our own views with explicit fixture data. No screen capture, live audio,
/// preferences, Accessibility or automation access is involved.
@MainActor
struct ScreenshotRenderer {
    static func render(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let model = MixerModel(preview: true)
        model.snapshot.outputName = "MacBook Pro Speakers"
        model.snapshot.timing = "256 frames · 5.3 ms I/O buffer · 48 kHz"
        let host = NSHostingController(
            rootView: MixerView(model: model).environment(\.controlActiveState, .active).id("empty"))
        host.sizingOptions = [.preferredContentSize]
        let window = NSWindow(
            contentRect: NSRect(x: -8000, y: 0, width: 500, height: 240),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentViewController = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        func layout() -> CGSize {
            for _ in 0..<8 {
                RunLoop.current.run(until: Date().addingTimeInterval(0.035))
                host.view.layoutSubtreeIfNeeded()
                let size = host.view.fittingSize
                window.setContentSize(size)
                host.view.displayIfNeeded()
                CATransaction.flush()
            }
            return host.view.bounds.size
        }
        func capture(_ name: String, maximum: CGFloat) throws {
            let size = layout()
            guard size.height <= maximum + 1, size.height > 120 else {
                throw NSError(
                    domain: "QEQ screenshots", code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey: "Unexpected \(name) height: \(size.height), maximum \(maximum)"
                    ])
            }
            let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2),
                pixelsHigh: Int(size.height * 2), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            bitmap.size = size
            host.view.cacheDisplay(in: host.view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(
                to: directory.appendingPathComponent(name + ".png"))
            print("\(name): \(Int(size.width)) × \(Int(size.height)) pt")
        }
        try capture("empty", maximum: 300)
        func app(_ id: String, _ name: String, _ path: String) -> AudioApplication {
            AudioApplication(
                id: id, name: name, path: FileManager.default.fileExists(atPath: path) ? path : nil, playing: true)
        }
        let zoom = app("com.apple.FaceTime", "FaceTime", "/System/Applications/FaceTime.app")
        let music = app("com.spotify.client", "Spotify", "/Applications/Spotify.app")
        let chrome = app("com.google.Chrome", "Google Chrome", "/Applications/Google Chrome.app")
        model.snapshot.apps = [zoom, chrome, music]
        model.enabled = true
        var zoomEQ = MixerSettings()
        zoomEQ.bass = -12
        zoomEQ.volume = 0.8
        var musicEQ = MixerSettings()
        musicEQ.volume = 0.65
        model.settings = [zoom.id: zoomEQ, music.id: musicEQ]
        model.snapshot.active = [zoom.id, music.id]
        host.rootView = MixerView(model: model).environment(\.controlActiveState, .active).id("mixer")
        try capture("mixer", maximum: 500)
        model.snapshot.apps = [zoom]
        model.selectedEQ = zoom.id
        // Deliberately show the response preview, not fabricated live spectrum.
        model.enabled = false
        host.rootView = MixerView(model: model).environment(\.controlActiveState, .active).id("equalizer")
        try capture("equalizer", maximum: 720)
        model.snapshot.apps = (0..<15).map {
            AudioApplication(id: "sample-\($0)", name: "Sample app \($0 + 1)", playing: true)
        }
        model.selectedEQ = nil
        let longSize = layout()
        guard abs(longSize.height - 720) <= 1 else { throw NSError(domain: "QEQ layout", code: 2) }
        print("long list capped: \(Int(longSize.height)) pt")
        model.maximumPanelHeight = 460
        let smallScreenSize = layout()
        guard abs(smallScreenSize.height - 460) <= 1 else { throw NSError(domain: "QEQ layout", code: 3) }
        print("small-screen cap: \(Int(smallScreenSize.height)) pt")
        model.snapshot.apps = []
        try capture("empty-after-removal", maximum: 300)
    }
}
