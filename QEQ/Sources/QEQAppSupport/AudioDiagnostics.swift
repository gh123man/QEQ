import CoreAudio
import Foundation
import QEQCore

/// Explicit command-line smoke test, using the app's normal permission and route.
/// Prints numeric signal diagnostics only; never saves audio or preferences.
public enum AudioDiagnostics {
    public static func check(bundleID: String) -> String {
        do {
            let output = try HAL.output()
            let beforeTaps = Set(try HAL.objects(HAL.system, kAudioHardwarePropertyTapList))
            guard let app = try HAL.applications().first(where: { $0.id == bundleID }) else {
                return "UNAVAILABLE: No audio client for \(bundleID). Start playback and retry."
            }
            var settings = MixerSettings()
            settings.bands[2].gain = -3
            let route = try AppAudioRoute(app: app, output: output, settings: settings)
            defer { route.stop() }
            let analyzer = SpectrumAnalyzer()
            var peak: Float = 0
            var spectrumFrames = 0
            for _ in 0..<30 {
                Thread.sleep(forTimeInterval: 0.067)
                peak = max(peak, route.peak)
                if route.analysis(using: analyzer) != nil { spectrumFrames += 1 }
            }
            try route.checkHealth()
            let frames = route.lastFrames
            route.stop()
            let outputRestored = try HAL.uint(HAL.system, kAudioHardwarePropertyDefaultOutputDevice) == output.id
            let tapsRestored = Set(try HAL.objects(HAL.system, kAudioHardwarePropertyTapList)) == beforeTaps
            let signal = peak > 0.00003 ? "SIGNAL" : "SILENT (source paused, silent, or permission unavailable)"
            return
                "\(app.name) [\(app.id)] | clients=\(app.processes.count) | frames=\(frames) | peak=\(peak) | spectrumFrames=\(spectrumFrames) | \(signal) | outputRestored=\(outputRestored) | tapsRestored=\(tapsRestored)"
        } catch { return "FAILED: \(error.localizedDescription)" }
    }
}
