import AppKit
import XCTest
import SimKit
@testable import SimLab

final class MacSimulatorKeyboardTests: XCTestCase {
    @MainActor
    func testCompositionSendsOnlyTheCommit() {
        let keyboard = MacSimulatorKeyboard()
        var inputs: [SimulatorKeyboardInput] = []
        keyboard.send = { inputs.append($0) }
        let range = NSRange(location: NSNotFound, length: 0)
        for spelling in ["n", "ni", "nihao"] {
            keyboard.setMarkedText(spelling, selectedRange: NSRange(location: spelling.utf16.count, length: 0),
                                   replacementRange: range)
        }
        XCTAssertTrue(inputs.isEmpty)
        keyboard.insertText(NSAttributedString(string: "你好"), replacementRange: range)
        keyboard.unmarkText()
        XCTAssertEqual(inputs, [.text("你好")])
        XCTAssertFalse(keyboard.hasMarkedText())
    }

    @MainActor
    func testIPhoneCanvasRestoresKeyboardForDelete() throws {
        _ = NSApplication.shared
        let rect = NSRect(x: 0, y: 0, width: 160, height: 120)
        let window = NSWindow(contentRect: rect, styleMask: [.titled], backing: .buffered, defer: false)
        let screen = SimulatorScreenView(frame: rect)
        window.contentView?.addSubview(screen)
        var inputs: [SimulatorKeyboardInput] = []
        screen.onKeyboardFocus = { [weak screen] point in
            guard let screen else { return nil }
            return MacSimulatorKeyboard.focus(in: screen, at: point) { inputs.append($0) }
        }
        XCTAssertTrue(window.makeFirstResponder(screen))
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\u{7f}", charactersIgnoringModifiers: "\u{7f}",
            isARepeat: false, keyCode: 51))
        window.sendEvent(event)
        let keyboard = try XCTUnwrap(window.firstResponder as? MacSimulatorKeyboard)
        keyboard.doCommand(by: #selector(NSResponder.deleteForward(_:)))
        XCTAssertEqual(inputs, [.key(.backspace, shift: false), .key(.delete, shift: false)])
    }

    @MainActor
    func testFocusRoutesKeysAndDiscardsUnfinishedComposition() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 220, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let left = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let right = NSView(frame: NSRect(x: 120, y: 0, width: 100, height: 100))
        window.contentView?.addSubview(left)
        window.contentView?.addSubview(right)
        var first: [SimulatorKeyboardInput] = [], second: [SimulatorKeyboardInput] = []
        MacSimulatorKeyboard.focus(in: left, at: .zero) { first.append($0) }
        let a = try XCTUnwrap(window.firstResponder as? MacSimulatorKeyboard)
        let range = NSRange(location: NSNotFound, length: 0)
        a.setMarkedText("unfinished", selectedRange: .init(location: 10, length: 0), replacementRange: range)
        MacSimulatorKeyboard.focus(in: right, at: .zero) { second.append($0) }
        let b = try XCTUnwrap(window.firstResponder as? MacSimulatorKeyboard)
        XCTAssertFalse(a === b)
        XCTAssertFalse(a.hasMarkedText())
        b.keyDown(with: try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "m", charactersIgnoringModifiers: "m",
            isARepeat: false, keyCode: 46)))
        for (code, chars, flags) in [(UInt16(51), "\u{7f}", NSEvent.ModifierFlags()), (123, "\u{f702}", .shift), (36, "\r", [])] {
            b.keyDown(with: try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars,
                isARepeat: false, keyCode: code)))
        }
        XCTAssertTrue(first.isEmpty)
        XCTAssertEqual(second, [.text("m"), .key(.backspace, shift: false), .key(.left, shift: true), .key(.returnKey, shift: false)])
    }
}
