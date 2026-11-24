import AppKit

enum SimulatorKeyboardInput: Equatable {
    case text(String)
    case key(EditingKey, shift: Bool)
    case selectAll

    enum EditingKey: String {
        case returnKey = "Enter", tab = "Tab", backspace = "Backspace", delete = "Delete"
        case left = "ArrowLeft", right = "ArrowRight", up = "ArrowUp", down = "ArrowDown", escape = "Escape"

        init?(macCode: UInt16) {
            switch macCode {
            case 36, 76: self = .returnKey
            case 48: self = .tab
            case 51: self = .backspace
            case 117: self = .delete
            case 123: self = .left
            case 124: self = .right
            case 125: self = .down
            case 126: self = .up
            case 53: self = .escape
            default: return nil
            }
        }

        var androidCode: Int {
            switch self {
            case .returnKey: 66
            case .tab: 61
            case .backspace: 67
            case .delete: 112
            case .left: 21
            case .right: 22
            case .up: 19
            case .down: 20
            case .escape: 111
            }
        }
    }
}

/// Serialize pasteboard writes, paste shortcuts and subsequent keystrokes per device.
@MainActor
final class SimulatorKeyboardQueue {
    private var tail: Task<Void, Never>?
    private var generation = 0

    func submit(_ operation: @escaping @MainActor () async -> Void) {
        let previous = tail
        let session = generation
        tail = Task {
            await previous?.value
            guard generation == session else { return }
            await operation()
        }
    }

    func reset() {
        generation &+= 1
        tail = nil
    }
}

/// A screen-local first responder. AppKit owns the input method and its candidate window.
final class MacSimulatorKeyboard: NSView, NSTextInputClient {
    var send: ((SimulatorKeyboardInput) -> Void)?
    var onBlur: (() -> Void)?
    private var marked = ""
    private var selection = NSRange(location: 0, length: 0)
    private var anchor = NSPoint.zero
    private var editingKey: SimulatorKeyboardInput?

    @discardableResult
    static func focus(in screen: NSView, at pointInWindow: NSPoint,
                      onBlur: (() -> Void)? = nil, send: @escaping (SimulatorKeyboardInput) -> Void) -> MacSimulatorKeyboard? {
        guard let window = screen.window else { return nil }
        let keyboard: MacSimulatorKeyboard
        if let existing = screen.subviews.compactMap({ $0 as? MacSimulatorKeyboard }).first {
            keyboard = existing
            keyboard.discardComposition()
        } else {
            keyboard = MacSimulatorKeyboard(frame: .zero)
            screen.addSubview(keyboard)
        }
        keyboard.anchor = screen.convert(pointInWindow, from: nil)
        keyboard.send = send
        keyboard.onBlur = onBlur
        return window.makeFirstResponder(keyboard) ? keyboard : nil
    }

    override var acceptsFirstResponder: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func resignFirstResponder() -> Bool {
        discardComposition()
        onBlur?()
        return super.resignFirstResponder()
    }

    private func discardComposition() {
        guard hasMarkedText() else { return }
        clearMark()
        inputContext?.discardMarkedText()
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags
        if flags.contains(.command) || flags.contains(.control) {
            super.keyDown(with: event)
            return
        }
        // Input methods can keep their preedit in a separate candidate window.
        // Let the input method consume Delete, arrows and Return before routing an editing command.
        editingKey = SimulatorKeyboardInput.EditingKey(macCode: event.keyCode).map {
            .key($0, shift: flags.contains(.shift))
        }
        defer { editingKey = nil }
        if inputContext?.handleEvent(event) == true { return }
        if let editingKey, !hasMarkedText() { send?(editingKey) }
        else { super.keyDown(with: event) }
    }

    override func doCommand(by selector: Selector) {
        if let editingKey {
            if !hasMarkedText() { send?(editingKey) }
        } else {
            super.doCommand(by: selector)
        }
    }

    override func flagsChanged(with event: NSEvent) {
        if inputContext?.handleEvent(event) != true { super.flagsChanged(with: event) }
    }

    override func deleteBackward(_ sender: Any?) {
        if !hasMarkedText() { send?(.key(.backspace, shift: false)) }
    }

    override func deleteForward(_ sender: Any?) {
        if !hasMarkedText() { send?(.key(.delete, shift: false)) }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard window?.firstResponder === self, flags == .command else { return false }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "a": selectAll(nil)
        case "v": paste(nil)
        default: return false
        }
        return true
    }

    override func selectAll(_ sender: Any?) {
        discardComposition()
        send?(.selectAll)
    }

    @objc func paste(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        discardComposition()
        send?(.text(text))
    }

    func insertText(_ value: Any, replacementRange: NSRange) {
        clearMark()
        let text = Self.string(value)
        if !text.isEmpty { send?(.text(text)) }
    }

    func setMarkedText(_ value: Any, selectedRange: NSRange, replacementRange: NSRange) {
        marked = Self.string(value)
        selection = selectedRange
    }

    func unmarkText() {
        if !marked.isEmpty { send?(.text(marked)) }
        clearMark()
    }

    private func clearMark() {
        marked = ""
        selection = NSRange(location: 0, length: 0)
    }

    private static func string(_ value: Any) -> String {
        (value as? NSAttributedString)?.string ?? (value as? String ?? "")
    }

    func hasMarkedText() -> Bool { !marked.isEmpty }
    func markedRange() -> NSRange { NSRange(location: marked.isEmpty ? NSNotFound : 0, length: marked.utf16.count) }
    func selectedRange() -> NSRange { selection }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        let valid = NSIntersectionRange(range, NSRange(location: 0, length: marked.utf16.count))
        actualRange?.pointee = valid
        guard valid.length > 0 else { return nil }
        return NSAttributedString(string: (marked as NSString).substring(with: valid))
    }
    func characterIndex(for point: NSPoint) -> Int { NSNotFound }
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let window, let screen = superview else { return .zero }
        actualRange?.pointee = NSRange(location: 0, length: 0)
        return window.convertToScreen(screen.convert(NSRect(origin: anchor, size: NSSize(width: 1, height: 16)), to: nil))
    }
}
