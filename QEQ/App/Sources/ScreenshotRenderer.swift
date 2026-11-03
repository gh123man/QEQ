import AppKit
import QEQAppSupport
import QEQCore
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
        // Standalone crops have no desktop backdrop, so supply an opaque backing.
        // DesktopScreenshot separately composites its illustrated wallpaper to
        // approximate the live panel's behind-window translucency.
        let host = NSHostingController(
            rootView: MixerView(model: model).background(Color(nsColor: .windowBackgroundColor)).environment(
                \.controlActiveState, .active
            ).id("empty"))
        host.sizingOptions = [.preferredContentSize]
        let window = NSWindow(
            contentRect: NSRect(x: -8000, y: 0, width: 500, height: 240),
            styleMask: .borderless, backing: .buffered, defer: false)
        let lightAppearance = ProcessInfo.processInfo.environment["QEQ_SCREENSHOT_APPEARANCE"] == "light"
        window.appearance = NSAppearance(named: lightAppearance ? .aqua : .darkAqua)
        window.contentViewController = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        func layout() -> CGSize {
            for _ in 0..<12 {
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
            ScreenshotControls.prepare(in: host.view)
            host.view.cacheDisplay(in: host.view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(
                to: directory.appendingPathComponent(name + ".png"))
            print("\(name): \(Int(size.width)) × \(Int(size.height)) pt")
        }
        try capture("empty", maximum: 520)
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
        // Deterministic illustrative spectra: never capture audio or claim these
        // fixtures are live. Apply the displayed EQ/volume to each sample shape.
        let sourceSpectra = [
            music.id: ScreenshotAudio.spectrum(.music),
            zoom.id: ScreenshotAudio.spectrum(.voice),
            chrome.id: ScreenshotAudio.spectrum(.browser),
        ]
        func simulateSpectra() {
            var combined = AudioTelemetry()
            combined.simulated = true
            combined.spectrum = [Float](repeating: -90, count: 96)
            model.snapshot.active = Set(model.snapshot.apps.map(\.id))
            for app in model.snapshot.apps {
                var value = AudioTelemetry()
                value.simulated = true
                let settings = model.value(app.id)
                for index in 0..<96 {
                    let hz = 20 * pow(1000, (Double(index) + 0.5) / 96)
                    let measured = Double(sourceSpectra[app.id]?[index] ?? -90)
                    let eq =
                        settings.responseDB(at: hz, sampleRate: 48000)
                        + model.globalEQ.responseDB(at: hz, sampleRate: 48000)
                    let db = Float(max(-90, min(0, measured + eq + 20 * log10(settings.volume))))
                    value.spectrum.append(db)
                    combined.spectrum[index] = max(combined.spectrum[index], db)
                }
                value.peak = app.id == music.id ? 0.22 : (app.id == zoom.id ? 0.08 : 0.13)
                combined.peak = max(combined.peak, value.peak)
                combined.apps[app.id] = value
            }
            model.telemetry = combined
        }
        simulateSpectra()
        host.rootView = MixerView(model: model).background(Color(nsColor: .windowBackgroundColor)).environment(
            \.controlActiveState, .active
        ).id("mixer")
        try capture("mixer", maximum: MixerModel.panelHeightLimit)
        try DesktopScreenshot.render(
            model: model, panelHeight: layout().height, appearance: window.appearance,
            to: directory.appendingPathComponent("desktop-mixer.png"))
        model.snapshot.apps = [zoom, chrome, music]
        model.selectedEQ = zoom.id
        simulateSpectra()
        host.rootView = MixerView(model: model).background(Color(nsColor: .windowBackgroundColor)).environment(
            \.controlActiveState, .active
        ).id("equalizer")
        try capture("equalizer", maximum: MixerModel.panelHeightLimit)
        try DesktopScreenshot.render(
            model: model, panelHeight: layout().height, appearance: window.appearance,
            to: directory.appendingPathComponent("desktop-app-equalizer.png"))
        model.snapshot.apps = [zoom]
        model.globalEQ.bands = EQPreset.warm.bands
        model.selectedEQ = MixerModel.globalEQID
        simulateSpectra()
        host.rootView = MixerView(model: model).background(Color(nsColor: .windowBackgroundColor)).environment(
            \.controlActiveState, .active
        ).id("global-equalizer")
        try capture("global-equalizer", maximum: MixerModel.panelHeightLimit)
        model.snapshot.apps = (0..<15).map {
            AudioApplication(id: "sample-\($0)", name: "Sample app \($0 + 1)", playing: true)
        }
        model.selectedEQ = nil
        model.enabled = false
        model.telemetry = AudioTelemetry()
        let longSize = layout()
        guard abs(longSize.height - MixerModel.panelHeightLimit) <= 1 else {
            throw NSError(domain: "QEQ layout", code: 2)
        }
        print("long list capped: \(Int(longSize.height)) pt")
        model.maximumPanelHeight = 460
        let smallScreenSize = layout()
        guard abs(smallScreenSize.height - 460) <= 1 else { throw NSError(domain: "QEQ layout", code: 3) }
        print("small-screen cap: \(Int(smallScreenSize.height)) pt")
        model.snapshot.apps = []
        try capture("empty-after-removal", maximum: 520)
        let updates = UpdateStore(
            currentVersion: "0.1.0", distribution: true, defaults: nil,
            previewUpdate: AvailableUpdate(version: "0.1.1"))
        model.maximumPanelHeight = MixerModel.panelHeightLimit
        model.snapshot.apps = [zoom, chrome, music]
        model.enabled = true
        simulateSpectra()
        host.rootView = MixerView(model: model, updates: updates).background(Color(nsColor: .windowBackgroundColor))
            .environment(
                \.controlActiveState, .active
            ).id("update-available")
        try capture("update-available", maximum: MixerModel.panelHeightLimit)
        try renderSettings(to: directory, appearance: window.appearance, updates: updates)
        try renderSettings(to: directory, appearance: window.appearance, updates: updates, showExclusions: true)
    }
    private static func renderSettings(
        to directory: URL, appearance: NSAppearance?, updates: UpdateStore, showExclusions: Bool = false
    ) throws {
        let host = NSHostingController(
            rootView: SettingsView(
                updates: updates, loginItem: .preview(), exclusions: AppExclusions(defaults: nil), preview: true,
                showExclusions: showExclusions
            ) { "Fixture diagnostics" })
        let window = NSWindow(
            contentRect: NSRect(x: -8000, y: 0, width: 470, height: 620),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentViewController = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        for _ in 0..<12 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.035))
            host.view.layoutSubtreeIfNeeded()
            host.view.displayIfNeeded()
            CATransaction.flush()
        }
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 940, pixelsHigh: 1240,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0)!
        bitmap.size = NSSize(width: 470, height: 620)
        ScreenshotControls.prepare(in: host.view)
        host.view.cacheDisplay(in: host.view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(
            to: directory.appendingPathComponent(showExclusions ? "excluded-apps.png" : "settings.png"))
        print("settings: 470 × 620 pt")
    }

}
