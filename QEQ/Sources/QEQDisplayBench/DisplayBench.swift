import AppKit
import QEQAppSupport
@preconcurrency import QEQHardware
import os

/// Current UI workload, optionally sent through the production USB session at a 30 Hz target.
@main struct DisplayBench {
    @MainActor static func main() throws {
        let args = CommandLine.arguments
        guard args.count >= 2, args[1].hasPrefix("/") else {
            fatalError(
                "Usage: QEQDisplayBench ABS_OUTPUT [--stream SERIAL] [--legacy-tiles] [--refresh-boundaries ABS_MANIFEST]"
            )
        }
        var serial: String?
        var boundaries: String?
        var partialTiles = true
        var argument = 2
        while argument < args.count {
            switch args[argument] {
            case "--stream", "--refresh-boundaries":
                guard argument + 1 < args.count else { fatalError("Missing argument for \(args[argument])") }
                if args[argument] == "--stream" { serial = args[argument + 1] } else { boundaries = args[argument + 1] }
                argument += 2
            case "--legacy-tiles":
                partialTiles = false
                argument += 1
            default: fatalError("Unknown option: \(args[argument])")
            }
        }
        var forceRefresh = Set<String>()
        if let boundaries {
            let manifest =
                try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: boundaries)))
                as! [String: Any]
            for row in manifest["frames"] as! [[String: Any]] where row["force_full"] as? Bool == true {
                forceRefresh.insert(row["file"] as! String)
            }
        }
        var link: HardwareDisplayBenchmark?
        if let serial {
            let discovery = QEQUSBDiscovery()
            let found = OSAllocatedUnfairLock(initialState: [QEQUSBDevice]())
            let ready = DispatchSemaphore(value: 0)
            discovery.start { devices in
                let matching = devices.filter { $0.serial == serial }
                if matching.count == 1 {
                    found.withLock { $0 = matching }
                    ready.signal()
                }
            }
            let result = ready.wait(timeout: .now() + 5)
            discovery.stop()
            guard result == .success, let device = found.withLock({ $0.first }) else {
                fatalError("Exactly one display with serial \(serial) must be attached")
            }
            link = try HardwareDisplayBenchmark(device: device, partialTiles: partialTiles)
            print(
                "Connected \(serial), partial tiles: \(link!.partialTiles). Stop QEQ's display client before benchmarking."
            )
        }
        let directory = URL(fileURLWithPath: args[1], isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let caps = link?.capabilities ?? HardwareDisplayCapabilities()
        guard caps.width == 240, caps.height == 240, caps.shape == 1 else {
            fatalError("This workload requires the 240x240 round display")
        }
        let renderer = try MetalRoundDisplayRenderer(caps)
        let capabilityJSON: [String: Int] = [
            "width": 240, "height": 240, "format": 1, "orientation": 0, "shape": 1,
            "tile_width": 32, "tile_height": 32, "max_payload": 2064, "spi_hz": 40_000_000, "boot": 0,
        ]
        try JSONSerialization.data(withJSONObject: capabilityJSON, options: [.sortedKeys])
            .write(to: directory.appendingPathComponent("capabilities.json"))
        var icons: [String: CGImage] = [:]
        for (key, path) in [
            ("music", "/System/Applications/Music.app"), ("safari", "/Applications/Safari.app"),
            ("spotify", "/Applications/Spotify.app"),
        ] {
            var rect = CGRect(x: 0, y: 0, width: 128, height: 128)
            icons[key] = NSWorkspace.shared.icon(forFile: path).cgImage(
                forProposedRect: &rect, context: nil, hints: nil)
        }
        let menu: [HardwareRoundScreen.Item] = [
            .init("Music", iconKey: "music"), .init("Spotify", iconKey: "spotify"),
            .init("Safari", iconKey: "safari"), .init("Home", iconKey: "home"),
        ]
        let actions: [HardwareRoundScreen.Item] = [
            .init("Boost", iconKey: "boost", detail: "Off"), .init("Mute", iconKey: "mute", detail: "Off"),
            .init("Volume", iconKey: "volume"), .init("Slot", iconKey: "slot"), .init("Back", iconKey: "back"),
        ]
        let slots = (1...4).map { HardwareRoundScreen.Item("Slot \($0)", iconKey: "slot\($0)", detail: "Available") }
        var frames: [[String: Any]] = []
        for frame in 0..<600 {
            try autoreleasepool {
                let time = Double(frame) / 30 + 1
                var scene = HardwareDisplayScene(
                    label: "Music", percent: 65, systemPercent: 62, red: 0.95, green: 0.2, blue: 0.35)
                scene.roundVolumePosition = 0.65
                let phase: String
                switch frame {
                case 0..<180, 570..<600:
                    phase = "spectrum"
                    // Deterministic synthetic spectrum, explicitly not captured audio.
                    let bins = (0..<192).map { index -> UInt8 in
                        let x = Double(index)
                        let wave = 0.5 + 0.5 * sin(x * 0.11 + time * 3.7)
                        let envelope = 0.5 + 0.5 * sin(x * 0.027 - time * 1.3)
                        return UInt8(min(235, max(0, 25 + 150 * wave * envelope)))
                    }
                    scene.roundScreen = .home(bins)
                case 180..<270:
                    phase = "menu"
                    scene.roundScreen = .menu(items: menu, selected: min(3, (frame - 180) / 24))
                case 270..<360:
                    phase = "actions"
                    scene.roundScreen = .appActions(
                        appID: "music", title: "Music", items: actions, selected: min(4, (frame - 270) / 18))
                case 360..<420:
                    phase = "slots"
                    scene.roundScreen = .slots(
                        appID: "music", title: "Music", items: slots, selected: min(3, (frame - 360) / 15))
                case 420..<540:
                    phase = frame < 510 ? "volume" : "slider"
                    scene.percent = Int(50 + 45 * sin(Double(frame - 420) * 0.08))
                    scene.roundVolumePosition = Double(scene.percent) / 100
                    scene.roundScreen = .app(slider: frame >= 510)
                default:
                    phase = "playback"
                    scene.roundScreen = .music(player: "Music", selected: (frame - 540) / 10, status: "Playing")
                }
                let content = HardwareDisplayContent(
                    scene: scene, icon: icons["music"], iconKey: "music", menuIcons: icons)
                let start = DispatchTime.now().uptimeNanoseconds
                let pixels = try renderer.render(content, now: time)
                let duration = DispatchTime.now().uptimeNanoseconds - start
                let name = String(format: "%04d-%@.qras", frame, phase)
                var row: [String: Any] = [
                    "file": name, "phase": phase, "render_us": Double(duration) / 1000,
                    "force_full": forceRefresh.contains(name), "animating": renderer.animating,
                ]
                if let link {
                    for (key, value) in try link.send(pixels, forceFull: forceRefresh.contains(name)) {
                        row[key] = value
                    }
                    let total = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
                    row["total_ms"] = total
                    frames.append(row)
                    Thread.sleep(forTimeInterval: max(0, 1.0 / 30 - total / 1000))
                    return
                }
                var raster = Data("QRAS".utf8)
                func put<T: FixedWidthInteger>(_ value: T) {
                    var little = value.littleEndian
                    withUnsafeBytes(of: &little) { raster.append(contentsOf: $0) }
                }
                put(UInt16(caps.width))
                put(UInt16(caps.height))
                raster.append(contentsOf: [1, 0, 1, 0])
                put(start)
                put(duration)
                put(UInt32(0))
                raster.append(pixels)
                try raster.write(to: directory.appendingPathComponent(name))
                frames.append(row)
            }
        }
        let report: [String: Any] = [
            "renderer": "MetalRoundDisplayRenderer", "frames": frames, "sample_hz": 30,
            "mode": link == nil ? "offline" : "live", "partial_tiles": link?.partialTiles ?? false,
            "note":
                "Production GPU UI; deterministic synthetic spectrum/navigation. Live total_ms covers rendering, planning, encoding and SPI-complete ACK; offline timings cover rendering only. Neither measures visible panel scanout.",
        ]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("workload.json"))
        print(
            "Rendered 600 frames with the production Metal round UI: spectrum, menu, actions, slots, volume, slider, playback."
        )
    }
}
