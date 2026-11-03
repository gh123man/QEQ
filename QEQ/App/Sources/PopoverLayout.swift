import AppKit
import SwiftUI

/// Resolve the content's measured height before AppKit presents the popover.
/// Otherwise its placeholder size becomes visible before SwiftUI preferences settle.
@MainActor
enum PopoverLayout {
    static func prepare<Content: View>(
        _ host: NSHostingController<Content>, maximumHeight: CGFloat
    ) -> NSSize {
        let proposal = NSSize(width: 500, height: maximumHeight)
        var size = proposal
        for _ in 0..<4 {
            host.view.setFrameSize(size)
            host.view.layoutSubtreeIfNeeded()
            let measured = host.sizeThatFits(in: proposal)
            size = NSSize(width: 500, height: min(maximumHeight, measured.height))
        }
        host.view.setFrameSize(size)
        host.view.layoutSubtreeIfNeeded()
        return size
    }
}
