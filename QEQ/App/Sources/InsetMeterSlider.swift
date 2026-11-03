import AppKit
import QEQCore
import QuartzCore
import SwiftUI

/// Native slider tracking, keyboard input and accessibility, with post-DSP
/// telemetry painted into the track up to the volume handle.
struct InsetMeterSlider: NSViewRepresentable {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var value: Double
    var maximum: Double
    var peak: Float
    var metered: Bool
    var muted = false
    var color: NSColor
    var limitingDB: Float
    var appName: String

    func makeCoordinator() -> Coordinator { Coordinator(value: $value) }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MeterSlider, context: Context) -> CGSize? {
        // Keep the actual AppKit view fixed, not just its SwiftUI frame. Native
        // intrinsic sizing can otherwise change around interaction states.
        CGSize(width: proposal.width ?? 120, height: 26)
    }

    func makeNSView(context: Context) -> MeterSlider {
        let slider = MeterSlider()
        slider.cell = MeterSliderCell()
        slider.sliderType = .linear
        slider.isContinuous = true
        slider.minValue = 0
        slider.target = context.coordinator
        slider.action = #selector(Coordinator.changed(_:))
        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
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
        let db = peak > 0 && peak.isFinite ? 20 * log10(Double(peak)) : -.infinity
        let level = metered ? (db.isFinite ? String(format: "%.0f dBFS", db) : "Silent") : "Not metered"
        slider.toolTip =
            "\(Int((value * 100).rounded()))% · \(muted ? "Muted · Source: " : "")\(level)\n"
            + "Drag to set volume; double-click to reset to 100%.\n"
            + (muted
                ? "Gray shows source activity before EQ, volume and mute. Output is silent."
                : "Color shows output activity after EQ, volume and mute, scaled within the handle.")
            + (metered && !muted && limitingDB > 0.1 ? String(format: "\nPeak protection: −%.1f dB", limitingDB) : "")
        if let cell = slider.cell as? MeterSliderCell {
            cell.meterColor = muted ? .secondaryLabelColor : color
            cell.boosted = maximum > 1
        }
        slider.setMeterLevel(metered ? max(0, min(1, (db + 60) / 60)) : 0, animated: metered && !reduceMotion)
        slider.needsDisplay = true
    }

    static func dismantleNSView(_ slider: MeterSlider, coordinator: Coordinator) {
        slider.stopMeterAnimation()
    }

    @MainActor final class Coordinator: NSObject {
        var value: Binding<Double>
        init(value: Binding<Double>) { self.value = value }
        @objc func changed(_ sender: MeterSlider) { value.wrappedValue = sender.scale.gain(at: sender.doubleValue) }
    }
}

final class MeterSlider: NSSlider {
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
                needsDisplay = true
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

    override func drawBar(inside rect: NSRect, flipped: Bool) {
        let bar = NSRect(x: rect.minX, y: rect.midY - 6, width: rect.width, height: 12)
        let shape = NSBezierPath(roundedRect: bar, xRadius: 6, yRadius: 6)
        NSColor.secondaryLabelColor.withAlphaComponent(0.18).setFill()
        shape.fill()
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        meterColor.withAlphaComponent(0.72).setFill()
        // Fit the full meter range into the selected volume span, rather than
        // clipping a full-width meter (which would look stuck at low volumes).
        let span = doubleValue > minValue ? max(0, min(bar.width, knobRect(flipped: flipped).midX - bar.minX)) : 0
        NSRect(x: bar.minX, y: bar.minY, width: span * level, height: bar.height).fill()
        NSGraphicsContext.restoreGraphicsState()
        if boosted {
            // This reference must never depend on an animated native knob/bar
            // rectangle. Use the fixed control bounds and the resting 10pt inset.
            let bounds = controlView?.bounds ?? rect
            let pixels = controlView?.window?.backingScaleFactor ?? 1
            let unityX =
                ((bounds.minX + 10 + max(0, bounds.width - 20) * VolumeSliderScale.boostedUnityPosition) * pixels)
                .rounded() / pixels
            let centerY = (bounds.midY * pixels).rounded() / pixels
            // High-contrast unity marker crosses the track; end caps remain
            // visible above and below the handle when it sits at exactly 100%.
            NSColor.labelColor.withAlphaComponent(0.8).setFill()
            NSRect(x: unityX - 1, y: centerY - 12, width: 2, height: 24).fill()
            NSRect(x: unityX - 3, y: centerY - 12, width: 6, height: 2).fill()
            NSRect(x: unityX - 3, y: centerY + 10, width: 6, height: 2).fill()
        }
    }

    override func knobRect(flipped: Bool) -> NSRect {
        let native = super.knobRect(flipped: flipped)
        return NSRect(x: native.midX - 4.5, y: native.midY - 10, width: 9, height: 20)
    }

    override func drawKnob(_ knobRect: NSRect) {
        let shape = NSBezierPath(roundedRect: knobRect, xRadius: 4, yRadius: 4)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.set()
        NSColor(white: 0.95, alpha: 1).setFill()
        shape.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSColor.black.withAlphaComponent(0.12).setStroke()
        shape.lineWidth = 0.5
        shape.stroke()
    }
}
