// SPDX-License-Identifier: Apache-2.0
import Foundation
import Synchronization

/// A pure model of the VM's serial console: a fixed grid of cells with a cursor, a bounded
/// scrollback, and a parser for the small VT/xterm subset that getty, login, bash and systemd use.
///
/// Guest output is untrusted. The parser:
/// - never acts on anything outside this value (no clipboard, title, hyperlink, bell: OSC, DCS,
///   APC, PM and SOS strings are consumed up to BEL/ST/CAN/SUB and dropped, whatever their length);
/// - answers only two queries (ruling R-M2-35): DSR 5n ("ESC[0n") and DSR 6n (the cursor
///   position), queued in `takeReplies()` (at most `maxPendingReplies`); every other query
///   (DECXCPR, DA, OSC and window reports…) stays unanswered;
/// - keeps memory bounded: `scrollbackLimit` lines, a fixed grid, at most `maxPendingEscape`
///   bytes of a CSI sequence (a longer one is abandoned and parsing goes on as text), at most
///   3 pending bytes of a UTF-8 sequence;
/// - accepts any byte sequence (invalid UTF-8 becomes U+FFFD; numbers are clamped).
///
/// Each Unicode scalar takes one cell (no wide or combining characters). Format characters
/// (category Cf: bidi overrides and isolates, zero-width joiners, BOM…) are shown as U+FFFD, so
/// the guest cannot make the console show text in another order than it was sent, or hide
/// characters.
///
/// `generation` changes with every mutation: the view compares it, never the whole grid.
struct TerminalBuffer {
    struct Position: Equatable, Sendable {
        var row: Int
        var column: Int
    }

    /// Foreground colours worth keeping from SGR (systemd's "[  OK  ]", "FAILED", warnings).
    /// The view maps them to Theme status colours; everything else is drawn in the console colour.
    enum Color: UInt8, Sendable {
        case standard, red, green, yellow
    }

    struct Cell: Equatable, Sendable {
        var scalar: Unicode.Scalar
        var color: Color

        static let blank = Cell(scalar: " ", color: .standard)
    }

    /// Replies (DSR 5n/6n only) waiting to be sent; more are dropped, so a flood of queries
    /// cannot amplify into the guest.
    static let maxPendingReplies = 16
    static let scrollbackLimit = 5_000
    static let maxPendingEscape = 256
    static let defaultColumns = 100
    static let defaultRows = 32
    /// Upper bound of a grid side, whatever the view asks for.
    static let maxSide = 1_000
    private static let maxParameter = 9_999
    private static let maxParameters = 16

    /// A value no other buffer has had, renewed by every mutation: the view redraws when it
    /// changes (also for a new session's buffer with the same text).
    private(set) var generation: UInt64
    /// Lines dropped from the front of the scrollback so far (its limit, ED 3): with it a line keeps
    /// one number while the screen scrolls (`stableLine`), which the view's selection uses.
    private(set) var droppedLineCount = 0
    /// Which buffer this is: kept by RIS, different for every new buffer (another session).
    private(set) var origin: UInt64
    /// Bumped when the guest wipes text (ED 2/3, RIS): a selection on it no longer means anything.
    private(set) var eraseCount = 0

    /// Process-wide source of `generation` values.
    private static let generations = Atomic<UInt64>(0)

    private static func nextGeneration() -> UInt64 {
        generations.add(1, ordering: .relaxed).newValue
    }

    private mutating func bump() {
        generation = Self.nextGeneration()
    }

    private(set) var columns: Int
    private(set) var rows: Int
    /// The visible grid, `rows` lines of `columns` cells.
    private var screen: [[Cell]]
    /// A blank grid of the current size, shared copy-on-write: ED 2/3 assigns it in O(1), so a
    /// guest's 4-byte erase never costs rows × columns cells on the main actor.
    private var blankScreen: [[Cell]]
    /// Lines scrolled off the top, oldest first: a ring of at most `scrollbackLimit` lines.
    private var scrollback: [[Cell]] = []
    private var scrollbackStart = 0

    private(set) var cursor = Position(row: 0, column: 0)
    private var savedCursor = Position(row: 0, column: 0)
    /// The cursor sits on the last column after printing there; the next character wraps first.
    private var pendingWrap = false
    private var color = Color.standard
    private(set) var cursorVisible = true
    /// DECSET 2004: the guest wants pastes wrapped in ESC[200~ … ESC[201~.
    private(set) var bracketedPaste = false
    private var replies: [Data] = []

    // MARK: Parser state

    private enum State: Equatable {
        case ground
        case escape
        /// ESC ( ) * + and similar: one more byte (the character set), ignored.
        case escapeIntermediate
        case csi
        /// OSC, DCS, SOS, PM, APC: consumed up to BEL or ST, never stored.
        case string
        /// ESC seen inside a string: `\` ends it.
        case stringEscape
    }

    private var state = State.ground
    /// Parameter and intermediate bytes of the CSI sequence being read.
    private var csiBytes: [UInt8] = []
    /// Bytes of an incomplete UTF-8 sequence, and how many it needs in all.
    private var utf8Bytes: [UInt8] = []
    private var utf8Needed = 0

    /// Bytes held for an unfinished escape sequence: never more than `maxPendingEscape`.
    var pendingEscapeCount: Int {
        switch state {
        case .ground: 0
        case .escape, .escapeIntermediate: 1
        case .csi: 2 + csiBytes.count
        case .string, .stringEscape: 2  // skipped, never stored
        }
    }

    init(columns: Int = TerminalBuffer.defaultColumns, rows: Int = TerminalBuffer.defaultRows) {
        generation = Self.nextGeneration()
        origin = generation
        self.columns = Self.clamp(columns)
        self.rows = Self.clamp(rows)
        blankScreen = Array(repeating: Array(repeating: .blank, count: self.columns), count: self.rows)
        screen = blankScreen
    }

    private static func clamp(_ side: Int) -> Int { min(max(side, 1), maxSide) }

    // MARK: - Reading the grid

    /// The visible lines, trailing blanks removed.
    var lines: [String] { screen.map(Self.string) }

    /// The visible text for accessibility: lines joined by "\n", trailing blank lines removed.
    var text: String {
        var lines = self.lines
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    var scrollbackCount: Int { scrollback.count }

    /// Line `index` of the scrollback, 0 being the oldest kept.
    func scrollbackLine(_ index: Int) -> String { Self.string(scrollbackCells(index)) }

    func scrollbackCells(_ index: Int) -> [Cell] {
        scrollback[(scrollbackStart + index) % scrollback.count]
    }

    func screenCells(_ row: Int) -> [Cell] { screen[row] }

    func color(row: Int, column: Int) -> Color { screen[row][column].color }

    /// Scrollback lines followed by the screen rows.
    var lineCount: Int { scrollback.count + rows }

    /// Line `index` of scrollback + screen (0: the oldest scrollback line).
    func cells(line index: Int) -> [Cell] {
        index < scrollback.count ? scrollbackCells(index) : screen[index - scrollback.count]
    }

    /// The text from `start` to `end` (either order, both included), where a position's row is a
    /// line of scrollback + screen. Each line loses its trailing spaces; lines are joined by "\n".
    /// Positions outside the buffer are clamped.
    func text(from start: Position, to end: Position) -> String {
        guard lineCount > 0 else { return "" }
        var (first, last) = (start, end)
        if (last.row, last.column) < (first.row, first.column) { swap(&first, &last) }
        let maxLine = lineCount - 1
        first = Position(row: min(max(first.row, 0), maxLine), column: max(first.column, 0))
        last = Position(row: min(max(last.row, 0), maxLine), column: min(max(last.column, 0), Self.maxSide))
        var lines: [String] = []
        for line in first.row...last.row {
            let cells = self.cells(line: line)
            let from = line == first.row ? min(first.column, cells.count) : 0
            let to = line == last.row ? min(last.column + 1, cells.count) : cells.count
            lines.append(from < to ? Self.string(Array(cells[from..<to])) : "")
        }
        return lines.joined(separator: "\n")
    }
    private static func string(_ cells: [Cell]) -> String {
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: cells.map(\.scalar))
        var text = String(scalars)
        while text.last == " " { text.removeLast() }
        return text
    }

    // MARK: - Resizing

    /// Keeps the bottom of the screen (and so the cursor) visible: rows that no longer fit at the
    /// top go to the scrollback; lines are cut or padded to the new width.
    mutating func resize(columns newColumns: Int, rows newRows: Int) {
        let newColumns = Self.clamp(newColumns)
        let newRows = Self.clamp(newRows)
        guard newColumns != columns || newRows != rows else { return }
        bump()
        if cursor.row >= newRows {
            let excess = cursor.row - newRows + 1
            for _ in 0..<excess { pushScrollback(screen.removeFirst()) }
            cursor.row -= excess
        }
        if screen.count > newRows { screen.removeLast(screen.count - newRows) }
        for index in screen.indices {
            if newColumns < columns {
                screen[index].removeLast(columns - newColumns)
            } else if newColumns > columns {
                screen[index].append(contentsOf: Array(repeating: .blank, count: newColumns - columns))
            }
        }
        while screen.count < newRows { screen.append(Array(repeating: .blank, count: newColumns)) }
        columns = newColumns
        rows = newRows
        blankScreen = Array(repeating: Array(repeating: .blank, count: columns), count: rows)
        cursor.column = min(cursor.column, columns - 1)
        savedCursor = Position(row: min(savedCursor.row, rows - 1), column: min(savedCursor.column, columns - 1))
        pendingWrap = false
    }

    // MARK: - Feeding bytes

    mutating func feed(_ data: Data) {
        guard !data.isEmpty else { return }
        bump()
        data.withUnsafeBytes { raw in
            for byte in raw { feed(byte: byte) }
        }
    }

    private mutating func feed(byte: UInt8) {
        switch state {
        case .ground: ground(byte)
        case .escape: escape(byte)
        case .escapeIntermediate: state = .ground
        case .csi: csi(byte)
        case .string: string(byte)
        case .stringEscape:
            // ESC \ (ST) ends the string; ESC followed by anything else ends it too and starts
            // a new escape sequence.
            state = .ground
            if byte != 0x5C { escape(byte) }
        }
    }

    private mutating func ground(_ byte: UInt8) {
        if !utf8Bytes.isEmpty {
            if byte & 0xC0 == 0x80 {
                utf8Bytes.append(byte)
                if utf8Bytes.count == utf8Needed { finishUTF8() }
                return
            }
            // The sequence was cut short: one replacement character, then this byte on its own.
            utf8Bytes = []
            put(Unicode.Scalar(0xFFFD)!)
        }
        switch byte {
        case 0x1B: state = .escape
        case 0x0D: carriageReturn()
        case 0x0A, 0x0B, 0x0C: lineFeed()
        case 0x08: backspace()
        case 0x09: tab()
        case 0x00..<0x20, 0x7F: break  // BEL and the other controls: ignored
        case 0x20..<0x7F: put(Unicode.Scalar(byte))
        case 0xC2...0xDF: startUTF8(byte, needs: 2)
        case 0xE0...0xEF: startUTF8(byte, needs: 3)
        case 0xF0...0xF4: startUTF8(byte, needs: 4)
        default: put(Unicode.Scalar(0xFFFD)!)  // stray continuation or invalid lead byte
        }
    }

    private mutating func startUTF8(_ byte: UInt8, needs: Int) {
        utf8Bytes = [byte]
        utf8Needed = needs
    }

    private mutating func finishUTF8() {
        var value: UInt32
        switch utf8Needed {
        case 2: value = UInt32(utf8Bytes[0] & 0x1F)
        case 3: value = UInt32(utf8Bytes[0] & 0x0F)
        default: value = UInt32(utf8Bytes[0] & 0x07)
        }
        for byte in utf8Bytes.dropFirst() { value = value << 6 | UInt32(byte & 0x3F) }
        let minimum: UInt32 = utf8Needed == 2 ? 0x80 : utf8Needed == 3 ? 0x800 : 0x10000
        utf8Bytes = []
        // Overlong forms, surrogates and values past U+10FFFF are invalid.
        if value >= minimum, let scalar = Unicode.Scalar(value) {
            // C1 controls (U+0080–U+009F) are not printed.
            if !(0x80...0x9F).contains(value) { put(scalar) }
        } else {
            put(Unicode.Scalar(0xFFFD)!)
        }
    }

    private mutating func escape(_ byte: UInt8) {
        state = .ground
        switch byte {
        case 0x5B:  // [
            state = .csi
            csiBytes = []
        case 0x5D, 0x50, 0x58, 0x5E, 0x5F:  // ] P X ^ _
            state = .string
        case 0x28...0x2F: state = .escapeIntermediate  // ( ) * + - . /: character sets
        case 0x37: savedCursor = cursor  // 7
        case 0x38:  // 8
            cursor = savedCursor
            pendingWrap = false
        case 0x44: index()  // D
        case 0x45:  // E
            carriageReturn()
            lineFeed()
        case 0x4D: reverseIndex()  // M
        case 0x63: reset()  // c
        case 0x1B: state = .escape
        default: break  // anything else (keypad modes, …): dropped
        }
    }

    private mutating func string(_ byte: UInt8) {
        switch byte {
        case 0x07: state = .ground  // BEL ends an OSC
        case 0x1B: state = .stringEscape
        case 0x18, 0x1A: state = .ground  // CAN, SUB abort
        default: break  // skipped, however long: nothing of it reaches the screen
        }
    }

    private mutating func csi(_ byte: UInt8) {
        switch byte {
        case 0x40...0x7E:
            state = .ground
            dispatchCSI(final: byte)
        case 0x20...0x3F:
            csiBytes.append(byte)
            if pendingEscapeCount > Self.maxPendingEscape {
                state = .ground  // runaway: dropped
                csiBytes = []
            }
        case 0x1B: state = .escape
        case 0x18, 0x1A: state = .ground
        case 0x0D: carriageReturn()  // C0 controls act even inside a sequence
        case 0x0A, 0x0B, 0x0C: lineFeed()
        case 0x08: backspace()
        default: break
        }
    }

    // MARK: - CSI

    private mutating func dispatchCSI(final: UInt8) {
        let bytes = csiBytes
        csiBytes = []
        var isPrivate = false
        var body = bytes[...]
        if let first = body.first, (0x3C...0x3F).contains(first) {  // < = > ?
            isPrivate = first == 0x3F
            if first != 0x3F { return }  // < = > queries and settings: never answered
            body = body.dropFirst()
        }
        // Intermediate bytes, or a marker in the middle: not a sequence of the subset.
        guard body.allSatisfy({ (0x30...0x3B).contains($0) }) else { return }
        let params = Self.parameters(body)

        if isPrivate {
            guard final == 0x68 || final == 0x6C else { return }  // h l
            let on = final == 0x68
            for mode in params {
                switch mode {
                case 25: cursorVisible = on
                case 2004: bracketedPaste = on
                default: break  // alternate screen, autowrap, mouse…: ignored
                }
            }
            return
        }

        let first = params.first ?? 0
        let count = max(first, 1)
        switch final {
        case 0x41: moveCursor(row: cursor.row - count, column: cursor.column)  // A
        case 0x42: moveCursor(row: cursor.row + count, column: cursor.column)  // B
        case 0x43: moveCursor(row: cursor.row, column: cursor.column + count)  // C
        case 0x44: moveCursor(row: cursor.row, column: cursor.column - count)  // D
        case 0x45: moveCursor(row: cursor.row + count, column: 0)  // E
        case 0x46: moveCursor(row: cursor.row - count, column: 0)  // F
        case 0x47, 0x60: moveCursor(row: cursor.row, column: count - 1)  // G `
        case 0x64: moveCursor(row: count - 1, column: cursor.column)  // d
        case 0x48, 0x66:  // H f
            let column = params.count > 1 ? max(params[1], 1) : 1
            moveCursor(row: count - 1, column: column - 1)
        case 0x4A: eraseInDisplay(first)  // J
        case 0x4B: eraseInLine(first)  // K
        case 0x40: insertCharacters(count)  // @
        case 0x50: deleteCharacters(count)  // P
        case 0x58: eraseCharacters(count)  // X
        case 0x4C: insertLines(count)  // L
        case 0x4D: deleteLines(count)  // M
        case 0x6D: selectGraphicRendition(params)  // m
        case 0x6E: deviceStatusReport(first)  // n
        case 0x73: savedCursor = cursor  // s
        case 0x75:  // u
            cursor = savedCursor
            pendingWrap = false
        default: break  // device queries (c, n) are never answered; the rest is ignored
        }
    }

    /// Pending replies for the guest, oldest first; the queue is emptied.
    mutating func takeReplies() -> [Data] {
        guard !replies.isEmpty else { return [] }
        bump()
        defer { replies = [] }
        return replies
    }

    /// DSR 5 (status: "ok") and DSR 6 (cursor position, 1-based, always inside the grid).
    private mutating func deviceStatusReport(_ kind: Int) {
        let reply: String
        switch kind {
        case 5: reply = "\u{1B}[0n"
        case 6: reply = "\u{1B}[\(cursor.row + 1);\(cursor.column + 1)R"
        default: return
        }
        guard replies.count < Self.maxPendingReplies else { return }
        replies.append(Data(reply.utf8))
    }

    /// "1;;25" → [1, 0, 25]; each value clamped to `maxParameter`, at most `maxParameters`.
    private static func parameters(_ bytes: ArraySlice<UInt8>) -> [Int] {
        guard !bytes.isEmpty else { return [] }
        var result: [Int] = []
        var current = 0
        for byte in bytes {
            if byte == 0x3B || byte == 0x3A {
                if result.count < maxParameters { result.append(current) }
                current = 0
            } else {
                current = min(current * 10 + Int(byte - 0x30), maxParameter)
            }
        }
        if result.count < maxParameters { result.append(current) }
        return result
    }

    private mutating func selectGraphicRendition(_ params: [Int]) {
        let params = params.isEmpty ? [0] : params
        var index = 0
        while index < params.count {
            switch params[index] {
            case 0, 39: color = .standard
            case 31, 91: color = .red
            case 32, 92: color = .green
            case 33, 93: color = .yellow
            case 30, 34...37, 90, 94...97: color = .standard
            case 38, 48:
                // Extended colours (5;n or 2;r;g;b): skipped; a foreground one draws as standard.
                if params[index] == 38 { color = .standard }
                if index + 1 < params.count {
                    switch params[index + 1] {
                    case 5: index += 2
                    case 2: index += 4
                    default: index += 1
                    }
                }
            default: break  // bold, underline, background…: ignored
            }
            index += 1
        }
    }

    // MARK: - Editing the grid

    private mutating func put(_ scalar: Unicode.Scalar) {
        // Format characters (Cf) are invisible and can reorder text: shown as U+FFFD.
        let scalar = scalar.properties.generalCategory == .format ? Unicode.Scalar(0xFFFD)! : scalar
        if pendingWrap {
            pendingWrap = false
            cursor.column = 0
            lineFeed()
        }
        screen[cursor.row][cursor.column] = Cell(scalar: scalar, color: color)
        if cursor.column == columns - 1 {
            pendingWrap = true
        } else {
            cursor.column += 1
        }
    }

    private mutating func carriageReturn() {
        cursor.column = 0
        pendingWrap = false
    }

    /// LF moves down (the guest's tty adds the CR); at the bottom the screen scrolls.
    private mutating func lineFeed() {
        pendingWrap = false
        index()
    }

    private mutating func index() {
        if cursor.row == rows - 1 {
            pushScrollback(screen.removeFirst())
            screen.append(Array(repeating: .blank, count: columns))
        } else {
            cursor.row += 1
        }
    }

    private mutating func reverseIndex() {
        pendingWrap = false
        if cursor.row == 0 {
            screen.removeLast()
            screen.insert(Array(repeating: .blank, count: columns), at: 0)
        } else {
            cursor.row -= 1
        }
    }

    private mutating func backspace() {
        pendingWrap = false
        cursor.column = max(cursor.column - 1, 0)
    }

    private mutating func tab() {
        pendingWrap = false
        cursor.column = min((cursor.column / 8 + 1) * 8, columns - 1)
    }

    private mutating func moveCursor(row: Int, column: Int) {
        pendingWrap = false
        cursor = Position(row: min(max(row, 0), rows - 1), column: min(max(column, 0), columns - 1))
    }

    private mutating func eraseInDisplay(_ mode: Int) {
        switch mode {
        case 0:
            eraseInLine(0)
            for row in (cursor.row + 1)..<rows { clear(row: row) }
        case 1:
            for row in 0..<cursor.row { clear(row: row) }
            eraseInLine(1)
        case 2, 3:
            eraseCount += 1
            screen = blankScreen
            if mode == 3 {
                droppedLineCount += scrollback.count
                scrollback = []
                scrollbackStart = 0
            }
        default: break
        }
    }

    private mutating func eraseInLine(_ mode: Int) {
        let range: Range<Int>
        switch mode {
        case 0: range = cursor.column..<columns
        case 1: range = 0..<(cursor.column + 1)
        case 2: range = 0..<columns
        default: return
        }
        for column in range { screen[cursor.row][column] = .blank }
    }

    private mutating func clear(row: Int) {
        screen[row] = Array(repeating: .blank, count: columns)
    }

    private mutating func insertCharacters(_ count: Int) {
        let count = min(count, columns - cursor.column)
        screen[cursor.row].insert(contentsOf: Array(repeating: .blank, count: count), at: cursor.column)
        screen[cursor.row].removeLast(count)
    }

    private mutating func deleteCharacters(_ count: Int) {
        let count = min(count, columns - cursor.column)
        screen[cursor.row].removeSubrange(cursor.column..<(cursor.column + count))
        screen[cursor.row].append(contentsOf: Array(repeating: .blank, count: count))
    }

    private mutating func eraseCharacters(_ count: Int) {
        let end = min(cursor.column + count, columns)
        for column in cursor.column..<end { screen[cursor.row][column] = .blank }
    }

    private mutating func insertLines(_ count: Int) {
        let count = min(count, rows - cursor.row)
        screen.removeLast(count)
        screen.insert(contentsOf: Array(repeating: Array(repeating: .blank, count: columns), count: count),
                      at: cursor.row)
    }

    private mutating func deleteLines(_ count: Int) {
        let count = min(count, rows - cursor.row)
        screen.removeSubrange(cursor.row..<(cursor.row + count))
        screen.append(contentsOf: Array(repeating: Array(repeating: .blank, count: columns), count: count))
    }

    private mutating func reset() {
        self = TerminalBuffer(columns: columns, rows: rows, keeping: self)
    }

    /// RIS: a clean screen of the same size; the scrollback stays.
    private init(columns: Int, rows: Int, keeping old: TerminalBuffer) {
        self.init(columns: columns, rows: rows)
        scrollback = old.scrollback
        scrollbackStart = old.scrollbackStart
        droppedLineCount = old.droppedLineCount
        origin = old.origin
        eraseCount = old.eraseCount + 1
    }

    private mutating func pushScrollback(_ line: [Cell]) {
        if scrollback.count < Self.scrollbackLimit {
            scrollback.append(line)
        } else {
            scrollback[scrollbackStart] = line
            scrollbackStart = (scrollbackStart + 1) % Self.scrollbackLimit
            droppedLineCount += 1
        }
    }
}
