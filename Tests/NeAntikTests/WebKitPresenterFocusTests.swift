#if NEANTIK_WEBKIT_PROXY_PRODUCTION
import AppKit
import QuartzCore
import Testing
@testable import NeAntik

extension WebKitFrameTransportTests {
    @Test @MainActor func mouseDownRefreshesFocusOnlyForAnInsideSingleClick() throws {
        _ = NSApplication.shared
        let drawable = CAMetalLayer()
        drawable.drawableSize = CGSize(width: 1100, height: 760)
        let view = WebKitPresenterView(drawable: drawable)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 380),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        view.setFrameSize(NSSize(width: 900, height: 380))
        #expect(window.makeFirstResponder(view))
        var focusUpdates = 0
        view.onFocusChange = { focusUpdates += 1 }
        func event(_ point: CGPoint, clicks: Int) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point,
                                            modifierFlags: [], timestamp: 0,
                                            windowNumber: window.windowNumber, context: nil,
                                            eventNumber: 1, clickCount: clicks, pressure: 1))
        }

        view.mouseDown(with: try event(CGPoint(x: 450, y: 190), clicks: 1))
        #expect(focusUpdates == 1)
        view.mouseDown(with: try event(CGPoint(x: 20, y: 190), clicks: 1))
        view.mouseDown(with: try event(CGPoint(x: 450, y: 190), clicks: 2))
        #expect(focusUpdates == 1)
        #expect(window.makeFirstResponder(nil))
        view.mouseDown(with: try event(CGPoint(x: 450, y: 190), clicks: 1))
        #expect(window.firstResponder === view)
        #expect(focusUpdates == 2)
    }
}
#endif
