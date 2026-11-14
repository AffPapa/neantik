import Darwin
import Foundation
import Metal
#if NEANTIK_WEBKIT_PROXY_QUALIFICATION || NEANTIK_WEBKIT_PROXY_PRODUCTION
import CoreGraphics
import IOSurface
import QuartzCore
#endif
import WebKitFrameMemory

/// The host writes one shared BGRA frame at a time. The presenter maps it
/// read-only and acknowledges the exact frame after GPU consumption.
enum WebKitFrameTransport {
    struct Layout: Equatable, Sendable {
        let width: Int
        let height: Int
        let bytesPerRow: Int
        let bytes: Int

        init?(width: Int, height: Int) {
            guard (1...4096).contains(width), (1...4096).contains(height) else { return nil }
            let row = (width * 4 + 255) & ~255
            let page = Int(getpagesize())
            let count = ((row * height + page - 1) / page) * page
            guard count <= 32 * 1024 * 1024 else { return nil }
            self.width = width
            self.height = height
            bytesPerRow = row
            bytes = count
        }
    }

    enum PreviewGeometry {
        static func fit(_ content: CGSize, inside bounds: CGRect) -> CGRect {
            guard content.width.isFinite, content.height.isFinite,
                  content.width > 0, content.height > 0,
                  bounds.width.isFinite, bounds.height.isFinite,
                  bounds.width > 0, bounds.height > 0 else { return .zero }
            let scale = min(bounds.width / content.width, bounds.height / content.height)
            let size = CGSize(width: content.width * scale, height: content.height * scale)
            return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                          width: size.width, height: size.height)
        }

        static func normalized(_ point: CGPoint, in content: CGRect) -> CGPoint? {
            guard content.width > 0, content.height > 0 else { return nil }
            let x = (point.x - content.minX) / content.width
            let y = (content.maxY - point.y) / content.height
            guard x >= 0, x < 1, y >= 0, y < 1 else { return nil }
            return CGPoint(x: x, y: y)
        }

        static func globalTopLeft(_ point: CGPoint, primaryDisplayTop: CGFloat) -> CGPoint {
            CGPoint(x: point.x, y: primaryDisplayTop - point.y)
        }
    }

    static let qaLayout = Layout(width: 1100, height: 760)!

    #if NEANTIK_WEBKIT_PROXY_QUALIFICATION || NEANTIK_WEBKIT_PROXY_PRODUCTION
    @MainActor
    final class Renderer {
        private let layout: Layout
        private let queue: any MTLCommandQueue
        private let memory: any MTLBuffer
        private let texture: any MTLTexture
        private let renderer: CARenderer

        init?(endpoint: Endpoint) {
            let layout = endpoint.layout
            guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
                  let memory = try? map(endpoint.memory, layout: layout, writer: true, device: device),
                  let surface = IOSurface(properties: [
                    .width: layout.width, .height: layout.height, .bytesPerElement: 4,
                    .bytesPerRow: layout.bytesPerRow, .pixelFormat: UInt32(0x42475241)
                  ]) else { return nil }
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: layout.width, height: layout.height, mipmapped: false)
            descriptor.storageMode = .shared
            descriptor.usage = [.renderTarget, .shaderRead]
            guard let texture = device.makeTexture(descriptor: descriptor, iosurface: surface, plane: 0),
                  let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
            let renderer = CARenderer(mtlTexture: texture, options: [
                kCARendererMetalCommandQueue: queue, kCARendererColorSpace: colorSpace
            ])
            self.layout = layout
            self.queue = queue
            self.memory = memory
            self.texture = texture
            self.renderer = renderer
            renderer.bounds = CGRect(x: 0, y: 0, width: layout.width, height: layout.height)
        }

        func submit(layer: CALayer) -> (any MTLCommandBuffer)? {
            if renderer.layer !== layer { renderer.layer = layer }
            CATransaction.flush()
            renderer.beginFrame(atTime: CACurrentMediaTime(), timeStamp: nil)
            renderer.addUpdate(renderer.bounds)
            renderer.render()
            renderer.endFrame()

            guard let command = queue.makeCommandBuffer(), let blit = command.makeBlitCommandEncoder() else { return nil }
            blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
                      sourceSize: MTLSize(width: layout.width, height: layout.height, depth: 1),
                      to: memory, destinationOffset: 0, destinationBytesPerRow: layout.bytesPerRow,
                      destinationBytesPerImage: layout.bytesPerRow * layout.height)
            blit.endEncoding()
            command.commit()
            return command
        }
    }
    #endif

    /// Evidence for the signed synthetic click fixture. Each sample is taken
    /// from the exact buffer blitted to the drawable, before reuse is allowed.
    struct ClickPixels {
        enum Color: Equatable {
            case red, green

            init?(bgra: UInt32) {
                let blue = bgra & 255
                let green = (bgra >> 8) & 255
                let red = (bgra >> 16) & 255
                guard bgra >> 24 >= 240, blue <= 16 else { return nil }
                if red >= 240 && green <= 16 { self = .red }
                else if green >= 240 && red <= 16 { self = .green }
                else { return nil }
            }
        }

        enum Observation: Equatable {
            case arm
            case verified(baseline: UInt64, changed: UInt64)
        }

        private var newest: UInt64 = 0
        private var baseline: UInt64?
        private var clickedAfter: UInt64?
        private(set) var complete = false

        mutating func beginClick() -> Bool {
            guard baseline != nil, clickedAfter == nil, !complete else { return false }
            clickedAfter = newest
            return true
        }

        mutating func presented(sequence: UInt64, color: Color?) -> Observation? {
            guard !complete, sequence > newest else { return nil }
            newest = sequence
            if baseline == nil, color == .red {
                baseline = sequence
                return .arm
            }
            guard let baseline, let clickedAfter, sequence > clickedAfter, color == .green else { return nil }
            complete = true
            return .verified(baseline: baseline, changed: sequence)
        }

        static func sampleOffset(in layout: Layout) -> Int {
            // The swatch is at 13% viewport width and vertically centered.
            layout.height / 2 * layout.bytesPerRow + (layout.width * 13 / 100) * 4
        }
    }

    enum Failure: Error {
        case region, descriptor, mapping, staleFrame
    }

    struct Region {
        let reader: FileHandle
        let writer: FileHandle

        init(layout: Layout) throws {
            // Darwin POSIX shared-memory names are at most 31 bytes.
            let name = "/neantik-" + UUID().uuidString.prefix(20)
            let writeFD = neantik_frame_memory_create(name)
            guard writeFD >= 0 else { throw Failure.region }
            let writer = FileHandle(fileDescriptor: writeFD, closeOnDealloc: true)
            let readFD = neantik_frame_memory_open_readonly(name)
            let unlinked = shm_unlink(name)
            guard readFD >= 0 else { throw Failure.region }
            let reader = FileHandle(fileDescriptor: readFD, closeOnDealloc: true)
            guard unlinked == 0,
                  fcntl(writeFD, F_SETFD, FD_CLOEXEC) == 0,
                  fcntl(readFD, F_SETFD, FD_CLOEXEC) == 0,
                  ftruncate(writeFD, off_t(layout.bytes)) == 0 else { throw Failure.region }
            self.reader = reader
            self.writer = writer
        }
    }

    private struct Offer: Codable {
        let generation: UUID
        let width: Int
        let height: Int
    }

    struct Endpoint: Sendable {
        let memory: FileHandle
        let layout: Layout
        private let control: FileHandle
        private var fence: Fence
        private let sends: Frame.Kind

        fileprivate init(memory: FileHandle, control: FileHandle, layout: Layout, generation: UUID, sends: Frame.Kind) {
            self.memory = memory
            self.control = control
            self.layout = layout
            self.fence = Fence(generation: generation)
            self.sends = sends
        }

        /// Wake any blocked peer I/O without closing a descriptor still in use.
        func stop() {
            _ = shutdown(control.fileDescriptor, SHUT_RDWR)
        }

        mutating func send(_ frame: Frame, timeout: TimeInterval) throws {
            guard frame.kind == sends else { throw Failure.staleFrame }
            var next = fence
            try next.accept(frame)
            let bytes = try JSONEncoder().encode(frame)
            try ProxyRelayPrivatePipe.writeFrame(control.fileDescriptor, data: bytes, timeout: timeout)
            fence = next
        }

        mutating func receive(timeout: TimeInterval) throws -> Frame {
            let bytes = try ProxyRelayPrivatePipe.readFrame(control.fileDescriptor, timeout: timeout)
            let frame = try JSONDecoder().decode(Frame.self, from: bytes)
            guard frame.kind != sends else { throw Failure.staleFrame }
            try fence.accept(frame)
            return frame
        }
    }

    /// Called in a serialized bootstrap phase, after the live child code is
    /// attested. The frame socket is independent of proxy and save traffic.
    static func offer(layout: Layout, generation: UUID, to bootstrap: Int32,
                      timeout: TimeInterval) throws -> Endpoint {
        let region = try Region(layout: layout)
        let (presenter, renderer) = try ProxyRelayPrivatePipe.anonymousSocketPair()
        try ProxyRelayPrivatePipe.sendDescriptor(region.writer.fileDescriptor, to: bootstrap, timeout: timeout)
        try ProxyRelayPrivatePipe.sendDescriptor(renderer.fileDescriptor, to: bootstrap, timeout: timeout)
        let header = Offer(generation: generation, width: layout.width, height: layout.height)
        try ProxyRelayPrivatePipe.writeFrame(presenter.fileDescriptor, data: JSONEncoder().encode(header), timeout: timeout)
        return Endpoint(memory: region.reader, control: presenter, layout: layout, generation: generation, sends: .consumed)
    }

    /// Called by the child before WebKit starts any subprocess.
    static func accept(generation: UUID, from bootstrap: Int32, timeout: TimeInterval) throws -> Endpoint {
        let memory = try ProxyRelayPrivatePipe.receiveDescriptor(from: bootstrap, timeout: timeout)
        let control = try ProxyRelayPrivatePipe.receiveDescriptor(from: bootstrap, timeout: timeout)
        try ProxyRelayPrivatePipe.prepareAnonymousSocket(control.fileDescriptor)
        let bytes = try ProxyRelayPrivatePipe.readFrame(control.fileDescriptor, timeout: timeout)
        let offer = try JSONDecoder().decode(Offer.self, from: bytes)
        guard offer.generation == generation,
              let layout = Layout(width: offer.width, height: offer.height) else { throw Failure.staleFrame }
        return Endpoint(memory: memory, control: control, layout: layout, generation: generation, sends: .ready)
    }

    static func map(_ descriptor: FileHandle, layout: Layout, writer: Bool,
                    device: any MTLDevice) throws -> any MTLBuffer {
        let fd = descriptor.fileDescriptor
        var info = stat()
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, flags & O_ACCMODE == (writer ? O_RDWR : O_RDONLY),
              fstat(fd, &info) == 0, info.st_uid == geteuid(),
              info.st_mode & 0o777 == 0o600,
              info.st_size == off_t(layout.bytes) else { throw Failure.descriptor }
        let address = mmap(nil, layout.bytes, PROT_READ | (writer ? PROT_WRITE : 0), MAP_SHARED, fd, 0)
        guard let address, address != MAP_FAILED else { throw Failure.mapping }
        guard let buffer = device.makeBuffer(bytesNoCopy: address, length: layout.bytes,
                                             options: .storageModeShared, deallocator: { pointer, size in
            _ = munmap(pointer, size)
        }) else {
            munmap(address, layout.bytes)
            throw Failure.mapping
        }
        return buffer
    }

    struct Frame: Codable, Equatable, Sendable {
        enum Kind: String, Codable, Sendable { case ready, consumed }
        let kind: Kind
        let generation: UUID
        let sequence: UInt64
        let acceptsClick: Bool?
        let page: WebKitPresenterChannel.State?

        init(kind: Kind, generation: UUID, sequence: UInt64, acceptsClick: Bool? = nil,
             page: WebKitPresenterChannel.State? = nil) {
            self.kind = kind
            self.generation = generation
            self.sequence = sequence
            self.acceptsClick = acceptsClick
            self.page = page
        }
    }

    /// Use on each side of the frame channel. A sender may not reuse the
    /// buffer until the corresponding acknowledgement has been accepted.
    struct Fence: Sendable {
        let generation: UUID
        private var sequence: UInt64 = 1
        private var pending = false

        mutating func accept(_ frame: Frame) throws {
            guard frame.generation == generation, frame.sequence == sequence, sequence < UInt64.max,
                  frame.kind == (pending ? .consumed : .ready),
                  frame.acceptsClick == nil || (!pending && sequence == 1),
                  frame.page == nil || (!pending && frame.acceptsClick == nil &&
                    frame.page?.generation == generation && frame.page?.isValid == true)
            else { throw Failure.staleFrame }
            if pending { sequence += 1 }
            pending.toggle()
        }
    }
}
