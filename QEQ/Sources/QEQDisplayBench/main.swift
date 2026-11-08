import AppKit
import QEQAppSupport

@main struct DisplayBench {
    @MainActor static func main() throws {
        guard CommandLine.arguments.count == 2 else { fatalError("Usage: QEQDisplayBench ABSOLUTE_OUTPUT_DIRECTORY") }
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let capabilityURL = directory.appendingPathComponent("capabilities.json")
        let caps: HardwareDisplayCapabilities
        if FileManager.default.fileExists(atPath: capabilityURL.path) {
            caps = try JSONDecoder().decode(HardwareDisplayCapabilities.self, from: Data(contentsOf: capabilityURL))
        } else {
            caps = HardwareDisplayCapabilities()
            let json: [String: Int] = ["width": 240, "height": 240, "format": 1, "orientation": 0, "shape": 1,
                                      "tile_width": 32, "tile_height": 32, "max_payload": 2064, "spi_hz": 10_000_000, "boot": 0]
            try JSONSerialization.data(withJSONObject: json, options: .sortedKeys).write(to: capabilityURL)
        }
        let apps = [("Music", "/System/Applications/Music.app", 0.95, 0.2, 0.35),
                    ("Safari", "/Applications/Safari.app", 0.2, 0.6, 1.0),
                    ("Spotify", "/Applications/Spotify.app", 0.15, 0.8, 0.4)]
        var index = 0
        for (name, path, r, g, b) in apps {
            let icon = FileManager.default.fileExists(atPath: path) ? NSWorkspace.shared.icon(forFile: path) : nil
            for volume in stride(from: 0, through: 100, by: 5) {
                let scene = HardwareDisplayScene(label: name, percent: volume, systemPercent: 64,
                                                 pickup: volume == 0, red: r, green: g, blue: b)
                let data = try HardwareDisplayRenderer.render(scene, capabilities: caps, icon: icon)
                try data.write(to: directory.appendingPathComponent(String(format: "%03d-%@-volume.qras", index, name)))
                index += 1
            }
            for state in 0..<4 {
                let scene = HardwareDisplayScene(label: name, percent: 100, systemPercent: 64 + state,
                                                 available: state != 3, muted: state == 0, enabled: state != 1,
                                                 red: r, green: g, blue: b)
                try HardwareDisplayRenderer.render(scene, capabilities: caps, icon: icon)
                    .write(to: directory.appendingPathComponent(String(format: "%03d-%@-state.qras", index, name)))
                index += 1
            }
        }
        print("Rendered \(index) QEQ controller scenes at \(caps.width)×\(caps.height), RGB565 LE, using the live app renderer.")
    }
}
