import CoreGraphics
import Darwin
import Foundation

/// Separate from frame acknowledgements and the profile's lifecycle pipe.
/// Use one sequential reader and one sequential writer at each endpoint.
enum WebKitPresenterChannel {
    struct Target: Codable, Equatable, Sendable {
        let tab: UUID
        let navigation: UUID
        let focus: UUID
    }

    struct TextRange: Codable, Equatable, Sendable {
        let location: Int
        let length: Int

        var isValid: Bool {
            guard let location = UInt32(exactly: location), let length = UInt32(exactly: length)
            else { return false }
            return length <= UInt32.max - location
        }

        init(location: Int, length: Int) {
            self.location = location
            self.length = length
        }

        init?(_ range: NSRange) {
            self.init(location: range.location, length: range.length)
            guard isValid else { return nil }
        }

        var native: NSRange { NSRange(location: location, length: length) }
    }

    enum EditCommand: String, Codable, Equatable, Sendable {
        case cancel
        case deleteBackward = "DeleteBackward", deleteForward = "DeleteForward"
        case moveLeft = "MoveLeft", moveRight = "MoveRight", moveUp = "MoveUp", moveDown = "MoveDown"
        case moveWordLeft = "MoveWordLeft", moveWordRight = "MoveWordRight"
        case moveLeftAndModifySelection = "MoveLeftAndModifySelection"
        case moveRightAndModifySelection = "MoveRightAndModifySelection"
        case moveToBeginningOfLine = "MoveToBeginningOfLine", moveToEndOfLine = "MoveToEndOfLine"
        case selectAll = "SelectAll", insertNewline = "InsertNewline", undo = "Undo", redo = "Redo"
    }

    struct Editor: Codable, Equatable, Sendable {
        let token: UUID
        let secure: Bool
        let selected: TextRange?
        let marked: TextRange?
        let caret: CGRect?

        var isValid: Bool {
            if secure { return selected == nil && marked == nil && caret == nil }
            guard selected?.isValid != false, marked?.isValid != false else { return false }
            guard let caret else { return true }
            return (-16_384...16_384).contains(caret.origin.x) &&
                (-16_384...16_384).contains(caret.origin.y) &&
                (0...16_384).contains(caret.size.width) && (0...16_384).contains(caret.size.height)
        }
    }

    struct EditTarget: Codable, Equatable, Sendable {
        let token: UUID
        let secure: Bool
        let selected: TextRange?

        init(editor: Editor) {
            token = editor.token
            secure = editor.secure
            selected = editor.selected
        }
    }

    enum Navigation: Codable, Equatable, Sendable {
        case open(String)
        case back, forward, reload, newTab
        case selectTab(UUID)
        case closeTab(UUID)
    }

    enum Action: Codable, Equatable, Sendable {
        case navigate(Navigation)
        case activity(visible: Bool, active: Bool, focused: Bool)
        case click(x: Double, y: Double, screenX: Double, screenY: Double)
        case scroll(x: Double, y: Double, deltaX: Double, deltaY: Double)
        case insert(text: String, replacing: TextRange?)
        case mark(text: String, selected: TextRange, replacing: TextRange?)
        case unmark
        case edit(EditCommand)

        var isValid: Bool {
            switch self {
            case .navigate(.open(let address)):
                return !address.isEmpty && address.utf8.count <= 4_096 &&
                    !address.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            case .navigate:
                return true
            case .activity(let visible, let active, let focused):
                return (!active || visible) && (!focused || active)
            case .click(let x, let y, let screenX, let screenY):
                return (0..<1).contains(x) && (0..<1).contains(y) &&
                    (-100_000...100_000).contains(screenX) && (-100_000...100_000).contains(screenY)
            case .scroll(let x, let y, let deltaX, let deltaY):
                return (0..<1).contains(x) && (0..<1).contains(y) &&
                    (-10_000...10_000).contains(deltaX) && (-10_000...10_000).contains(deltaY)
            case .insert(let text, let replacement):
                return Self.validText(text) && replacement?.isValid != false
            case .mark(let text, let selection, let replacement):
                return Self.validText(text) && selection.isValid &&
                    selection.location <= text.utf16.count &&
                    selection.length <= text.utf16.count - selection.location &&
                    replacement?.isValid != false
            case .unmark, .edit:
                return true
            }
        }

        var requiresEditor: Bool {
            switch self {
            case .insert, .mark, .unmark, .edit: true
            default: false
            }
        }

        private static func validText(_ text: String) -> Bool {
            text.utf8.count <= 4_096 && text.utf8.allSatisfy {
                $0 >= 0x20 || [0x09, 0x0A, 0x0D].contains($0)
            }
        }
    }

    struct Command: Codable, Equatable, Sendable {
        let generation: UUID
        let sequence: UInt64
        let target: Target
        let action: Action
        let editor: EditTarget?

        init(generation: UUID, sequence: UInt64, target: Target, action: Action, editor: EditTarget? = nil) {
            self.generation = generation
            self.sequence = sequence
            self.target = target
            self.action = action
            self.editor = editor
        }

        var isValid: Bool {
            guard action.isValid, action.requiresEditor == (editor != nil) else { return false }
            guard let editor else { return true }
            guard editor.selected?.isValid != false, !editor.secure || editor.selected == nil else { return false }
            if editor.secure {
                switch action {
                case .insert(_, let replacement): return replacement == nil
                case .edit(.cancel), .edit(.insertNewline), .edit(.undo), .edit(.redo): return false
                case .edit: return true
                default: return false
                }
            }
            switch action {
            case .insert(_, let replacement), .mark(_, _, let replacement):
                return replacement == nil || editor.selected != nil
            default: break
            }
            return true
        }
    }

    struct State: Codable, Equatable, Sendable {
        struct Tab: Codable, Equatable, Sendable {
            let id: UUID
            let title: String
        }

        let generation: UUID
        let target: Target
        let tabs: [Tab]
        let address: String
        let canGoBack: Bool
        let canGoForward: Bool
        let acceptsPageInput: Bool
        let status: String
        let editor: Editor?

        init(generation: UUID, target: Target, tabs: [Tab], address: String,
             canGoBack: Bool, canGoForward: Bool, acceptsPageInput: Bool, status: String,
             editor: Editor? = nil) {
            self.generation = generation
            self.target = target
            self.tabs = tabs
            self.address = address
            self.canGoBack = canGoBack
            self.canGoForward = canGoForward
            self.acceptsPageInput = acceptsPageInput
            self.status = status
            self.editor = editor
        }

        var isValid: Bool {
            !tabs.isEmpty && tabs.count <= 32 &&
                Set(tabs.map(\.id)).count == tabs.count &&
                tabs.contains { $0.id == target.tab } &&
                tabs.allSatisfy { $0.title.utf8.count <= 128 &&
                    !$0.title.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) } &&
                address.utf8.count <= 2_048 && status.utf8.count <= 512 &&
                editor?.isValid != false && (acceptsPageInput || editor == nil)
        }
    }

    /// Ordered transport and page custody are checked independently. Consuming
    /// a late record does not apply it to the current tab, navigation or focus.
    struct Fence: Sendable {
        let generation: UUID
        private var next: UInt64 = 1

        init(generation: UUID) {
            self.generation = generation
        }

        mutating func consume(_ command: Command) throws {
            guard command.generation == generation, command.sequence == next, next < UInt64.max,
                  command.isValid else { throw Failure.invalidRecord }
            next += 1
        }

        mutating func receive(_ command: Command, current: Target?) throws -> Bool {
            try consume(command)
            return command.target == current
        }
    }

    enum Failure: Error, Equatable {
        case invalidRecord
    }

    static func offer(to bootstrap: Int32, timeout: TimeInterval) throws -> FileHandle {
        let (presenter, renderer) = try ProxyRelayPrivatePipe.anonymousSocketPair()
        try ProxyRelayPrivatePipe.sendDescriptor(renderer.fileDescriptor, to: bootstrap, timeout: timeout)
        return presenter
    }

    static func accept(from bootstrap: Int32, timeout: TimeInterval) throws -> FileHandle {
        let channel = try ProxyRelayPrivatePipe.receiveDescriptor(from: bootstrap, timeout: timeout)
        try ProxyRelayPrivatePipe.prepareAnonymousSocket(channel.fileDescriptor)
        return channel
    }

    static func write(_ command: Command, to channel: FileHandle, timeout: TimeInterval) throws {
        guard command.isValid else { throw Failure.invalidRecord }
        try ProxyRelayPrivatePipe.writeFrame(channel.fileDescriptor, data: JSONEncoder().encode(command), timeout: timeout)
    }

    static func read(from channel: FileHandle, timeout: TimeInterval) throws -> Command {
        let data = try ProxyRelayPrivatePipe.readFrame(channel.fileDescriptor, timeout: timeout)
        let command = try JSONDecoder().decode(Command.self, from: data)
        guard command.isValid else { throw Failure.invalidRecord }
        return command
    }

}
