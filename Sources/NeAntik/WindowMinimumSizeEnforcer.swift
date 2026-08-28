import AppKit
import SwiftUI

/// Reapplies the product minimum after AppKit restores an older saved frame.
///
/// SwiftUI's `.windowResizability(.contentMinSize)` prevents new undersized
/// resizes, but macOS can restore a frame saved by an older build before the
/// current content minimum is known. This zero-sized bridge keeps that native
/// restoration path while correcting only dimensions below the current
/// product contract.
struct WindowMinimumSizeEnforcer: NSViewRepresentable {
    let minimumContentSize: CGSize

    func makeNSView(context: Context) -> MinimumSizeObserverView {
        MinimumSizeObserverView(minimumContentSize: minimumContentSize)
    }

    func updateNSView(
        _ nsView: MinimumSizeObserverView,
        context: Context
    ) {
        nsView.minimumContentSize = minimumContentSize
        nsView.enforceMinimumIfNeeded()
    }
}

final class MinimumSizeObserverView: NSView {
    var minimumContentSize: CGSize

    init(minimumContentSize: CGSize) {
        self.minimumContentSize = minimumContentSize
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        enforceMinimumIfNeeded()
    }

    func enforceMinimumIfNeeded() {
        guard let window,
              !window.styleMask.contains(.fullScreen)
        else {
            return
        }

        let minimum = NSSize(
            width: minimumContentSize.width,
            height: minimumContentSize.height
        )
        window.contentMinSize = minimum

        let current = window.contentLayoutRect.size
        let target = NSSize(
            width: max(current.width, minimum.width),
            height: max(current.height, minimum.height)
        )
        guard target != current else { return }

        let oldFrame = window.frame
        let targetFrameSize = window.frameRect(
            forContentRect: NSRect(origin: .zero, size: target)
        ).size
        let correctedFrame = NSRect(
            x: oldFrame.minX,
            y: oldFrame.maxY - targetFrameSize.height,
            width: targetFrameSize.width,
            height: targetFrameSize.height
        )
        window.setFrame(correctedFrame, display: true)
    }
}
