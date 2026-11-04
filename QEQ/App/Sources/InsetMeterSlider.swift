import AppKit
import Combine
import QEQAppSupport
import QEQCore
import QuartzCore
import SwiftUI

/// Native slider tracking, keyboard input and accessibility, with post-DSP
/// telemetry painted into the track up to the volume handle.
struct InsetMeterSlider: NSViewRepresentable {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var value: Double
    var maximum: Double
    var metered: Bool
    var muted = false
    var bypassed = false
    var color: NSColor
    var appName: String
    let liveAudio: LiveAudioTelemetry
    let appID: String

    func makeCoordinator() -> Coordinator { Coordinator(value: $value) }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MeterSlider, context: Context) -> CGSize? {
        // Keep the actual AppKit view fixed, not just its SwiftUI frame. Native
        // intrinsic sizing can otherwise change around interaction states.
        CGSize(width: proposal.width ?? 120, height: 26)
    }

    func makeNSView(context: Context) -> MeterSlider {
        let slider = MeterSlider()
        // Retained drawing layers keep meter animation out of AppKit's
        // control drawing and the surrounding SwiftUI hosting view.
        slider.wantsLayer = true
        slider.cell = MeterSliderCell()
        slider.sliderType = .linear
        slider.isContinuous = true
        slider.minValue = 0
        slider.target = context.coordinator
        slider.action = #selector(Coordinator.changed(_:))
        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        slider.observe(liveAudio, appID: appID)
        return slider
    }

    func updateNSView(_ slider: MeterSlider, context: Context) {
        context.coordinator.value = $value
        slider.scale = VolumeSliderScale(maximum: maximum)
        slider.maxValue = 1
        let position = slider.scale.position(for: value)
        if slider.doubleValue != position { slider.doubleValue = position }
        slider.altIncrementValue = 0.01
        slider.setAccessibilityLabel("\(appName) volume")
        if let cell = slider.cell as? MeterSliderCell {
            cell.meterColor = muted ? .secondaryLabelColor : color
            cell.boosted = maximum > 1
        }
        slider.configureMeter(
            metered: metered, muted: muted, bypassed: bypassed, animated: !reduceMotion, volume: value)
        slider.needsDisplay = true
    }

    static func dismantleNSView(_ slider: MeterSlider, coordinator: Coordinator) {
        slider.stopObserving()
        slider.stopMeterAnimation()
    }

    @MainActor final class Coordinator: NSObject {
        var value: Binding<Double>
        init(value: Binding<Double>) { self.value = value }
        @objc func changed(_ sender: MeterSlider) { value.wrappedValue = sender.scale.gain(at: sender.doubleValue) }
    }
}

final class MeterSlider: NSSlider {
    private var subscription: AnyCancellable?
    private var reading = AudioTelemetry()
    private var metered = false
    private var muted = false
    private var bypassed = false
    private var animateMeter = true
    private var volume = 1.0

    func observe(_ source: LiveAudioTelemetry, appID: String) {
        subscription = source.$value.sink { [weak self] value in
            guard let self else { return }
            self.reading = value.apps[appID] ?? AudioTelemetry()
            self.refreshMeter()
        }
    }

    func stopObserving() { subscription = nil }

    func configureMeter(metered: Bool, muted: Bool, bypassed: Bool, animated: Bool, volume: Double) {
        self.metered = metered
        self.muted = muted
        self.bypassed = bypassed
        self.animateMeter = animated
        self.volume = volume
        refreshMeter()
    }

    private func refreshMeter() {
        let peak = muted ? reading.sourcePeak : reading.peak
        let db = peak > 0 && peak.isFinite ? 20 * log10(Double(peak)) : -.infinity
        let level = metered ? (db.isFinite ? String(format: "%.0f dBFS", db) : "Silent") : "Not metered"
        let volumeLabel =
            bypassed
            ? "100% · Bypassed (saved: \(Int((volume * 100).rounded()))%)" : "\(Int((volume * 100).rounded()))%"
        let tip =
            "\(volumeLabel) · \(muted ? "Muted · Source: " : "")\(level)\n"
            + "Drag to set volume; double-click to reset to 100%.\n"
            + (muted
                ? "Gray shows source activity before EQ, volume and mute. Output is silent."
                : (bypassed
                    ? "Color shows output activity across the full track. This app's volume and EQ are bypassed; Global EQ still applies."
                    : "Color shows output activity after EQ, volume and mute, scaled within the handle."))
            + (metered && !muted && reading.limitingDB > 0.1
                ? String(format: "\nPeak protection: −%.1f dB", reading.limitingDB) : "")
        if toolTip != tip { toolTip = tip }
        setMeterLevel(metered ? max(0, min(1, (db + 60) / 60)) : 0, animated: metered && animateMeter)
    }

    var scale = VolumeSliderScale(maximum: 1)
    private var meterTransition = MeterLevelTransition()
    private var meterDisplayLink: MeterDisplayLinkLifetime?

    private var canAnimateMeter: Bool {
        window?.isVisible == true && window?.occlusionState.contains(.visible) == true && !isHiddenOrHasHiddenAncestor
    }

    func setMeterLevel(_ level: Double, animated: Bool) {
        let now = CACurrentMediaTime()
        meterTransition.setTarget(level, at: now, animated: animated && canAnimateMeter)
        advanceMeter(at: now)
        if !meterTransition.isSettled(at: now), meterDisplayLink == nil {
            // The display link retains its target; the target only weakly owns
            // this view, so removing a row cannot leave an animation running.
            let target = MeterDisplayTarget(slider: self)
            let link = displayLink(target: target, selector: #selector(MeterDisplayTarget.tick(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
            meterDisplayLink = MeterDisplayLinkLifetime(link)
            link.add(to: .main, forMode: .common)
        }
    }

    fileprivate func advanceMeter(at time: CFTimeInterval) {
        if !canAnimateMeter {
            meterTransition.setTarget(meterTransition.target, at: time, animated: false)
        }
        if let cell = cell as? MeterSliderCell {
            let level = meterTransition.value(at: time)
            if cell.level != level {
                cell.level = level
                updateMeterFill()
            }
        }
        if meterTransition.isSettled(at: time) { stopMeterAnimation() }
    }

    func stopMeterAnimation() {
        meterDisplayLink = nil
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        NotificationCenter.default.removeObserver(
            self, name: NSWindow.didChangeOcclusionStateNotification, object: window)
        stopMeterAnimation()
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            NotificationCenter.default.addObserver(
                self, selector: #selector(windowVisibilityChanged), name: NSWindow.didChangeOcclusionStateNotification,
                object: window)
        }
    }

    override func viewDidHide() {
        super.viewDidHide()
        setMeterLevel(meterTransition.target, animated: false)
    }

    @objc private func windowVisibilityChanged() {
        if !canAnimateMeter { setMeterLevel(meterTransition.target, animated: false) }
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            doubleValue = scale.unityPosition
            sendAction(action, to: target)
        } else {
            super.mouseDown(with: event)
        }
    }

    // The native control still owns tracking, keyboard input and accessibility.
    // Retain its static geometry in layers; moving the fill must not repaint the
    // knob/shadow or ask AppKit to lay out the SwiftUI panel at display cadence.
    private let trackLayer = CALayer()
    private let fillLayer = CALayer()
    private let markerLayer = CAShapeLayer()
    private let knobLayer = CAShapeLayer()
    private var fillSpan: CGFloat = 0
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        guard let layer, let cell = cell as? MeterSliderCell else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        if trackLayer.superlayer == nil {
            layer.addSublayer(trackLayer)
            trackLayer.addSublayer(fillLayer)
            layer.addSublayer(markerLayer)
            layer.addSublayer(knobLayer)
            trackLayer.cornerRadius = 6
            trackLayer.masksToBounds = true
            knobLayer.lineWidth = 0.5
            knobLayer.shadowOpacity = 1
            knobLayer.shadowRadius = 2
            knobLayer.shadowOffset = CGSize(width: 0, height: -1)
        }
        let rect = cell.barRect(flipped: isFlipped)
        let bar = CGRect(x: rect.minX, y: rect.midY - 6, width: rect.width, height: 12)
        let knob = cell.knobRect(flipped: isFlipped)
        trackLayer.frame = bar
        // A bypassed app uses unity gain regardless of its saved volume/boost.
        // Keep the handle at that saved setting, but meter over the whole track.
        fillSpan = bypassed ? bar.width : (doubleValue > minValue ? max(0, min(bar.width, knob.midX - bar.minX)) : 0)
        let path = CGPath(roundedRect: knob, cornerWidth: 4, cornerHeight: 4, transform: nil)
        knobLayer.path = path
        knobLayer.shadowPath = path
        let marker = CGMutablePath()
        if cell.boosted {
            let pixels = window?.backingScaleFactor ?? 1
            let unityX =
                ((bounds.minX + 10 + max(0, bounds.width - 20) * VolumeSliderScale.boostedUnityPosition)
                * pixels).rounded() / pixels
            let centerY = (bounds.midY * pixels).rounded() / pixels
            marker.addRect(CGRect(x: unityX - 1, y: centerY - 12, width: 2, height: 24))
            marker.addRect(CGRect(x: unityX - 3, y: centerY - 12, width: 6, height: 2))
            marker.addRect(CGRect(x: unityX - 3, y: centerY + 10, width: 6, height: 2))
        }
        markerLayer.path = marker
        effectiveAppearance.performAsCurrentDrawingAppearance {
            trackLayer.backgroundColor = NSColor.secondaryLabelColor.withAlphaComponent(0.18).cgColor
            fillLayer.backgroundColor = cell.meterColor.withAlphaComponent(0.72).cgColor
            markerLayer.fillColor = NSColor.labelColor.withAlphaComponent(0.8).cgColor
            knobLayer.fillColor = NSColor(white: 0.95, alpha: 1).cgColor
            knobLayer.strokeColor = NSColor.black.withAlphaComponent(0.12).cgColor
            knobLayer.shadowColor = NSColor.black.withAlphaComponent(0.3).cgColor
        }
        for surface in [trackLayer, fillLayer, markerLayer, knobLayer] {
            surface.contentsScale = window?.backingScaleFactor ?? 2
        }
        updateMeterFill()
    }

    private func updateMeterFill() {
        guard let cell = cell as? MeterSliderCell else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fillLayer.frame = CGRect(x: 0, y: 0, width: fillSpan * cell.level, height: 12)
        CATransaction.commit()
    }

    override func accessibilityValueDescription() -> String? {
        "\(Int((scale.gain(at: doubleValue) * 100).rounded())) percent"
    }
}

/// Releasing the owner invalidates the run-loop registration even if an AppKit
/// view is destroyed without another display callback (for example, offscreen).
private final class MeterDisplayLinkLifetime {
    let link: CADisplayLink
    init(_ link: CADisplayLink) { self.link = link }
    deinit { link.invalidate() }
}

@MainActor private final class MeterDisplayTarget: NSObject {
    weak var slider: MeterSlider?
    init(slider: MeterSlider) { self.slider = slider }
    @objc func tick(_ link: CADisplayLink) {
        guard let slider else {
            link.invalidate()
            return
        }
        slider.advanceMeter(at: CACurrentMediaTime())
    }
}

private final class MeterSliderCell: NSSliderCell {
    var level: Double = 0
    var meterColor: NSColor = .controlAccentColor
    var boosted = false

    override func knobRect(flipped: Bool) -> NSRect {
        let native = super.knobRect(flipped: flipped)
        return NSRect(x: native.midX - 4.5, y: native.midY - 10, width: 9, height: 20)
    }

}
