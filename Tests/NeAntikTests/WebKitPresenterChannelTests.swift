import Foundation
import Testing
@testable import NeAntik

struct WebKitPresenterChannelTests {
    @Test func staleInputDoesNotReachAnotherTabOrFocus() throws {
        let generation = UUID(), tab = UUID(), navigation = UUID()
        let initial = WebKitPresenterChannel.Target(tab: tab, navigation: navigation, focus: UUID())
        let current = WebKitPresenterChannel.Target(tab: tab, navigation: navigation, focus: UUID())
        let editor = WebKitPresenterChannel.EditTarget(editor: .init(
            token: UUID(), secure: false, selected: nil, marked: nil, caret: nil))
        var fence = WebKitPresenterChannel.Fence(generation: generation)
        let stale = WebKitPresenterChannel.Command(generation: generation, sequence: 1, target: initial,
                                                   action: .insert(text: "あ", replacing: nil), editor: editor)
        let fresh = WebKitPresenterChannel.Command(generation: generation, sequence: 2, target: current,
                                                   action: .insert(text: "い", replacing: nil), editor: editor)
        #expect(try fence.receive(stale, current: current) == false)
        #expect(try fence.receive(fresh, current: current))
        #expect(throws: WebKitPresenterChannel.Failure.invalidRecord) {
            try fence.receive(fresh, current: current)
        }
    }

    @Test func secureEditorCannotTransportCaretOrCompositionMetadata() {
        let selection = WebKitPresenterChannel.TextRange(location: 2, length: 0)
        let editor = WebKitPresenterChannel.Editor(token: UUID(), secure: true,
                                                    selected: nil, marked: nil, caret: nil)
        let generation = UUID()
        let target = WebKitPresenterChannel.Target(tab: UUID(), navigation: UUID(), focus: UUID())
        typealias Action = WebKitPresenterChannel.Action
        func command(_ action: Action, editor: WebKitPresenterChannel.EditTarget?) -> WebKitPresenterChannel.Command {
            WebKitPresenterChannel.Command(generation: generation, sequence: 1, target: target,
                                             action: action, editor: editor)
        }
        let secureTarget = WebKitPresenterChannel.EditTarget(editor: editor)
        let replacementAllowed = command(.insert(text: "synthetic", replacing: selection), editor: secureTarget).isValid
        let compositionAllowed = command(.mark(text: "字", selected: .init(location: 1, length: 0), replacing: nil),
                                         editor: secureTarget).isValid
        let undoAllowed = command(.edit(.undo), editor: secureTarget).isValid
        #expect(editor.isValid)
        #expect(!WebKitPresenterChannel.Editor(token: editor.token, secure: true,
                                                selected: selection, marked: nil, caret: nil).isValid)
        #expect(command(.insert(text: "synthetic", replacing: nil), editor: secureTarget).isValid)
        #expect(replacementAllowed == false)
        #expect(compositionAllowed == false)
        #expect(undoAllowed == false)
        #expect(command(.edit(.deleteBackward), editor: secureTarget).isValid)
        #expect(!command(.insert(text: "synthetic", replacing: nil), editor: nil).isValid)
    }

    @Test func validatesUTF16SelectionAndUntrustedCoordinates() {
        typealias Action = WebKitPresenterChannel.Action
        #expect(Action.mark(text: "😀", selected: .init(location: 2, length: 0), replacing: nil).isValid)
        #expect(!Action.mark(text: "😀", selected: .init(location: 2, length: 1), replacing: nil).isValid)
        #expect(!Action.insert(text: "x", replacing: .init(location: Int.max, length: Int.max)).isValid)
        #expect(!Action.click(x: Double.nan, y: 0.5, screenX: 2, screenY: 3).isValid)
        #expect(!Action.activity(visible: false, active: false, focused: true).isValid)
        #expect(!Action.navigate(.open("https://example.test/\n")).isValid)
        #expect(!Action.insert(text: String(repeating: "\\", count: 4_097), replacing: nil).isValid)
        #expect(!Action.insert(text: String(repeating: "\u{1}", count: 4_096), replacing: nil).isValid)
        #expect(Action.insert(text: "résumé\n水", replacing: nil).isValid)
    }

    @Test func carriesInputWithoutConsumingLifecycleFrames() throws {
        let (manager, host) = try ProxyRelayPrivatePipe.anonymousSocketPair()
        let sender = try WebKitPresenterChannel.offer(to: manager.fileDescriptor, timeout: 1)
        let receiver = try WebKitPresenterChannel.accept(from: host.fileDescriptor, timeout: 1)
        let target = WebKitPresenterChannel.Target(tab: UUID(), navigation: UUID(), focus: UUID())
        let command = WebKitPresenterChannel.Command(generation: UUID(), sequence: 1, target: target,
                                                      action: .navigate(.back))
        try WebKitPresenterChannel.write(command, to: sender, timeout: 1)
        let payload = Data("lifecycle".utf8)
        try ProxyRelayPrivatePipe.writeFrame(manager.fileDescriptor, data: payload, timeout: 1)
        #expect(try WebKitPresenterChannel.read(from: receiver, timeout: 1) == command)
        #expect(try ProxyRelayPrivatePipe.readFrame(host.fileDescriptor, timeout: 1) == payload)
    }
}
