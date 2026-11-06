import AppKit
import Combine
import QEQAppSupport
import QEQCore
import QuartzCore
import SwiftUI

/// Native-renderer regression checks, run by the screenshot command in CI too.
@MainActor
enum VisualizationChecks {
    static func verifyAdaptivePopover() throws {
        let model = MixerModel(preview: true)
        let popover = NSPopover()
        let sizer = PopoverSizer(popover: popover)
        let host = NSHostingController(
            rootView: MixerView(
                model: model,
                onPanelHeightChange: { height in
                    sizer.update(height: height)
                }))
        host.sizingOptions = []
        popover.contentViewController = host
        popover.contentSize = PopoverLayout.prepare(host, maximumHeight: model.maximumPanelHeight)

        func settle() -> CGFloat {
            for _ in 0..<12 {
                RunLoop.current.run(until: Date().addingTimeInterval(0.035))
                host.view.layoutSubtreeIfNeeded()
            }
            return popover.contentSize.height
        }
        // Keep the same view identity and never manually resize or prepare it
        // again: this is the late-discovery path after a login launch.
        let empty = settle()
        let apps = (0..<3).map {
            AudioApplication(id: "resize-\($0)", name: "App \($0 + 1)", playing: true)
        }
        model.snapshot.apps = [apps[0]]
        let oneApp = settle()
        model.snapshot.apps = apps
        let populated = settle()
        guard populated > oneApp + 100, populated > empty + 100 else {
            throw failure("Popover stayed compressed after late app discovery: \(empty), \(oneApp), \(populated)")
        }
        model.selectedEQ = apps[0].id
        let expanded = settle()
        guard expanded > populated else { throw failure("Popover did not grow for the app EQ editor") }
        model.selectedEQ = nil
        guard abs(settle() - populated) <= 1 else { throw failure("Popover did not shrink after closing app EQ") }
        model.snapshot.error = "An app needs audio capture permission."
        guard settle() > populated else { throw failure("Popover did not grow for the error banner") }
        model.snapshot.error = nil
        model.snapshot.apps = (0..<15).map {
            AudioApplication(id: "long-\($0)", name: "App \($0 + 1)", playing: true)
        }
        guard abs(settle() - MixerModel.panelHeightLimit) <= 1 else {
            throw failure("Popover did not grow to its long-list limit")
        }
        model.maximumPanelHeight = 460
        guard abs(settle() - 460) <= 1 else { throw failure("Popover ignored the smaller screen limit") }
        model.maximumPanelHeight = MixerModel.panelHeightLimit
        guard abs(settle() - MixerModel.panelHeightLimit) <= 1 else {
            throw failure("Popover did not grow after the screen limit increased")
        }
        model.snapshot.apps = []
        guard abs(settle() - empty) <= 1 else { throw failure("Popover did not shrink after app removal") }
        print("adaptive popover: late discovery, EQ, errors, long lists, screen changes and removal")
    }

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
