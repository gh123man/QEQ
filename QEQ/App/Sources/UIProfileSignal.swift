import Foundation
import QEQAppSupport
import QEQCore

/// Deterministic UI-only profiling input. No audio engine, capture, or saved state.
@MainActor
final class UIProfileSignal {
    private var timer: Timer?
    private var frame = 0
    private let bases: [[Float]] = [
        ScreenshotAudio.spectrum(.music), ScreenshotAudio.spectrum(.voice), ScreenshotAudio.spectrum(.browser),
    ]

    func start(model: MixerModel, isVisible: @escaping @MainActor @Sendable () -> Bool) {
        model.snapshot.apps = [
            AudioApplication(
                id: "com.spotify.client", name: "Spotify", path: "/Applications/Spotify.app", playing: true),
            AudioApplication(
                id: "com.apple.FaceTime", name: "FaceTime", path: "/System/Applications/FaceTime.app", playing: true),
            AudioApplication(
                id: "com.google.Chrome", name: "Google Chrome", path: "/Applications/Google Chrome.app", playing: true),
        ]
        model.snapshot.outputName = "UI profiling · simulated audio"
        model.snapshot.active = Set(model.snapshot.apps.map(\.id))
        model.enabled = true
        publish(model)
        let timer = Timer(timeInterval: 0.033, repeats: true) { [weak self, weak model] _ in
            Task { @MainActor in
                guard let self, let model, isVisible() else { return }
                self.frame += 1
                self.publish(model)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func publish(_ model: MixerModel) {
        let time = Double(frame) * 0.033
        var combined = AudioTelemetry()
        combined.simulated = true
        combined.spectrum = [Float](repeating: -90, count: AudioTelemetry.spectrumBinCount)
        for (index, app) in model.snapshot.apps.enumerated() {
            var value = AudioTelemetry()
            value.simulated = true
            value.peak = Float(0.05 + 0.4 * abs(sin(time * 2.1 + Double(index))))
            value.sourcePeak = value.peak
            value.spectrum = bases[index].enumerated().map { bin, db in
                max(-90, min(0, db + Float(9 * sin(time * 3 + Double(index) + Double(bin) / 23))))
            }
            for bin in value.spectrum.indices {
                combined.spectrum[bin] = max(combined.spectrum[bin], value.spectrum[bin])
            }
            combined.peak = max(combined.peak, value.peak)
            combined.apps[app.id] = value
        }
        model.telemetry = combined
    }
}
