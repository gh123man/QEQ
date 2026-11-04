import AppKit
import Combine
import QEQAppSupport
import QEQCore
import QuartzCore

/// Only paths change at audio cadence. Core Animation interpolates those paths
/// without driving SwiftUI layout/styles at every display refresh.
final class SpectrumSurface: NSView {
    override var isFlipped: Bool { true }
    private var subscription: AnyCancellable?
    private var latest = AudioTelemetry()
    private var appID = ""
    private var processing = false
    private var animated = true
    private var apps: [(id: String, color: NSColor)] = []
    private var accent = NSColor.controlAccentColor
    private var traces: [String: CAShapeLayer] = [:]
    private var previousBins: [String: [Float]] = [:]
    private var previousSize = CGSize.zero

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func observe(_ source: LiveAudioTelemetry) {
        subscription = source.$value.sink { [weak self] value in
            guard let self else { return }
            self.latest = value
            self.render()
        }
    }
    func stopObserving() {
        subscription = nil
        for trace in traces.values { trace.removeAllAnimations() }
    }
    func configure(
        appID: String, processing: Bool, apps: [(id: String, color: NSColor)], accent: NSColor, animated: Bool
    ) {
        self.appID = appID
        self.processing = processing
        self.apps = apps
        self.accent = accent
        self.animated = animated
        render()
    }
    override func layout() {
        super.layout()
        render()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        render()
    }

    private func render() {
        guard let layer else { return }
        let reading = appID == MixerEngine.globalEQID ? latest : latest.apps[appID] ?? AudioTelemetry()
        let visible = processing && !reading.spectrum.isEmpty
        let ids = visible ? Set(["envelope"] + apps.map(\.id)) : []
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        for id in Array(traces.keys) where !ids.contains(id) {
            traces.removeValue(forKey: id)?.removeFromSuperlayer()
            previousBins.removeValue(forKey: id)
        }
        let resized = previousSize != bounds.size
        previousSize = bounds.size
        guard visible, bounds.width > 0, bounds.height > 0 else { return }
        func draw(_ id: String, bins: [Float], color: NSColor, filled: Bool) {
            let trace: CAShapeLayer
            if let existing = traces[id] {
                trace = existing
            } else {
                trace = CAShapeLayer()
                trace.lineWidth = 1
                traces[id] = trace
                layer.addSublayer(trace)
            }
            trace.frame = bounds
            trace.contentsScale = window?.backingScaleFactor ?? 2
            effectiveAppearance.performAsCurrentDrawingAppearance {
                trace.fillColor = filled ? color.cgColor : nil
                trace.strokeColor = filled ? nil : color.cgColor
            }
            guard resized || previousBins[id] != bins else { return }
            let path = SpectrumTrace(levels: SpectrumPlotValues(spectrum: bins), filled: filled)
                .path(in: CGRect(origin: .zero, size: bounds.size)).cgPath
            let canAnimate =
                animated && !resized && previousBins[id]?.count == bins.count
                && window?.isVisible == true && window?.occlusionState.contains(.visible) == true
            let from = trace.presentation()?.path ?? trace.path
            trace.removeAnimation(forKey: "spectrum")
            trace.path = path
            if canAnimate, let from {
                let transition = CABasicAnimation(keyPath: "path")
                transition.fromValue = from
                transition.toValue = path
                transition.duration = 0.033
                transition.timingFunction = CAMediaTimingFunction(name: .linear)
                trace.add(transition, forKey: "spectrum")
            }
            previousBins[id] = bins
        }
        draw("envelope", bins: reading.spectrum, color: accent.withAlphaComponent(0.16), filled: true)
        for app in apps {
            draw(
                app.id, bins: latest.apps[app.id]?.spectrum ?? [], color: app.color.withAlphaComponent(0.85),
                filled: false)
        }
    }
}
