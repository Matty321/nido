// SPDX-License-Identifier: Apache-2.0
import AppKit
import Testing

@testable import Nido

/// The console view's grid size, reported to the model when the view is resized.
@MainActor
struct TerminalViewTests {
    /// Lets the main queue run what `setFrameSize` dispatched (`onResize` is asynchronous).
    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    @Test func emptyFrameKeepsTheGridThenARealSizeReportsIt() async {
        let view = TerminalNSView(frame: .zero)
        var reported: [(columns: Int, rows: Int)] = []
        view.onResize = { reported.append(($0, $1)) }

        // The first layout pass: an empty frame must not shrink the grid to 1×1.
        view.setFrameSize(.zero)
        view.setFrameSize(NSSize(width: 4, height: 4))
        await drainMainQueue()
        #expect(reported.isEmpty, "Ridimensionamenti con cornice vuota: \(reported)")

        // The console area of the 1100×720 window: a real grid.
        view.setFrameSize(NSSize(width: 1100, height: 650))
        await drainMainQueue()
        #expect(reported.count == 1)
        if let size = reported.last {
            #expect(size.columns > 80, "colonne: \(size.columns)")
            #expect(size.rows > 20, "righe: \(size.rows)")
        }
    }

    private static let noRange = NSRange(location: NSNotFound, length: 0)

    /// Text input goes through `NSTextInputClient`: a dead key (⌥E on a US or Italian layout)
    /// shows as marked text and sends nothing; the composed character is sent once, as UTF-8.
    @Test func deadKeyComposesAccent() {
        let view = TerminalNSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        var sent = Data()
        view.onInput = { sent.append($0) }

        view.setMarkedText("´", selectedRange: NSRange(location: 1, length: 0), replacementRange: Self.noRange)
        #expect(view.hasMarkedText())
        #expect(view.markedRange() == NSRange(location: 0, length: 1))
        #expect(sent.isEmpty)

        view.insertText("é", replacementRange: Self.noRange)
        #expect(!view.hasMarkedText())
        #expect(sent == Data("é".utf8))

        // IME output may arrive as an attributed string, several characters at once.
        view.insertText(NSAttributedString(string: "日本"), replacementRange: Self.noRange)
        #expect(sent == Data("é日本".utf8))

        // A composition abandoned with unmarkText sends nothing.
        view.setMarkedText("¨", selectedRange: NSRange(location: 1, length: 0), replacementRange: Self.noRange)
        view.unmarkText()
        #expect(!view.hasMarkedText())
        #expect(sent == Data("é日本".utf8))

        // AppKit's private-use function-key characters never reach the guest.
        view.insertText("\u{F704}", replacementRange: Self.noRange)
        #expect(sent == Data("é日本".utf8))

        // Not while the VM is not running.
        view.acceptsInput = false
        view.insertText("x", replacementRange: Self.noRange)
        #expect(sent == Data("é日本".utf8))
    }

    /// The control keys keep their bytes and never go through the input system.
    @Test func controlKeysKeepTheirBytes() {
        func direct(_ characters: String, _ special: NSEvent.SpecialKey?, keyCode: UInt16 = 0,
                    _ modifiers: NSEvent.ModifierFlags = []) -> Data? {
            TerminalInput.directBytes(characters: characters, charactersIgnoringModifiers: characters,
                                      specialKey: special, keyCode: keyCode, modifiers: modifiers)
        }
        #expect(direct("\r", .carriageReturn) == Data("\r".utf8))
        #expect(direct("\u{7F}", .delete) == Data([0x7F]))
        #expect(direct("\u{F700}", .upArrow) == Data("\u{1B}[A".utf8))
        #expect(direct("\u{1B}", nil, keyCode: 53) == Data([0x1B]))
        #expect(direct("c", nil, [.control]) == Data([0x03]))
        // Text (also with ⌥) is for the input system: dead keys and IME compose there.
        #expect(direct("e", nil) == nil)
        #expect(direct("´", nil, [.option]) == nil)
        // ⌘ shortcuts stay with the app.
        #expect(direct("c", nil, [.command]) == nil)
    }

    /// The view takes a new buffer only when its generation changed: no comparison of the whole
    /// grid on every SwiftUI update.
    @Test func viewUpdatesOnGenerationOnly() {
        let view = TerminalNSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        var buffer = TerminalBuffer(columns: 20, rows: 3)
        buffer.feed(Data("a".utf8))
        #expect(view.show(buffer))
        #expect(!view.show(buffer), "Stessa generazione: nessun aggiornamento")
        buffer.feed(Data("b".utf8))
        #expect(view.show(buffer))
        #expect(view.buffer.lines[0] == "ab")
        // Same text, another buffer (a new session): it still redraws.
        var other = TerminalBuffer(columns: 20, rows: 3)
        other.feed(Data("ab".utf8))
        #expect(view.show(other))
    }

    private func scratchPasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("nido-test-\(UUID().uuidString)"))
    }

    /// ⌘C copies the selected cells (scrollback included), trailing spaces trimmed per line;
    /// without a selection it does nothing.
    @Test func copySelectionReturnsText() {
        let view = TerminalNSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        var buffer = TerminalBuffer(columns: 20, rows: 2)
        buffer.feed(Data("one   \r\ntwo\r\nthree".utf8))
        view.show(buffer)
        let board = scratchPasteboard()
        defer { board.releaseGlobally() }
        view.pasteboard = board
        board.clearContents()
        board.setString("prima", forType: .string)

        view.copy(nil)
        #expect(board.string(forType: .string) == "prima", "Senza selezione ⌘C non fa nulla")

        view.selectCells(from: .init(row: 0, column: 1), to: .init(row: 2, column: 2))
        #expect(view.selectedText == "ne\ntwo\nthr")
        view.copy(nil)
        #expect(board.string(forType: .string) == "ne\ntwo\nthr")

        // The selection follows its lines when more output scrolls the screen.
        buffer.feed(Data("\r\nfour".utf8))
        view.show(buffer)
        #expect(view.selectedText == "ne\ntwo\nthr")
    }

    /// A mouse drag selects cells; ⌘C (a key equivalent) copies them; a click clears the selection.
    @Test func mouseDragSelectsAndCommandCCopies() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.borderless], backing: .buffered, defer: true)
        let view = TerminalNSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        window.contentView = view
        var buffer = TerminalBuffer(columns: 40, rows: 5)
        buffer.feed(Data("root@debian:~# ls\r\nbin  etc  home".utf8))
        view.show(buffer)
        let board = scratchPasteboard()
        defer { board.releaseGlobally() }
        view.pasteboard = board
        board.clearContents()

        func mouse(_ type: NSEvent.EventType, row: Int, column: Int) -> NSEvent {
            let point = view.convert(view.cellCenter(row: row, column: column), to: nil)
            return NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                      windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                      clickCount: 1, pressure: 1)!
        }
        view.mouseDown(with: mouse(.leftMouseDown, row: 0, column: 5))
        view.mouseDragged(with: mouse(.leftMouseDragged, row: 1, column: 2))
        view.mouseUp(with: mouse(.leftMouseUp, row: 1, column: 2))
        #expect(view.selectedText == "debian:~# ls\nbin")

        window.makeFirstResponder(view)
        let commandC = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "c", charactersIgnoringModifiers: "c",
            isARepeat: false, keyCode: 8))
        #expect(view.performKeyEquivalent(with: commandC))
        #expect(board.string(forType: .string) == "debian:~# ls\nbin")

        view.mouseDown(with: mouse(.leftMouseDown, row: 0, column: 0))
        view.mouseUp(with: mouse(.leftMouseUp, row: 0, column: 0))
        #expect(view.selectedText == nil)
    }

    /// Keys the input system turns into commands (after a dead key: ⌥E then Return commits "´"
    /// and then asks for insertNewline:) reach the guest with the bytes of the key.
    @Test func commandsAfterDeadKeySendTheirBytes() {
        let view = TerminalNSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        var sent: [Data] = []
        view.onInput = { sent.append($0) }
        let expected: [(Selector, String)] = [
            (#selector(NSResponder.insertNewline(_:)), "\r"),
            (#selector(NSResponder.insertTab(_:)), "\t"),
            (#selector(NSResponder.insertBacktab(_:)), "\u{1B}[Z"),
            (#selector(NSResponder.deleteBackward(_:)), "\u{7F}"),
            (#selector(NSResponder.deleteForward(_:)), "\u{1B}[3~"),
            (#selector(NSResponder.cancelOperation(_:)), "\u{1B}"),
            (#selector(NSResponder.moveUp(_:)), "\u{1B}[A"),
            (#selector(NSResponder.moveDown(_:)), "\u{1B}[B"),
            (#selector(NSResponder.moveRight(_:)), "\u{1B}[C"),
            (#selector(NSResponder.moveLeft(_:)), "\u{1B}[D"),
            (#selector(NSResponder.moveLeftAndModifySelection(_:)), "\u{1B}[D"),
        ]
        for (selector, bytes) in expected {
            sent = []
            view.doCommand(by: selector)
            #expect(sent == [Data(bytes.utf8)], "\(selector)")
        }
        // Commands with no key behind them send nothing.
        sent = []
        view.doCommand(by: #selector(NSResponder.selectAll(_:)))
        #expect(sent.isEmpty)
        // Not while the VM is not running.
        view.acceptsInput = false
        view.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        #expect(sent.isEmpty)
    }

    /// A selection belongs to the text it was made on: another session's buffer, or the guest
    /// clearing the screen, drops it, and ⌘C then copies nothing.
    @Test func bufferSwapClearsSelection() {
        let view = TerminalNSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let board = scratchPasteboard()
        defer { board.releaseGlobally() }
        view.pasteboard = board
        var buffer = TerminalBuffer(columns: 20, rows: 3)
        buffer.feed(Data("secret\r\nline".utf8))
        view.show(buffer)
        view.selectCells(from: .init(row: 0, column: 0), to: .init(row: 0, column: 5))
        #expect(view.selectedText == "secret")

        var other = TerminalBuffer(columns: 20, rows: 3)
        other.feed(Data("secret\r\nline".utf8))
        view.show(other)
        #expect(view.selectedText == nil)
        board.clearContents()
        view.copy(nil)
        #expect(board.string(forType: .string) == nil)

        // ED 2 on the same buffer: the selected text is gone.
        view.selectCells(from: .init(row: 0, column: 0), to: .init(row: 0, column: 5))
        other.feed(Data("\u{1B}[2J".utf8))
        view.show(other)
        #expect(view.selectedText == nil)
        // Plain output keeps it.
        view.selectCells(from: .init(row: 1, column: 0), to: .init(row: 1, column: 3))
        other.feed(Data("more".utf8))
        view.show(other)
        #expect(view.selectedText != nil)
    }
}
