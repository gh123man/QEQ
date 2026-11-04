import AppKit
import Combine
import QEQAppSupport
import QuartzCore
import SwiftUI

/// Native-renderer regression checks, run by the screenshot command in CI too.
@MainActor
enum VisualizationChecks {
    static func verify(model: MixerModel, host: NSHostingController<some View>) throws {
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let views = descendants(host.view)
        guard let graph = views.compactMap({ $0 as? SpectrumSurface }).first,
            let meter = views.compactMap({ $0 as? MeterSlider }).first,
            let envelope = graph.layer?.sublayers?.first as? CAShapeLayer,
            let initialPath = envelope.path
        else { throw failure("Native visualizers missing") }
        let original = model.telemetry
        defer { model.telemetry = original }
        let originalSize = host.view.bounds.size
        let meterPosition = meter.doubleValue
        var controlInvalidations = 0
        let observer = model.objectWillChange.sink { controlInvalidations += 1 }
        defer { observer.cancel() }
        var silence = original
        silence.peak = 0
        silence.spectrum = silence.spectrum.map { _ in -90 }
        for id in Array(silence.apps.keys) {
            if var reading = silence.apps[id] {
                reading.peak = 0
                reading.spectrum = reading.spectrum.map { _ in -90 }
                silence.apps[id] = reading
            }
        }
        model.telemetry = silence
        guard controlInvalidations == 0 else { throw failure("Audio frames invalidated the controls model") }
        guard let silentPath = envelope.path, silentPath != initialPath,
            silentPath.boundingBoxOfPath.height < 0.01,
            abs(silentPath.boundingBoxOfPath.maxY - graph.bounds.height) < 0.01
        else { throw failure("Spectrum did not update immediately to the silent baseline") }
        // Audio frames update layer targets without replacing the visualizer or
        // moving the native volume handle. No desktop interaction is involved.
        model.telemetry = original
        guard envelope.path == initialPath, graph.layer?.sublayers?.first === envelope,
            meter.doubleValue == meterPosition, host.view.bounds.size == originalSize
        else { throw failure("Audio frames changed visualizer identity, volume, or panel geometry") }
        print("live visualizers: immediate targets, stable controls/layout, no parent invalidations")
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "QEQ visualization", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
