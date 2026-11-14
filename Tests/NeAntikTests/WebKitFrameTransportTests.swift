import Darwin
import Foundation
import Testing
#if NEANTIK_WEBKIT_PROXY_QUALIFICATION
import QuartzCore
#endif
@testable import NeAntik

struct WebKitFrameTransportTests {
    @Test func previewGeometryUsesTheDrawnRectAndPrimaryScreenOrigin() {
        typealias Geometry = WebKitFrameTransport.PreviewGeometry
        let wide = Geometry.fit(CGSize(width: 1100, height: 760),
                                inside: CGRect(x: 20, y: 30, width: 900, height: 380))
        #expect(wide == CGRect(x: 195, y: 30, width: 550, height: 380))
        let tall = Geometry.fit(CGSize(width: 1100, height: 760),
                                inside: CGRect(x: 0, y: 0, width: 550, height: 1000))
        #expect(tall == CGRect(x: 0, y: 310, width: 550, height: 380))
        #expect(Geometry.normalized(CGPoint(x: 470, y: 220), in: wide) == CGPoint(x: 0.5, y: 0.5))
        #expect(Geometry.normalized(CGPoint(x: 30, y: 220), in: wide) == nil)
        #expect(Geometry.normalized(CGPoint(x: 275, y: 100), in: tall) == nil)
        #expect(Geometry.globalTopLeft(CGPoint(x: -320, y: 1080), primaryDisplayTop: 900)
                == CGPoint(x: -320, y: -180))
    }

    #if NEANTIK_WEBKIT_PROXY_QUALIFICATION
    @Test @MainActor func metalViewResizesWithoutReallocatingTheDrawable() {
        let pixels = CGSize(width: 1100, height: 760)
        let drawable = CAMetalLayer()
        drawable.drawableSize = pixels
        let view = WebKitQAMetalView(frame: CGRect(x: 0, y: 0, width: 550, height: 380),
                                     drawableLayer: drawable, contentSize: pixels)
        #expect(drawable.superlayer === view.layer)
        #expect(drawable.affineTransform() == CGAffineTransform(scaleX: 1, y: -1))
        #expect(drawable.frame == view.bounds)
        view.setFrameSize(CGSize(width: 900, height: 380))
        #expect(drawable.frame == CGRect(x: 175, y: 0, width: 550, height: 380))
        #expect(view.clickRect == drawable.frame)
        view.setFrameSize(CGSize(width: 550, height: 800))
        #expect(drawable.frame == CGRect(x: 0, y: 210, width: 550, height: 380))
        #expect(view.clickRect == drawable.frame)
        #expect(drawable.drawableSize == pixels)
        #expect(WebKitFrameTransport.PreviewGeometry.normalized(
            CGPoint(x: view.clickRect.midX, y: view.clickRect.maxY), in: view.clickRect
        ) == CGPoint(x: 0.5, y: 0))
    }
    #endif

    @Test func layoutsBoundFrameMemoryAndAlignRows() throws {
        let layout = try #require(WebKitFrameTransport.Layout(width: 1100, height: 760))
        #expect(layout.bytesPerRow >= 1100 * 4)
        #expect(layout.bytesPerRow % 256 == 0)
        #expect(layout.bytes % Int(getpagesize()) == 0)
        #expect(layout.bytes >= layout.bytesPerRow * layout.height)
        #expect(WebKitFrameTransport.Layout(width: 4096, height: 4096) == nil)
        #expect(WebKitFrameTransport.Layout(width: -1, height: 1) == nil)
        #expect(WebKitFrameTransport.Layout(width: 1, height: Int.max) == nil)
    }

    @Test func transferredMemoryIsReadOnlyInPresenterAndUsesDedicatedControl() throws {
        let generation = UUID()
        let layout = try #require(WebKitFrameTransport.Layout(width: 256, height: 256))
        let (parent, child) = try ProxyRelayPrivatePipe.anonymousSocketPair()
        var presenter = try WebKitFrameTransport.offer(layout: layout, generation: generation,
                                                       to: parent.fileDescriptor, timeout: 1)
        var renderer = try WebKitFrameTransport.accept(generation: generation, from: child.fileDescriptor,
                                                        timeout: 1)
        #expect(renderer.layout == layout)
        #expect(fcntl(presenter.memory.fileDescriptor, F_GETFL) & O_ACCMODE == O_RDONLY)
        #expect(fcntl(renderer.memory.fileDescriptor, F_GETFL) & O_ACCMODE == O_RDWR)
        #expect(fcntl(renderer.memory.fileDescriptor, F_GETFD) & FD_CLOEXEC == FD_CLOEXEC)

        let writerAddress = try #require(mmap(nil, layout.bytes, PROT_READ | PROT_WRITE, MAP_SHARED,
                                               renderer.memory.fileDescriptor, 0))
        try #require(writerAddress != MAP_FAILED)
        defer { munmap(writerAddress, layout.bytes) }
        let readerAddress = try #require(mmap(nil, layout.bytes, PROT_READ, MAP_SHARED,
                                               presenter.memory.fileDescriptor, 0))
        try #require(readerAddress != MAP_FAILED)
        defer { munmap(readerAddress, layout.bytes) }
        for sequence in UInt64(1)...6 {
            let color = sequence.isMultiple(of: 2) ? UInt32(0xff00ff00) : UInt32(0xffff0000)
            writerAddress.storeBytes(of: color, as: UInt32.self)
            let ready = WebKitFrameTransport.Frame(kind: .ready, generation: generation, sequence: sequence)
            let consumed = WebKitFrameTransport.Frame(kind: .consumed, generation: generation, sequence: sequence)
            try renderer.send(ready, timeout: 1)
            #expect(try presenter.receive(timeout: 1) == ready)
            #expect(readerAddress.load(as: UInt32.self) == color)
            try presenter.send(consumed, timeout: 1)
            #expect(try renderer.receive(timeout: 1) == consumed)
        }

        let lifecycle = Data("lifecycle channel remains framed".utf8)
        try ProxyRelayPrivatePipe.writeFrame(parent.fileDescriptor, data: lifecycle, timeout: 1)
        #expect(try ProxyRelayPrivatePipe.readFrame(child.fileDescriptor, timeout: 1) == lifecycle)
    }

    @Test func stoppingWithAFrameInFlightWakesRendererWithoutClosingLifecycle() throws {
        let generation = UUID()
        let layout = try #require(WebKitFrameTransport.Layout(width: 64, height: 64))
        let (parent, child) = try ProxyRelayPrivatePipe.anonymousSocketPair()
        var presenter = try WebKitFrameTransport.offer(layout: layout, generation: generation,
                                                       to: parent.fileDescriptor, timeout: 1)
        var renderer = try WebKitFrameTransport.accept(generation: generation, from: child.fileDescriptor,
                                                        timeout: 1)
        try renderer.send(.init(kind: .ready, generation: generation, sequence: 1), timeout: 1)
        #expect(try presenter.receive(timeout: 1).sequence == 1)
        presenter.stop()
        #expect(throws: ProxyRelayPrivatePipe.Failure.closed) {
            _ = try renderer.receive(timeout: 1)
        }
        let close = Data("close profile".utf8)
        try ProxyRelayPrivatePipe.writeFrame(parent.fileDescriptor, data: close, timeout: 1)
        #expect(try ProxyRelayPrivatePipe.readFrame(child.fileDescriptor, timeout: 1) == close)
    }

    @Test func rendererCloseEndsFrameStreamButDeliversSavedAndClosed() throws {
        let generation = UUID()
        let session = WebKitHostIPC.Session(
            profileID: UUID(), revision: 1, generation: generation,
            dataRoot: "/private/tmp/neantik-frame-close-test",
            runtimeSHA256: String(repeating: "a", count: 64))
        let layout = try #require(WebKitFrameTransport.Layout(width: 64, height: 64))
        let (parent, child) = try ProxyRelayPrivatePipe.anonymousSocketPair()
        var presenter = try WebKitFrameTransport.offer(
            layout: layout, generation: generation, to: parent.fileDescriptor, timeout: 1)
        let renderer = try WebKitFrameTransport.accept(
            generation: generation, from: child.fileDescriptor, timeout: 1)

        renderer.stop()
        #expect(throws: ProxyRelayPrivatePipe.Failure.closed) {
            _ = try presenter.receive(timeout: 1)
        }
        try WebKitHostIPC.write(.saved(session), to: child.fileDescriptor)
        try WebKitHostIPC.write(.closed(session), to: child.fileDescriptor)
        #expect(try WebKitHostIPC.read(from: parent.fileDescriptor) == .saved(session))
        #expect(try WebKitHostIPC.read(from: parent.fileDescriptor) == .closed(session))
    }

    @Test func fenceRejectsReplaySkippedSequenceAndOtherProfile() throws {
        let generation = UUID()
        var fence = WebKitFrameTransport.Fence(generation: generation)
        let ready = WebKitFrameTransport.Frame(kind: .ready, generation: generation, sequence: 1)
        let consumed = WebKitFrameTransport.Frame(kind: .consumed, generation: generation, sequence: 1)
        #expect(throws: WebKitFrameTransport.Failure.staleFrame) { try fence.accept(consumed) }
        #expect(throws: WebKitFrameTransport.Failure.staleFrame) {
            try fence.accept(.init(kind: .ready, generation: UUID(), sequence: 1))
        }
        try fence.accept(ready)
        #expect(throws: WebKitFrameTransport.Failure.staleFrame) {
            try fence.accept(.init(kind: .ready, generation: generation, sequence: 2))
        }
        try fence.accept(consumed)
        #expect(throws: WebKitFrameTransport.Failure.staleFrame) { try fence.accept(ready) }
        try fence.accept(.init(kind: .ready, generation: generation, sequence: 2))
    }

    @Test func frameMetadataMustBelongToTheReadyFrameAndItsGeneration() throws {
        let generation = UUID()
        let target = WebKitPresenterChannel.Target(tab: UUID(), navigation: UUID(), focus: UUID())
        func page(_ generation: UUID) -> WebKitPresenterChannel.State {
            .init(generation: generation, target: target, tabs: [.init(id: target.tab, title: "Example")],
                  address: "https://example.test", canGoBack: true, canGoForward: false,
                  acceptsPageInput: true, status: "")
        }
        var fence = WebKitFrameTransport.Fence(generation: generation)
        #expect(throws: WebKitFrameTransport.Failure.staleFrame) {
            try fence.accept(.init(kind: .ready, generation: generation, sequence: 1, page: page(UUID())))
        }
        #expect(throws: WebKitFrameTransport.Failure.staleFrame) {
            try fence.accept(.init(kind: .ready, generation: generation, sequence: 1,
                                   acceptsClick: true, page: page(generation)))
        }
        try fence.accept(.init(kind: .ready, generation: generation, sequence: 1, page: page(generation)))
        #expect(throws: WebKitFrameTransport.Failure.staleFrame) {
            try fence.accept(.init(kind: .consumed, generation: generation, sequence: 1, page: page(generation)))
        }
        try fence.accept(.init(kind: .consumed, generation: generation, sequence: 1))
    }

    @Test func clickPixelEvidenceRequiresPresentedRedAndNewGreenAfterClick() throws {
        typealias Evidence = WebKitFrameTransport.ClickPixels
        var evidence = Evidence()
        let prematureClick = evidence.beginClick()
        #expect(!prematureClick)
        let earlyGreen = evidence.presented(sequence: 1, color: .green)
        #expect(earlyGreen == nil)
        let baseline = evidence.presented(sequence: 2, color: .red)
        #expect(baseline == .arm)
        let unsolicitedGreen = evidence.presented(sequence: 3, color: .green)
        #expect(unsolicitedGreen == nil)
        let click = evidence.beginClick()
        let repeatedClick = evidence.beginClick()
        #expect(click)
        #expect(!repeatedClick)
        let replay = evidence.presented(sequence: 3, color: .green)
        let stillRed = evidence.presented(sequence: 4, color: .red)
        let changed = evidence.presented(sequence: 5, color: .green)
        #expect(replay == nil)
        #expect(stillRed == nil)
        #expect(changed == .verified(baseline: 2, changed: 5))
        #expect(evidence.complete)
        let repeatedEvidence = evidence.presented(sequence: 6, color: .green)
        #expect(repeatedEvidence == nil)
        #expect(Evidence.Color(bgra: 0xffff0000) == .red)
        #expect(Evidence.Color(bgra: 0xff00ff00) == .green)
        #expect(Evidence.Color(bgra: 0x00ff0000) == nil)
        #expect(Evidence.Color(bgra: 0xffffffff) == nil)
        let layout = try #require(WebKitFrameTransport.Layout(width: 256, height: 256))
        #expect(Evidence.sampleOffset(in: layout) == 128 * layout.bytesPerRow + 33 * 4)
    }

    @Test func onlyFirstReadyFrameCanOfferClick() throws {
        let generation = UUID()
        var fence = WebKitFrameTransport.Fence(generation: generation)
        try fence.accept(.init(kind: .ready, generation: generation, sequence: 1, acceptsClick: true))
        #expect(throws: WebKitFrameTransport.Failure.staleFrame) {
            try fence.accept(.init(kind: .consumed, generation: generation, sequence: 1, acceptsClick: true))
        }
        try fence.accept(.init(kind: .consumed, generation: generation, sequence: 1))
        #expect(throws: WebKitFrameTransport.Failure.staleFrame) {
            try fence.accept(.init(kind: .ready, generation: generation, sequence: 2, acceptsClick: true))
        }
        try fence.accept(.init(kind: .ready, generation: generation, sequence: 2))
    }

    @Test func aBootstrapForAnotherGenerationIsRefused() throws {
        let layout = try #require(WebKitFrameTransport.Layout(width: 64, height: 64))
        let (parent, child) = try ProxyRelayPrivatePipe.anonymousSocketPair()
        let presenter = try WebKitFrameTransport.offer(layout: layout, generation: UUID(),
                                                       to: parent.fileDescriptor, timeout: 1)
        withExtendedLifetime(presenter) {
            #expect(throws: WebKitFrameTransport.Failure.staleFrame) {
                try WebKitFrameTransport.accept(generation: UUID(), from: child.fileDescriptor, timeout: 1)
            }
        }
    }

    @Test func ordinaryBytesCannotActAsDescriptorOffer() throws {
        let (parent, child) = try ProxyRelayPrivatePipe.anonymousSocketPair()
        try parent.write(contentsOf: Data([0x46]))
        #expect(throws: ProxyRelayPrivatePipe.Failure.malformed) {
            try ProxyRelayPrivatePipe.receiveDescriptor(from: child.fileDescriptor, timeout: 1)
        }
    }
}
