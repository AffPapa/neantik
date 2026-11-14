#if NEANTIK_WEBKIT_PROXY_PRODUCTION
import AppKit
import Carbon
import Darwin
import Foundation
import Metal
import QuartzCore

/// The manager owns only the window and read-only frame mapping. The host
/// owns navigation, website data, the compositor and the network route.
@MainActor
final class WebKitDetachedPresenter: NSObject, NSWindowDelegate {
    let generation: UUID
    private let window: NSWindow
    private let view: WebKitPresenterView
    private let endpoint: WebKitFrameTransport.Endpoint
    private let input: FileHandle
    private let downloadIntake: FileHandle
    private let drawable: CAMetalLayer
    private let queue: any MTLCommandQueue
    private let memory: any MTLBuffer
    private let address = NSTextField()
    private let tabs = NSPopUpButton()
    private let status = NSTextField(wrappingLabelWithString: "")
    private var pageStatus = ""
    private var downloadStatus: String?
    private var downloads: WebKitDetachedDownloadPresenter?
    private let back = NSButton(title: "Назад", target: nil, action: nil)
    private let forward = NSButton(title: "Вперёд", target: nil, action: nil)
    private let cancelDownloads = NSButton(title: "Отменить загрузки", target: nil, action: nil)
    private var state: WebKitPresenterChannel.State?
    private var displayedSequence: UInt64 = 0
    private var nextInputSequence: UInt64 = 1
    private var inputSink: AsyncStream<WebKitPresenterChannel.Command>.Continuation?
    private var inputTask: Task<Void, Never>?
    private var frameTask: Task<Void, Never>?
    private var onClose: (() -> Void)?
    private var onFailure: (() -> Void)?
    private var appActivityObservers: [NSObjectProtocol] = []
    private var nextAccessibilityRefresh = ContinuousClock.now
    private var active = false

    init?(profileName: String, generation: UUID, endpoint: WebKitFrameTransport.Endpoint,
          input: FileHandle, downloadIntake: FileHandle, onClose: @escaping () -> Void, onFailure: @escaping () -> Void) {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
              let memory = try? WebKitFrameTransport.map(endpoint.memory, layout: endpoint.layout,
                                                        writer: false, device: device) else { return nil }
        self.generation = generation
        self.endpoint = endpoint
        self.input = input
        self.downloadIntake = downloadIntake
        self.queue = queue
        self.memory = memory
        self.onClose = onClose
        self.onFailure = onFailure

        let drawable = CAMetalLayer()
        drawable.device = device
        drawable.pixelFormat = .bgra8Unorm
        drawable.framebufferOnly = false
        drawable.drawableSize = CGSize(width: endpoint.layout.width, height: endpoint.layout.height)
        self.drawable = drawable
        view = WebKitPresenterView(drawable: drawable)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 820),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable],
                          backing: .buffered, defer: false)
        super.init()
        window.title = profileName
        window.minSize = NSSize(width: 570, height: 300)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = makeContent()
        view.onInput = { [weak self] action, editor in self?.send(action, editor: editor) }
        view.onFocusChange = { [weak self] in self?.sendActivity() }
        view.onAccessibilityQuery = { [weak self] in self?.requestAccessibility() }
        view.onAccessibilityAction = { [weak self] document, node, press in
            guard let self, self.window.isKeyWindow, NSApp.isActive,
                  self.window.makeFirstResponder(self.view) else { return false }
            self.sendActivity()
            return self.send(.accessibilityAction(document: document, node: node, press: press))
        }
    }

    private func makeContent() -> NSView {
        back.target = self
        back.action = #selector(goBack)
        forward.target = self
        forward.action = #selector(goForward)
        back.isEnabled = false
        forward.isEnabled = false
        address.placeholderString = "Адрес страницы"
        address.setAccessibilityLabel("Адрес страницы")
        address.target = self
        address.action = #selector(openAddress)
        address.isEnabled = false
        tabs.setAccessibilityLabel("Вкладки")
        tabs.target = self
        tabs.action = #selector(selectTab)
        let reload = NSButton(title: "Обновить", target: self, action: #selector(reloadPage))
        let newTab = NSButton(title: "Новая вкладка", target: self, action: #selector(addTab))
        let closeTab = NSButton(title: "Закрыть вкладку", target: self, action: #selector(removeTab))
        let bar = NSStackView(views: [back, forward, reload, address, tabs, newTab, closeTab])
        bar.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        bar.orientation = .horizontal
        bar.alignment = .centerY
        bar.spacing = 6
        address.setContentHuggingPriority(.defaultLow, for: .horizontal)
        tabs.widthAnchor.constraint(lessThanOrEqualToConstant: 150).isActive = true

        let content = NSView()
        bar.translatesAutoresizingMaskIntoConstraints = false
        view.translatesAutoresizingMaskIntoConstraints = false
        status.translatesAutoresizingMaskIntoConstraints = false
        status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        status.textColor = .secondaryLabelColor
        cancelDownloads.target = self
        cancelDownloads.action = #selector(cancelPendingDownloads)
        cancelDownloads.isHidden = true
        let footer = NSStackView(views: [status, cancelDownloads])
        footer.translatesAutoresizingMaskIntoConstraints = false
        footer.orientation = .horizontal
        footer.alignment = .centerY
        content.addSubview(bar)
        content.addSubview(view)
        content.addSubview(footer)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: content.topAnchor),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            view.topAnchor.constraint(equalTo: bar.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -4),
            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            footer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -4)
        ])
        return content
    }

    func start() {
        guard !active else { return }
        active = true
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            let observer = NotificationCenter.default.addObserver(forName: name, object: NSApp, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.sendActivity() }
            }
            appActivityObservers.append(observer)
        }
        let (stream, sink) = AsyncStream<WebKitPresenterChannel.Command>.makeStream(bufferingPolicy: .bufferingOldest(64))
        inputSink = sink
        let input = input
        inputTask = Task.detached { [weak self] in
            do {
                for await command in stream {
                    try Task.checkCancellation()
                    try WebKitPresenterChannel.write(command, to: input, timeout: 2)
                }
            } catch {
                if !Task.isCancelled { await self?.fail() }
            }
        }
        let endpoint = endpoint
        let generation = generation
        let drawable = drawable
        let queue = queue
        let memory = memory
        frameTask = Task.detached { [weak self] in
            var receiver = endpoint
            do {
                var hasReceived = false
                while !Task.isCancelled {
                    let frame: WebKitFrameTransport.Frame
                    do {
                        frame = try receiver.receive(timeout: hasReceived ? 2 : 15)
                    } catch ProxyRelayPrivatePipe.Failure.timeout where hasReceived {
                        continue
                    }
                    guard let page = frame.page else { throw WebKitFrameTransport.Failure.staleFrame }
                    if !hasReceived {
                        hasReceived = true
                        await self?.show()
                    }
                    if await self?.canPresent == true {
                        let command = Self.draw(drawable, queue: queue, memory: memory, layout: endpoint.layout) { [weak self] in
                            Task { @MainActor [weak self] in self?.didPresent(page, sequence: frame.sequence) }
                        }
                        if let command {
                            await command.completed()
                            guard command.status == .completed else { throw WebKitFrameTransport.Failure.mapping }
                        }
                    }
                    try receiver.send(.init(kind: .consumed, generation: generation,
                                            sequence: frame.sequence), timeout: 2)
                }
            } catch {
                if !Task.isCancelled { await self?.fail() }
            }
        }
    }

    private nonisolated static func draw(_ layer: CAMetalLayer, queue: any MTLCommandQueue,
                                        memory: any MTLBuffer, layout: WebKitFrameTransport.Layout,
                                        presented: @escaping @Sendable () -> Void) -> (any MTLCommandBuffer)? {
        autoreleasepool {
            guard let drawable = layer.nextDrawable(), drawable.texture.width == layout.width,
                  drawable.texture.height == layout.height,
                  let command = queue.makeCommandBuffer(), let blit = command.makeBlitCommandEncoder()
            else { return nil }
            blit.copy(from: memory, sourceOffset: 0, sourceBytesPerRow: layout.bytesPerRow,
                      sourceBytesPerImage: layout.bytesPerRow * layout.height,
                      sourceSize: .init(width: layout.width, height: layout.height, depth: 1),
                      to: drawable.texture, destinationSlice: 0, destinationLevel: 0,
                      destinationOrigin: MTLOrigin())
            blit.endEncoding()
            drawable.addPresentedHandler { if $0.presentedTime > 0 { presented() } }
            command.present(drawable)
            command.commit()
            return command
        }
    }

    private var canPresent: Bool { active && window.isVisible && !window.isMiniaturized }

    private func show() {
        guard active else { return }
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        let coordinator = WebKitDetachedDownloadPresenter(intake: downloadIntake, generation: generation, window: window,
            onStatus: { [weak self] value in
                self?.downloadStatus = value
                self?.refreshStatus()
            }, onFailure: { [weak self] in self?.fail() })
        downloads = coordinator
        coordinator.start()
    }

    private func didPresent(_ page: WebKitPresenterChannel.State, sequence: UInt64) {
        guard active, sequence > displayedSequence, page.generation == generation else { return }
        displayedSequence = sequence
        let changedTarget = state?.target != page.target
        let changedTabs = state?.tabs != page.tabs
        state = page
        address.isEnabled = true
        if window.firstResponder !== address.currentEditor() { address.stringValue = page.address }
        back.isEnabled = page.canGoBack
        forward.isEnabled = page.canGoForward
        pageStatus = page.status
        refreshStatus()
        view.updateEditor(page.editor)
        view.updatePageAccessibility(page.accessibility, reset: changedTarget)
        if changedTabs {
            tabs.removeAllItems()
            for (index, summary) in page.tabs.enumerated() {
                let title = summary.title.isEmpty ? "Новая вкладка" : summary.title
                let item = NSMenuItem(title: "\(index + 1) · \(title)", action: nil, keyEquivalent: "")
                item.representedObject = summary.id
                tabs.menu?.addItem(item)
            }
        }
        if let index = page.tabs.firstIndex(where: { $0.id == page.target.tab }) { tabs.selectItem(at: index) }
        if changedTarget { sendActivity() }
        if NSWorkspace.shared.isVoiceOverEnabled || NSWorkspace.shared.isSwitchControlEnabled {
            requestAccessibility()
        }
    }

    private func refreshStatus() {
        status.stringValue = [pageStatus, downloadStatus].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
        cancelDownloads.isHidden = downloads?.hasActiveTransfers != true
    }

    @objc private func cancelPendingDownloads() { downloads?.cancelActive() }

    @discardableResult
    private func send(_ action: WebKitPresenterChannel.Action, editor: WebKitPresenterChannel.EditTarget? = nil) -> Bool {
        guard active, let state, let inputSink, action.isValid else { return false }
        switch action {
        case .navigate, .activity: break
        default: guard state.acceptsPageInput else { return false }
        }
        guard nextInputSequence < UInt64.max else { fail(); return false }
        let command = WebKitPresenterChannel.Command(generation: generation, sequence: nextInputSequence,
            target: state.target, action: action, editor: editor)
        guard command.isValid else { return false }
        switch inputSink.yield(command) {
        case .enqueued:
            nextInputSequence += 1
            return true
        case .dropped, .terminated:
            fail()
            return false
        @unknown default:
            fail()
            return false
        }
    }

    private func requestAccessibility() {
        let now = ContinuousClock.now
        guard now >= nextAccessibilityRefresh, NSApp.isActive, window.isKeyWindow,
              send(.accessibilitySnapshot) else { return }
        nextAccessibilityRefresh = now + .milliseconds(500)
    }

    private func sendActivity() {
        view.updateSecureInput()
        let visible = canPresent && window.occlusionState.contains(.visible)
        let key = visible && window.isKeyWindow && NSApp.isActive
        send(.activity(visible: visible, active: key, focused: key && window.firstResponder === view))
    }

    func windowDidBecomeKey(_ notification: Notification) { sendActivity() }
    func windowDidResignKey(_ notification: Notification) { sendActivity() }
    func windowDidChangeOcclusionState(_ notification: Notification) { sendActivity() }
    func windowDidMiniaturize(_ notification: Notification) { sendActivity() }
    func windowDidDeminiaturize(_ notification: Notification) { sendActivity() }
    func windowWillClose(_ notification: Notification) { onClose?() }

    @objc private func goBack() { send(.navigate(.back)) }
    @objc private func goForward() { send(.navigate(.forward)) }
    @objc private func reloadPage() { send(.navigate(.reload)) }
    @objc private func addTab() { send(.navigate(.newTab)) }
    @objc private func removeTab() {
        if let tab = state?.target.tab { send(.navigate(.closeTab(tab))) }
    }
    @objc private func selectTab() {
        if let tab = tabs.selectedItem?.representedObject as? UUID { send(.navigate(.selectTab(tab))) }
    }
    @objc private func openAddress() {
        guard let url = BrowserStartURL.validate(address.stringValue), WebKitProfilePolicy.permits(url) else { return }
        send(.navigate(.open(url.absoluteString)))
        window.makeFirstResponder(view)
    }

    private func fail() { onFailure?() }

    func dismiss() {
        active = false
        downloads?.stop()
        downloads = nil
        appActivityObservers.forEach(NotificationCenter.default.removeObserver)
        appActivityObservers.removeAll()
        view.updateEditor(nil)
        view.updatePageAccessibility(nil, reset: true)
        window.delegate = nil
        window.orderOut(nil)
        inputSink?.finish()
        inputSink = nil
        inputTask?.cancel()
        inputTask = nil
        frameTask?.cancel()
        frameTask = nil
        endpoint.stop()
        _ = shutdown(input.fileDescriptor, SHUT_RDWR)
        onClose = nil
        onFailure = nil
    }
}

@MainActor
private final class WebKitPresenterView: NSView, @MainActor NSTextInputClient {
    private let drawable: CAMetalLayer
    private var downInsideContent = false
    private var editor: WebKitPresenterChannel.Editor?
    private var secureEventInput = false
    private var discardingComposition = false
    var onInput: ((WebKitPresenterChannel.Action, WebKitPresenterChannel.EditTarget?) -> Void)?
    var onFocusChange: (() -> Void)?
    var onAccessibilityQuery: (() -> Void)?
    var onAccessibilityAction: ((UUID, UInt64, Bool) -> Bool)?
    private var accessibilitySnapshot: WebKitPresenterChannel.AccessibilitySnapshot?
    private var pageElements: [WebKitPageAccessibilityElement] = []

    init(drawable: CAMetalLayer) {
        self.drawable = drawable
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        layer?.masksToBounds = true
        drawable.setAffineTransform(.init(scaleX: 1, y: -1))
        layer?.addSublayer(drawable)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Веб-страница")
    }

    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }

    override func accessibilityChildren() -> [Any]? {
        onAccessibilityQuery?()
        return pageElements.first.map { [$0] } ?? []
    }

    func updatePageAccessibility(_ snapshot: WebKitPresenterChannel.AccessibilitySnapshot?, reset: Bool) {
        if reset {
            accessibilitySnapshot = nil
            pageElements = []
        }
        guard accessibilitySnapshot != snapshot else { return }
        let reusable = accessibilitySnapshot?.document == snapshot?.document ?
            Dictionary(uniqueKeysWithValues: pageElements.map { ($0.node, $0) }) : [:]
        let previousFocus = pageElements.first(where: { $0.isAccessibilityFocused() })?.node
        accessibilitySnapshot = snapshot
        pageElements = []
        if let snapshot {
            for model in snapshot.nodes {
                guard let node = model.identifier else { continue }
                let element = reusable[node] ?? WebKitPageAccessibilityElement(view: self, document: snapshot.document, node: node)
                element.model = model
                pageElements.append(element)
            }
            for index in pageElements.indices {
                let model = snapshot.nodes[index]
                let parent: Any = model.parent < 0 ? self : pageElements[model.parent]
                pageElements[index].setAccessibilityParent(parent)
                pageElements[index].setAccessibilityChildren(pageElements.indices.compactMap {
                    snapshot.nodes[$0].parent == index ? pageElements[$0] : nil
                })
            }
        }
        NSAccessibility.post(element: self, notification: .layoutChanged)
        if let focused = pageElements.first(where: { $0.isAccessibilityFocused() }), previousFocus != focused.node {
            NSAccessibility.post(element: focused, notification: .focusedUIElementChanged)
        }
    }

    func performPageAccessibilityAction(document: UUID, node: UInt64, press: Bool) -> Bool {
        guard accessibilitySnapshot?.document == document,
              let item = pageElements.first(where: { $0.node == node }),
              press ? item.model?.pressable == true : item.model?.focusable == true else { return false }
        return onAccessibilityAction?(document, node, press) ?? false
    }

    func pageAccessibilityFrame(_ bounds: CGRect) -> CGRect {
        let display = contentRect
        guard drawable.drawableSize.width > 0, drawable.drawableSize.height > 0 else { return .zero }
        let xScale = display.width / drawable.drawableSize.width
        let yScale = display.height / drawable.drawableSize.height
        return NSAccessibility.screenRect(fromView: self, rect: .init(
            x: display.minX + bounds.minX * xScale, y: display.maxY - bounds.maxY * yScale,
            width: bounds.width * xScale, height: bounds.height * yScale))
    }

    override func becomeFirstResponder() -> Bool {
        DispatchQueue.main.async { [weak self] in self?.onFocusChange?() }
        return true
    }

    override func resignFirstResponder() -> Bool {
        updateEditor(nil)
        DispatchQueue.main.async { [weak self] in self?.onFocusChange?() }
        return true
    }

    func updateEditor(_ state: WebKitPresenterChannel.Editor?) {
        let previous = editor
        editor = state
        if previous?.token != state?.token || previous?.secure != state?.secure {
            discardingComposition = true
            inputContext?.discardMarkedText()
            discardingComposition = false
        }
        updateSecureInput()
        if previous != state { inputContext?.invalidateCharacterCoordinates() }
    }

    func updateSecureInput() {
        let needed = editor?.secure == true && window?.isKeyWindow == true &&
            window?.firstResponder === self && NSApp.isActive
        if needed && !secureEventInput {
            secureEventInput = EnableSecureEventInput() == noErr
        } else if !needed && secureEventInput {
            _ = DisableSecureEventInput()
            secureEventInput = false
        }
        inputContext?.allowedInputSourceLocales = secureEventInput ? [NSAllRomanInputSourcesLocaleIdentifier] : nil
    }

    private func sendEdit(_ action: WebKitPresenterChannel.Action) {
        guard !discardingComposition, let editor, NSApp.isActive,
              window?.isKeyWindow == true, window?.firstResponder === self,
              !editor.secure || secureEventInput else { return }
        onInput?(action, .init(editor: editor))
    }

    private var contentRect: CGRect {
        WebKitFrameTransport.PreviewGeometry.fit(drawable.drawableSize, inside: bounds)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        drawable.bounds = CGRect(origin: .zero, size: contentRect.size)
        drawable.position = CGPoint(x: contentRect.midX, y: contentRect.midY)
        CATransaction.commit()
        inputContext?.invalidateCharacterCoordinates()
    }

    private func point(_ event: NSEvent) -> CGPoint? {
        WebKitFrameTransport.PreviewGeometry.normalized(convert(event.locationInWindow, from: nil), in: contentRect)
    }

    override func mouseDown(with event: NSEvent) {
        downInsideContent = event.clickCount == 1 && point(event) != nil
        if downInsideContent { window?.makeFirstResponder(self) }
    }

    override func mouseDragged(with event: NSEvent) { downInsideContent = false }

    override func mouseUp(with event: NSEvent) {
        defer { downInsideContent = false }
        guard downInsideContent, let local = point(event), let window, window.isKeyWindow,
              window.screen != nil, let primary = NSScreen.screens.first else { return }
        let global = WebKitFrameTransport.PreviewGeometry.globalTopLeft(
            window.convertPoint(toScreen: event.locationInWindow), primaryDisplayTop: primary.frame.maxY)
        updateEditor(nil)
        onInput?(.click(x: local.x, y: local.y, screenX: global.x, screenY: global.y), nil)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let point = point(event) else { return }
        onInput?(.scroll(x: point.x, y: point.y, deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY), nil)
    }

    override func keyDown(with event: NSEvent) {
        updateSecureInput()
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if event.keyCode == UInt16(kVK_Tab),
           modifiers == [] || modifiers == .shift,
           NSApp.isActive, window?.isKeyWindow == true, window?.firstResponder === self {
            if editor?.marked != nil { inputContext?.discardMarkedText() }
            onInput?(.tabKey(backward: modifiers == .shift), nil)
            return
        }
        guard let editor else {
            super.keyDown(with: event)
            return
        }
        guard !editor.secure || secureEventInput else { return }
        if inputContext?.handleEvent(event) != true { super.keyDown(with: event) }
    }

    private func text(_ value: Any) -> String? {
        (value as? NSAttributedString)?.string ?? value as? String
    }

    func insertText(_ value: Any, replacementRange: NSRange) {
        guard let text = text(value) else { return }
        sendEdit(.insert(text: text, replacing: .init(replacementRange)))
    }

    func setMarkedText(_ value: Any, selectedRange: NSRange, replacementRange: NSRange) {
        guard editor?.secure == false, let text = text(value),
              let selection = WebKitPresenterChannel.TextRange(selectedRange) else { return }
        sendEdit(.mark(text: text, selected: selection, replacing: .init(replacementRange)))
    }

    func unmarkText() {
        if editor?.secure == false { sendEdit(.unmark) }
    }

    override func doCommand(by selector: Selector) {
        let name = NSStringFromSelector(selector)
        let base = name.dropLast()
        guard name.last == ":", let first = base.first else {
            super.doCommand(by: selector)
            return
        }
        let raw = first.uppercased() + base.dropFirst()
        let command = name == "cancelOperation:" ? .cancel : WebKitPresenterChannel.EditCommand(rawValue: raw)
        if let command { sendEdit(.edit(command)) }
        else { super.doCommand(by: selector) }
    }

    private static let missingRange = NSRange(location: NSNotFound, length: 0)
    func hasMarkedText() -> Bool { editor?.marked != nil }
    func markedRange() -> NSRange { editor?.marked?.native ?? Self.missingRange }
    func selectedRange() -> NSRange { editor?.selected?.native ?? Self.missingRange }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func attributedSubstring(forProposedRange range: NSRange,
                             actualRange: NSRangePointer?) -> NSAttributedString? {
        actualRange?.pointee = Self.missingRange
        return nil
    }
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        actualRange?.pointee = Self.missingRange
        guard let editor, !editor.secure, let selected = editor.selected, let caret = editor.caret,
              let window, caret.height > 0 else { return .zero }
        let content = contentRect
        guard content.width > 0, content.height > 0 else { return .zero }
        let scaleX = content.width / drawable.drawableSize.width
        let scaleY = content.height / drawable.drawableSize.height
        let local = NSRect(x: content.minX + caret.minX * scaleX,
                           y: content.maxY - caret.maxY * scaleY,
                           width: max(1, caret.width * scaleX), height: caret.height * scaleY)
        actualRange?.pointee = NSRange(location: selected.location, length: 0)
        return window.convertToScreen(convert(local, to: nil))
    }
    func characterIndex(for point: NSPoint) -> Int { NSNotFound }
}

@MainActor
private final class WebKitPageAccessibilityElement: NSAccessibilityElement {
    private weak var view: WebKitPresenterView?
    private let document: UUID
    let node: UInt64
    var model: WebKitPresenterChannel.AccessibilitySnapshot.Node?

    init(view: WebKitPresenterView, document: UUID, node: UInt64) {
        self.view = view
        self.document = document
        self.node = node
        super.init()
        setAccessibilityElement(true)
    }

    nonisolated override func accessibilityRole() -> NSAccessibility.Role? {
        guard Thread.isMainThread else { return nil }
        return MainActor.assumeIsolated { model.map { NSAccessibility.Role(rawValue: $0.role) } }
    }
    nonisolated override func accessibilityLabel() -> String? {
        guard Thread.isMainThread else { return nil }
        return MainActor.assumeIsolated { model?.label }
    }
    nonisolated override func accessibilityFrame() -> CGRect {
        guard Thread.isMainThread else { return .zero }
        return MainActor.assumeIsolated {
            guard let model else { return .zero }
            return view?.pageAccessibilityFrame(model.bounds) ?? .zero
        }
    }
    nonisolated override func isAccessibilityFocused() -> Bool {
        guard Thread.isMainThread else { return false }
        return MainActor.assumeIsolated { model?.focused == true }
    }
    nonisolated override func setAccessibilityFocused(_ focused: Bool) {
        guard focused, Thread.isMainThread else { return }
        MainActor.assumeIsolated {
            _ = view?.performPageAccessibilityAction(document: document, node: node, press: false)
        }
    }
    nonisolated override func accessibilityPerformPress() -> Bool {
        guard Thread.isMainThread else { return false }
        return MainActor.assumeIsolated {
            view?.performPageAccessibilityAction(document: document, node: node, press: true) ?? false
        }
    }
}
#endif
