import AppKit
import QuartzCore
import SwiftUI

/// Keep the material and tint together, independent of SwiftUI content updates
/// and the popover becoming key. Only a system appearance change alters the tint.
struct PanelBackground: NSViewRepresentable {
    static let tintOpacity = 0.55

    func makeNSView(context: Context) -> NSVisualEffectView {
        let material = NSVisualEffectView()
        material.material = .popover
        material.blendingMode = .behindWindow
        material.state = .active

        let tint = PanelTintView()
        tint.autoresizingMask = [.width, .height]
        tint.frame = material.bounds
        material.addSubview(tint)
        return material
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

private final class PanelTintView: NSView {
    override var allowsVibrancy: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        updateTint()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateTint()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateTint()
    }

    private func updateTint() {
        // Resolve the semantic color in this view's appearance before assigning
        // a concrete color to the layer. Never animate appearance/tint updates.
        effectiveAppearance.performAsCurrentDrawingAppearance {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.backgroundColor =
                NSColor.windowBackgroundColor.withAlphaComponent(
                    PanelBackground.tintOpacity
                ).cgColor
            CATransaction.commit()
        }
    }
}
