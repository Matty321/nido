// SPDX-License-Identifier: Apache-2.0
import AppKit
import SwiftUI

/// Keys and pastes to the bytes a VT220/xterm terminal sends. Pure, for the tests.
enum TerminalInput {
    /// A paste larger than this is cut, at a character boundary. Half the console's input queue:
    /// a max-size paste with its bracket markers always fits whole (`SerialConsole.send` drops a
    /// chunk that does not fit, never a part of it).
    static let maxPaste = 32 * 1024

    /// The bytes for a key press, or nil when the key is not for the guest (⌘-shortcuts stay
    /// with the app; unmapped function keys send nothing). The view sends the keys of
    /// `directBytes` itself and gives text keys to the input system (`NSTextInputClient`), which
    /// ends in `text(_:)`; this is both together, as one key press without composition.
    static func bytes(characters: String?, charactersIgnoringModifiers: String?, specialKey: NSEvent.SpecialKey?,
                      keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Data? {
        if modifiers.intersection(.deviceIndependentFlagsMask).contains(.command) { return nil }
        if let direct = directBytes(characters: characters, charactersIgnoringModifiers: charactersIgnoringModifiers,
                                    specialKey: specialKey, keyCode: keyCode, modifiers: modifiers) {
            return direct
        }
        if specialKey != nil { return nil }
        return characters.flatMap(text)
    }

    /// Keys that are not text: Escape, Return, Backspace, Tab, arrows and the other special keys,
    /// ⌃-combinations. Nil for a text key (with or without ⌥: dead keys and input methods compose
    /// it), for a ⌘-shortcut and for an unmapped special key.
    static func directBytes(characters: String?, charactersIgnoringModifiers: String?, specialKey: NSEvent.SpecialKey?,
                            keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Data? {
        let modifiers = modifiers.intersection(.deviceIndependentFlagsMask)
        if modifiers.contains(.command) { return nil }
        if keyCode == escapeKeyCode { return Data([0x1B]) }
        if let specialKey {
            return special(specialKey).map { Data($0.utf8) }
        }
        if modifiers.contains(.control), let control = control(charactersIgnoringModifiers) {
            return Data([control])
        }
        return nil
    }

    /// Text from the input system (a key, a composed accent, an IME commit) as UTF-8, or nil when
    /// nothing is left: AppKit's private-use function-key characters (F1…, Help…) and control
    /// characters are dropped (the control keys go through `directBytes`).
    static func text(_ string: String) -> Data? {
        var scalars = String.UnicodeScalarView()
        for scalar in string.unicodeScalars {
            switch scalar.value {
            case 0xF700...0xF8FF, 0x00..<0x20, 0x7F, 0x80...0x9F: continue
            default: scalars.append(scalar)
            }
        }
        return scalars.isEmpty ? nil : Data(String(scalars).utf8)
    }

    /// kVK_Escape.
    private static let escapeKeyCode: UInt16 = 53

    private static func special(_ key: NSEvent.SpecialKey) -> String? {
        switch key {
        case .carriageReturn, .enter, .newline: "\r"
        case .delete, .backspace: "\u{7F}"
        case .tab: "\t"
        case .backTab: "\u{1B}[Z"
        case .upArrow: "\u{1B}[A"
        case .downArrow: "\u{1B}[B"
        case .rightArrow: "\u{1B}[C"
        case .leftArrow: "\u{1B}[D"
        case .home: "\u{1B}[H"
        case .end: "\u{1B}[F"
        case .pageUp: "\u{1B}[5~"
        case .pageDown: "\u{1B}[6~"
        case .deleteForward: "\u{1B}[3~"
        default: nil
        }
    }

    /// ⌃A…⌃Z → 0x01…0x1A, ⌃[ ⌃\ ⌃] → ESC FS GS, ⌃Space/⌃@ → NUL, ⌃_ ⌃/ → US.
    private static func control(_ characters: String?) -> UInt8? {
        guard let scalars = characters?.lowercased().unicodeScalars, scalars.count == 1,
              let value = scalars.first.map({ $0.value }) else { return nil }
        switch value {
        case 0x61...0x7A: return UInt8(value - 0x60)
        case 0x5B: return 0x1B
        case 0x5C: return 0x1C
        case 0x5D: return 0x1D
        case 0x20, 0x40: return 0x00
        case 0x5F, 0x2F: return 0x1F
        default: return nil
        }
    }

    /// Pasted text: newlines become Return, control characters (ESC included) are dropped so a
    /// paste cannot smuggle escape sequences or end a bracketed paste early; bounded to `maxPaste`.
    static func paste(_ text: String, bracketed: Bool) -> Data {
        var data = Data()
        var previousWasCR = false
        for scalar in text.unicodeScalars {
            let value = scalar.value
            if value == 0x0A, previousWasCR { previousWasCR = false; continue }
            previousWasCR = value == 0x0D
            let piece: String
            switch value {
            case 0x0A, 0x0D: piece = "\r"
            case 0x09: piece = "\t"
            case 0x00..<0x20, 0x7F, 0x80...0x9F: continue
            default: piece = String(scalar)
            }
            let bytes = Data(piece.utf8)
            if data.count + bytes.count > maxPaste { break }
            data.append(bytes)
        }
        guard bracketed else { return data }
        return Data("\u{1B}[200~".utf8) + data + Data("\u{1B}[201~".utf8)
    }
}

/// The VM's serial console (S07, S11): the guest's text on the dark console, keyboard input to
/// the guest. ⌘-shortcuts stay with the app, except ⌘V (paste to the guest) and ⌘C (copy the
/// selection).
struct TerminalView: NSViewRepresentable {
    let buffer: TerminalBuffer
    /// False while the VM is not running (paused, stopping): keys are not sent.
    let acceptsInput: Bool
    let onInput: (Data) -> Void
    let onResize: (_ columns: Int, _ rows: Int) -> Void

    func makeNSView(context: Context) -> TerminalNSView {
        let view = TerminalNSView()
        update(view)
        return view
    }

    func updateNSView(_ view: TerminalNSView, context: Context) {
        update(view)
    }

    private func update(_ view: TerminalNSView) {
        view.onInput = onInput
        view.onResize = onResize
        view.acceptsInput = acceptsInput
        view.show(buffer)
    }
}

/// The console's view. Keys: the control keys (`TerminalInput.directBytes`) are sent as they are;
/// text goes through the input system (`NSTextInputClient`), so dead keys (⌥E then E → é) and
/// input methods compose before anything reaches the guest. The composition in progress (marked
/// text) is drawn underlined at the cursor and never sent. Mouse drag selects cells (screen and
/// scrollback); ⌘C copies them.
final class TerminalNSView: NSView, @preconcurrency NSTextInputClient {
    private(set) var buffer = TerminalBuffer() {
        didSet {
            scrollOffset = min(scrollOffset, buffer.scrollbackCount)
            needsDisplay = true
        }
    }
    var acceptsInput = true
    var onInput: (Data) -> Void = { _ in }
    var onResize: (Int, Int) -> Void = { _, _ in }
    /// The pasteboard of ⌘C and ⌘V (a private one in the tests).
    var pasteboard = NSPasteboard.general

    /// Lines scrolled back into the scrollback (0: the live screen).
    private var scrollOffset = 0 {
        didSet { if scrollOffset != oldValue { needsDisplay = true } }
    }
    private var scrollRemainder: CGFloat = 0
    private var reportedSize: (columns: Int, rows: Int)?
    private var keyObserver: (any NSObjectProtocol)?

    /// The selected cells, from the anchor (mouse down) to the head (drag), rows in
    /// `stableLine` numbers so the selection stays on its text while output scrolls.
    private var selection: (anchor: TerminalBuffer.Position, head: TerminalBuffer.Position)? {
        didSet { needsDisplay = true }
    }
    /// The anchor of a mouse press not yet dragged.
    private var pressAnchor: TerminalBuffer.Position?
    /// The input system's composition in progress (a dead key's accent, IME text): shown, not sent.
    private var markedText = ""

    private let font = NSFont.monospacedSystemFont(ofSize: Theme.TypeSize.body, weight: .regular)
    private lazy var cellWidth: CGFloat = ("M" as NSString).size(withAttributes: [.font: font]).width
    private let lineHeight = Theme.Layout.consoleLineHeight
    private let inset = Theme.Space.xl

    override init(frame: NSRect) {
        super.init(frame: frame)
        // The console is dark in both modes: status colours resolve to their dark variants.
        appearance = NSAppearance(named: .darkAqua)
        // Since macOS 14 views do not clip by default: never paint over the toolbar.
        clipsToBounds = true
        setAccessibilityElement(true)
        setAccessibilityRole(.textArea)
        setAccessibilityIdentifier("vm-terminal")
        setAccessibilityLabel(String(localized: "VM console"))
    }

    required init?(coder: NSCoder) { nil }

    isolated deinit {
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }

    override func accessibilityValue() -> Any? { buffer.text }

    /// Takes `buffer` when its generation differs from the one shown (a new chunk of output, a
    /// resize, a new session): never a comparison of the grids. True when it was taken.
    @discardableResult
    func show(_ buffer: TerminalBuffer) -> Bool {
        guard buffer.generation != self.buffer.generation else { return false }
        if buffer.origin != self.buffer.origin || buffer.eraseCount != self.buffer.eraseCount {
            // Another session's buffer, or the guest wiped the text: the selection is stale.
            selection = nil
            pressAnchor = nil
        }
        self.buffer = buffer
        return true
    }

    // MARK: Focus

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
        keyObserver = nil
        guard let window else { return }
        takeFocus()
        keyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.takeFocus() }
        }
    }

    /// The console takes the keyboard when the window is key, unless another control has it.
    private func takeFocus() {
        guard let window else { return }
        let current = window.firstResponder
        if current == nil || current === window || current === self { window.makeFirstResponder(self) }
    }

    override func becomeFirstResponder() -> Bool {
        needsDisplay = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        needsDisplay = true
        return true
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers.contains(.command) {
            super.keyDown(with: event)
            return
        }
        // While composing, every key belongs to the input system (Return commits, Escape cancels).
        if !hasMarkedText(), let bytes = TerminalInput.directBytes(
            characters: event.characters, charactersIgnoringModifiers: event.charactersIgnoringModifiers,
            specialKey: event.specialKey, keyCode: event.keyCode, modifiers: event.modifierFlags) {
            send(bytes)
            return
        }
        if !hasMarkedText(), event.specialKey != nil {
            return  // an unmapped function key: nothing for the guest
        }
        interpretKeyEvents([event])
    }

    /// Commands of the input system for keys it does not insert. They come only through
    /// `interpretKeyEvents`, i.e. during a composition: ⌥E then Return commits "´" (`insertText`)
    /// and then asks for insertNewline:. The key's bytes follow, as `directBytes` would send them.
    /// Other commands do nothing (and do not beep).
    override func doCommand(by selector: Selector) {
        if let bytes = Self.commandBytes[NSStringFromSelector(selector)] { send(Data(bytes.utf8)) }
    }

    private static let commandBytes: [String: String] = {
        var map = [
            "insertNewline:": "\r", "insertLineBreak:": "\r", "insertNewlineIgnoringFieldEditor:": "\r",
            "insertTab:": "\t", "insertTabIgnoringFieldEditor:": "\t", "insertBacktab:": "\u{1B}[Z",
            "deleteBackward:": "\u{7F}", "deleteForward:": "\u{1B}[3~", "cancelOperation:": "\u{1B}",
            "moveToBeginningOfLine:": "\u{1B}[H", "moveToEndOfLine:": "\u{1B}[F",
            "scrollPageUp:": "\u{1B}[5~", "scrollPageDown:": "\u{1B}[6~",
            "pageUp:": "\u{1B}[5~", "pageDown:": "\u{1B}[6~",
        ]
        for (direction, bytes) in [("Up", "\u{1B}[A"), ("Down", "\u{1B}[B"), ("Right", "\u{1B}[C"), ("Left", "\u{1B}[D")] {
            map["move\(direction):"] = bytes
            map["move\(direction)AndModifySelection:"] = bytes
        }
        return map
    }()

    private func send(_ bytes: Data) {
        guard acceptsInput else { return }
        scrollOffset = 0
        onInput(bytes)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if window?.firstResponder === self, modifiers == .command {
            switch event.charactersIgnoringModifiers {
            case "v":
                paste(nil)
                return true
            case "c":
                copy(nil)
                return true
            default:
                break
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    @objc func paste(_ sender: Any?) {
        guard acceptsInput, let text = pasteboard.string(forType: .string), !text.isEmpty else { return }
        scrollOffset = 0
        onInput(TerminalInput.paste(text, bracketed: buffer.bracketedPaste))
    }

    // MARK: NSTextInputClient

    private static let notFound = NSRange(location: NSNotFound, length: 0)

    /// The input system's text (a key, a composed accent, an IME commit): sent as UTF-8.
    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        markedText = ""
        needsDisplay = true
        if let bytes = TerminalInput.text(text) { send(bytes) }
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        markedText = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        needsDisplay = true
    }

    func unmarkText() {
        markedText = ""
        needsDisplay = true
    }

    func hasMarkedText() -> Bool { !markedText.isEmpty }

    func markedRange() -> NSRange {
        hasMarkedText() ? NSRange(location: 0, length: (markedText as NSString).length) : Self.notFound
    }

    /// The terminal has no editable text of its own: the insertion point is the end of the
    /// composition.
    func selectedRange() -> NSRange {
        NSRange(location: (markedText as NSString).length, length: 0)
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        nil
    }

    func characterIndex(for point: NSPoint) -> Int { NSNotFound }

    /// The cursor's cell on screen: where the input method shows its candidates.
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        let cursor = buffer.cursor
        let local = NSRect(x: inset + CGFloat(cursor.column) * cellWidth,
                           y: inset + CGFloat(cursor.row) * lineHeight, width: cellWidth, height: lineHeight)
        guard let window else { return .zero }
        return window.convertToScreen(convert(local, to: nil))
    }

    // MARK: Selection

    /// The centre of a screen cell, in view coordinates.
    func cellCenter(row: Int, column: Int) -> NSPoint {
        NSPoint(x: inset + (CGFloat(column) + 0.5) * cellWidth, y: inset + (CGFloat(row) + 0.5) * lineHeight)
    }

    /// The cell under `point` (view coordinates), as a line of scrollback + screen; clamped to
    /// the visible grid.
    private func cell(at point: NSPoint) -> TerminalBuffer.Position {
        let row = min(max(Int(floor((point.y - inset) / lineHeight)), 0), buffer.rows - 1)
        let column = min(max(Int(floor((point.x - inset) / cellWidth)), 0), buffer.columns - 1)
        return TerminalBuffer.Position(row: topLine + row, column: column)
    }

    /// The first visible line, as a line of scrollback + screen.
    private var topLine: Int { buffer.scrollbackCount - scrollOffset }

    private func stable(_ position: TerminalBuffer.Position) -> TerminalBuffer.Position {
        TerminalBuffer.Position(row: position.row + buffer.droppedLineCount, column: position.column)
    }

    private func current(_ position: TerminalBuffer.Position) -> TerminalBuffer.Position {
        TerminalBuffer.Position(row: position.row - buffer.droppedLineCount, column: position.column)
    }

    /// Selects from `start` to `end` (both included), rows as lines of scrollback + screen.
    func selectCells(from start: TerminalBuffer.Position, to end: TerminalBuffer.Position) {
        selection = (stable(start), stable(end))
    }

    /// The selection's ends in reading order, as lines of scrollback + screen; nil when nothing
    /// is selected or the selected lines left the scrollback.
    private var orderedSelection: (start: TerminalBuffer.Position, end: TerminalBuffer.Position)? {
        guard let selection else { return nil }
        var (start, end) = (current(selection.anchor), current(selection.head))
        if (end.row, end.column) < (start.row, start.column) { swap(&start, &end) }
        guard end.row >= 0 else { return nil }
        if start.row < 0 { start = TerminalBuffer.Position(row: 0, column: 0) }
        return (start, end)
    }

    /// The selected text, trailing spaces trimmed per line; nil without a selection.
    var selectedText: String? {
        guard let range = orderedSelection else { return nil }
        return buffer.text(from: range.start, to: range.end)
    }

    /// ⌘C: the selected text to the pasteboard. Without a selection, nothing happens.
    @objc func copy(_ sender: Any?) {
        guard let text = selectedText, !text.isEmpty else { return }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        selection = nil
        pressAnchor = stable(cell(at: convert(event.locationInWindow, from: nil)))
    }

    override func mouseDragged(with event: NSEvent) {
        guard let pressAnchor else { return }
        selection = (pressAnchor, stable(cell(at: convert(event.locationInWindow, from: nil))))
    }

    override func mouseUp(with event: NSEvent) {
        pressAnchor = nil
    }

    // MARK: Scrollback

    override func scrollWheel(with event: NSEvent) {
        let lines = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / lineHeight : event.scrollingDeltaY
        scrollRemainder += lines
        let whole = Int(scrollRemainder.rounded(.towardZero))
        guard whole != 0 else { return }
        scrollRemainder -= CGFloat(whole)
        scrollOffset = min(max(scrollOffset + whole, 0), buffer.scrollbackCount)
    }

    // MARK: Size

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // The first layout passes through an empty frame: a 1×1 grid would cut every line the guest
        // printed before the window appeared (a VM started without its window, a fast boot).
        guard newSize.width >= 2 * inset + cellWidth, newSize.height >= 2 * inset + lineHeight else { return }
        let columns = max(Int((newSize.width - 2 * inset) / cellWidth), 1)
        let rows = max(Int((newSize.height - 2 * inset) / lineHeight), 1)
        if reportedSize?.columns != columns || reportedSize?.rows != rows {
            reportedSize = (columns, rows)
            // Not during SwiftUI's own update pass.
            DispatchQueue.main.async { [onResize] in onResize(columns, rows) }
        }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor(Theme.Console.background).setFill()
        dirtyRect.intersection(bounds).fill()

        let textHeight = font.ascender - font.descender
        let textTop = (lineHeight - textHeight) / 2
        let top = topLine
        let selected = orderedSelection
        for row in 0..<buffer.rows {
            let y = inset + CGFloat(row) * lineHeight
            guard y < bounds.height else { break }
            let line = top + row
            if let selected { drawSelection(selected, line: line, y: y) }
            attributed(buffer.cells(line: line)).draw(at: NSPoint(x: inset, y: y + textTop))
        }

        let cursor = buffer.cursor
        guard scrollOffset == 0, cursor.row < buffer.rows else { return }
        let cursorX = inset + CGFloat(cursor.column) * cellWidth
        let cursorY = inset + CGFloat(cursor.row) * lineHeight
        if hasMarkedText() {
            // The composition in progress, underlined at the cursor.
            NSColor(Theme.Console.background).setFill()
            let marked = NSAttributedString(string: markedText, attributes: [
                .font: font, .foregroundColor: NSColor(Theme.Console.foreground),
                .underlineStyle: NSUnderlineStyle.single.rawValue,
            ])
            NSRect(x: cursorX, y: cursorY, width: marked.size().width, height: lineHeight).fill()
            marked.draw(at: NSPoint(x: cursorX, y: cursorY + textTop))
        } else if buffer.cursorVisible {
            let color = NSColor(Theme.Console.foreground)
            (window?.firstResponder === self
                ? color : color.withAlphaComponent(Theme.Layout.consoleCursorInactiveOpacity)).setFill()
            NSRect(x: cursorX,
                   y: cursorY + textTop + font.ascender + Theme.Layout.consoleCursorBaselineGap,
                   width: cellWidth, height: Theme.Layout.consoleCursorHeight).fill()
        }
    }

    /// The selected part of one line, behind its text.
    private func drawSelection(_ range: (start: TerminalBuffer.Position, end: TerminalBuffer.Position),
                               line: Int, y: CGFloat) {
        guard line >= range.start.row, line <= range.end.row else { return }
        let first = line == range.start.row ? range.start.column : 0
        let last = line == range.end.row ? min(range.end.column, buffer.columns - 1) : buffer.columns - 1
        guard first <= last else { return }
        NSColor(Theme.Color.accent).withAlphaComponent(Theme.Layout.consoleSelectionOpacity).setFill()
        NSRect(x: inset + CGFloat(first) * cellWidth, y: y,
               width: CGFloat(last - first + 1) * cellWidth, height: lineHeight).fill()
    }

    /// One line, in runs of the same colour.
    private func attributed(_ cells: [TerminalBuffer.Cell]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        var index = cells.startIndex
        while index < cells.endIndex {
            let color = cells[index].color
            var scalars = String.UnicodeScalarView()
            while index < cells.endIndex, cells[index].color == color {
                scalars.append(cells[index].scalar)
                index += 1
            }
            result.append(NSAttributedString(string: String(scalars),
                                             attributes: [.font: font, .foregroundColor: Self.nsColor(color)]))
        }
        return result
    }

    private static func nsColor(_ color: TerminalBuffer.Color) -> NSColor {
        switch color {
        case .standard: NSColor(Theme.Console.foreground)
        case .red: NSColor(Theme.Color.statusError)
        case .green: NSColor(Theme.Color.statusRunning)
        case .yellow: NSColor(Theme.Color.statusPaused)
        }
    }
}
