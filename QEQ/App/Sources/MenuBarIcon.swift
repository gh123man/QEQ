import AppKit

/// The app icon's three ascending faders, simplified for a small template image.
/// No enclosing tile or panels: macOS supplies the menu bar's foreground color.
@MainActor
enum MenuBarIcon {
    static func makeImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setFill()
            for (x, bottom, top, knob) in [
                (3.0, 1.5, 13.5, 4.5),
                (9.0, 2.5, 15.0, 8.5),
                (15.0, 4.0, 16.5, 13.5),
            ] {
                NSBezierPath(
                    roundedRect: NSRect(x: x - 0.75, y: bottom, width: 1.5, height: top - bottom),
                    xRadius: 0.75, yRadius: 0.75
                ).fill()
                NSBezierPath(
                    roundedRect: NSRect(x: x - 2.75, y: knob - 1.5, width: 5.5, height: 3),
                    xRadius: 1.5, yRadius: 1.5
                ).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "QEQ"
        return image
    }
}
