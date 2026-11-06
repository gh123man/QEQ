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

/// Keep AppKit's viewport in sync with SwiftUI's measured content after opening.
/// Preferred-content sizing alone can retain the small startup viewport while
/// audio apps are still being discovered.
@MainActor
final class PopoverSizer {
    private weak var popover: NSPopover?
    private var pendingHeight: CGFloat?
    private var updateScheduled = false

    init(popover: NSPopover) {
        self.popover = popover
    }

    func update(height: CGFloat) {
        guard height.isFinite, height > 0 else { return }
        pendingHeight = height
        guard !updateScheduled else { return }
        updateScheduled = true
        // Leave SwiftUI's layout transaction before changing the AppKit frame.
        // Coalesce initial measurements and apply only the latest settled size.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.updateScheduled = false
            guard let popover = self.popover, let height = self.pendingHeight else { return }
            let size = NSSize(width: 500, height: ceil(height))
            if popover.contentSize != size { popover.contentSize = size }
        }
    }
}
