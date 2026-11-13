// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing

@testable import Nido

private extension TerminalBuffer {
    mutating func feed(_ text: String) { feed(Data(text.utf8)) }
    /// The screen without trailing blank lines.
    var trimmedLines: [String] {
        var lines = self.lines
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines
    }
}

private let esc = "\u{1B}"

struct TerminalBufferTests {
    /// A guest's 4-byte ED 2 must not allocate a fresh row for every row (audit NV-6): a chunk of
    /// erase-display sequences costs about what plain text of the same size costs.
    @Test func eraseDisplayCostsAboutAsMuchAsText() {
        func cost(_ bytes: Data) -> Duration {
            (0..<3).map { _ in
                var buffer = TerminalBuffer(columns: 380, rows: 83)
                return ContinuousClock().measure { buffer.feed(bytes) }
            }.min()!
        }
        let erase = Data(String(repeating: "\(esc)[2J", count: 8_192).utf8)
        let text = Data(repeating: 0x61, count: erase.count)
        let ratio = cost(erase) / cost(text)
        #expect(ratio < 4, "ED 2 took \(ratio)× plain text")
    }

    @Test func defaultSize() {
        let buffer = TerminalBuffer()
        #expect(buffer.columns == 100)
        #expect(buffer.rows == 32)
        #expect(buffer.lines.count == 32)
    }

    @Test func plainTextAndCRLF() {
        var buffer = TerminalBuffer()
        buffer.feed("Debian GNU/Linux 13 debian-13 hvc0\r\n\r\ndebian-13 login: ")
        #expect(buffer.trimmedLines == ["Debian GNU/Linux 13 debian-13 hvc0", "", "debian-13 login:"])
        #expect(buffer.cursor == TerminalBuffer.Position(row: 2, column: 17))
    }

    @Test func lineFeedKeepsTheColumnAndCarriageReturnOverwrites() {
        var buffer = TerminalBuffer()
        buffer.feed("abc\ndef")
        #expect(buffer.trimmedLines == ["abc", "   def"])
        buffer.feed("\rX")
        #expect(buffer.trimmedLines == ["abc", "X  def"])
    }

    @Test func lineWrapAtColumns() {
        var buffer = TerminalBuffer(columns: 10, rows: 4)
        buffer.feed("0123456789")
        // Deferred wrap: the cursor stays on the last column until the next character.
        #expect(buffer.cursor == TerminalBuffer.Position(row: 0, column: 9))
        buffer.feed("abcde")
        #expect(buffer.trimmedLines == ["0123456789", "abcde"])
        #expect(buffer.cursor == TerminalBuffer.Position(row: 1, column: 5))
    }

    @Test func scrollingFillsTheScrollback() {
        var buffer = TerminalBuffer(columns: 20, rows: 3)
        buffer.feed("1\r\n2\r\n3\r\n4\r\n5")
        #expect(buffer.trimmedLines == ["3", "4", "5"])
        #expect(buffer.scrollbackCount == 2)
        #expect(buffer.scrollbackLine(0) == "1")
        #expect(buffer.scrollbackLine(1) == "2")
    }

    @Test func scrollbackIsCappedAt5000Lines() {
        var buffer = TerminalBuffer(columns: 20, rows: 5)
        for index in 0..<6_000 { buffer.feed("line \(index)\r\n") }
        #expect(TerminalBuffer.scrollbackLimit == 5_000)
        #expect(buffer.scrollbackCount == 5_000)
        // The oldest lines went first.
        #expect(buffer.scrollbackLine(0) == "line 996")
        #expect(buffer.scrollbackLine(4_999) == "line 5995")
        #expect(buffer.trimmedLines == ["line 5996", "line 5997", "line 5998", "line 5999"])
    }

    @Test func backspaceMovesLeftWithoutErasing() {
        var buffer = TerminalBuffer()
        buffer.feed("rooz\u{08}t")
        #expect(buffer.trimmedLines == ["root"])
        // The echo of a deleted character: BS, space, BS.
        buffer.feed("\u{08} \u{08}")
        #expect(buffer.trimmedLines == ["roo"])
        #expect(buffer.cursor.column == 3)
        // Never past the left margin.
        buffer.feed("\u{08}\u{08}\u{08}\u{08}\u{08}")
        #expect(buffer.cursor.column == 0)
    }

    @Test func tabAndBellAndOtherControls() {
        var buffer = TerminalBuffer()
        buffer.feed("a\tb\u{07}\u{00}\u{7F}c")
        #expect(buffer.trimmedLines == ["a       bc"])
    }

    @Test func csiCursorMovement() {
        var buffer = TerminalBuffer(columns: 20, rows: 5)
        buffer.feed("\(esc)[3;5HX")
        #expect(buffer.trimmedLines == ["", "", "    X"])
        buffer.feed("\(esc)[2AY\(esc)[BZ\(esc)[10DW\(esc)[3CV")
        #expect(buffer.trimmedLines == ["     Y", "W   V Z", "    X"])
        buffer.feed("\(esc)[HQ\(esc)[5;20fR\(esc)[99;99fS")
        #expect(buffer.lines[0].hasPrefix("Q"))
        #expect(buffer.lines[4] == String(repeating: " ", count: 19) + "S")
    }

    @Test func csiErase() {
        var buffer = TerminalBuffer(columns: 10, rows: 3)
        buffer.feed("aaaaaaaaaa\r\nbbbbbbbbbb\r\ncccccccccc")
        buffer.feed("\(esc)[2;5H\(esc)[K")
        #expect(buffer.trimmedLines == ["aaaaaaaaaa", "bbbb", "cccccccccc"])
        buffer.feed("\(esc)[1K")
        #expect(buffer.trimmedLines == ["aaaaaaaaaa", "", "cccccccccc"])
        buffer.feed("\(esc)[1;3H\(esc)[1J")
        #expect(buffer.trimmedLines == ["   aaaaaaa", "", "cccccccccc"])
        buffer.feed("\(esc)[3;3H\(esc)[J")
        #expect(buffer.trimmedLines == ["   aaaaaaa", "", "cc"])
        buffer.feed("\(esc)[2J")
        #expect(buffer.trimmedLines == [])
    }

    @Test func sgrIsAcceptedSafely() {
        var buffer = TerminalBuffer()
        buffer.feed("[  \(esc)[0;32mOK\(esc)[0m  ] Reached \(esc)[1;39mtarget\(esc)[0m \(esc)[38;5;196mX\(esc)[38;2;1;2;3mY\(esc)[mZ")
        buffer.feed("\(esc)[99999999999999999999;-1;;;m!")
        #expect(buffer.trimmedLines == ["[  OK  ] Reached target XYZ!"])
        #expect(buffer.color(row: 0, column: 3) == .green)
        #expect(buffer.color(row: 0, column: 0) == .standard)
        #expect(buffer.color(row: 0, column: 26) == .standard)
    }

    @Test func privateModes() {
        var buffer = TerminalBuffer()
        #expect(buffer.cursorVisible)
        buffer.feed("\(esc)[?25l")
        #expect(!buffer.cursorVisible)
        buffer.feed("\(esc)[?25h\(esc)[?2004h")
        #expect(buffer.cursorVisible)
        #expect(buffer.bracketedPaste)
        buffer.feed("\(esc)[?2004l\(esc)[?1049h\(esc)[?7l")
        #expect(!buffer.bracketedPaste)
        #expect(buffer.trimmedLines == [])
    }

    @Test func utf8SplitAcrossChunksRendersOnce() {
        var buffer = TerminalBuffer()
        let bytes = Array("è".utf8)
        #expect(bytes.count == 2)
        buffer.feed(Data("perch".utf8) + Data([bytes[0]]))
        buffer.feed(Data([bytes[1]]) + Data("!".utf8))
        #expect(buffer.trimmedLines == ["perchè!"])
        #expect(buffer.cursor.column == 7)
    }

    @Test func invalidUTF8BecomesReplacementCharacters() {
        var buffer = TerminalBuffer()
        buffer.feed(Data([0x61, 0xC3, 0x62, 0xFF, 0xE2, 0x82, 0x63]))
        #expect(buffer.trimmedLines == ["a\u{FFFD}b\u{FFFD}\u{FFFD}c"])
    }

    @Test func osc52AndOtherOSCAreIgnored() {
        var buffer = TerminalBuffer()
        buffer.feed("a\(esc)]52;c;cm0gLXJmIH4=\u{07}b\(esc)]0;titolo\(esc)\\c\(esc)]8;;https://example.com\u{07}link\(esc)]8;;\u{07}")
        #expect(buffer.trimmedLines == ["abclink"])
        #expect(buffer.pendingEscapeCount == 0)
    }

    @Test func dcsAndUnknownSequencesAreDropped() {
        var buffer = TerminalBuffer()
        buffer.feed("a\(esc)P1$r0m\(esc)\\b\(esc)[5zc\(esc)(Bd\(esc)=e\(esc)[>0cf")
        #expect(buffer.trimmedLines == ["abcdef"])
    }

    @Test func unterminatedEscapeLongerThan256BytesIsDropped() {
        var buffer = TerminalBuffer()
        buffer.feed("\(esc)[" + String(repeating: "1;", count: 200))
        #expect(buffer.pendingEscapeCount <= TerminalBuffer.maxPendingEscape)
        #expect(TerminalBuffer.maxPendingEscape == 256)
        buffer.feed("\(esc)]52;c;" + String(repeating: "A", count: 10_000))
        #expect(buffer.pendingEscapeCount <= TerminalBuffer.maxPendingEscape)
        // A string (OSC) is skipped until its terminator however long, without holding its bytes;
        // after BEL what follows is text again.
        buffer.feed("\u{07}\r\(esc)[2Kok")
        #expect(buffer.lines.contains("ok"))
    }

    @Test func longOSCAndDCSNeverSpillOntoTheScreen() {
        var buffer = TerminalBuffer()
        buffer.feed("a\(esc)]8;;https://" + String(repeating: "x", count: 10_000) + "\u{07}b")
        buffer.feed("\(esc)P" + String(repeating: "q", count: 5_000) + "\(esc)\\c")
        buffer.feed("\(esc)_" + String(repeating: "z", count: 5_000) + "\u{18}d")
        #expect(buffer.trimmedLines == ["abcd"])
        #expect(buffer.pendingEscapeCount <= TerminalBuffer.maxPendingEscape)
    }

    // MARK: - Replies (R-M2-35: only DSR 5n and 6n)

    @Test func statusReportIsAnswered() {
        var buffer = TerminalBuffer()
        buffer.feed("\(esc)[5n")
        #expect(buffer.takeReplies() == [Data("\(esc)[0n".utf8)])
        #expect(buffer.takeReplies().isEmpty)
    }

    @Test func cursorPositionReportIsOneBasedAndClamped() {
        var buffer = TerminalBuffer(columns: 100, rows: 32)
        buffer.feed("\r\n\r\nabcd\(esc)[6n")
        #expect(buffer.takeReplies() == [Data("\(esc)[3;5R".utf8)])
        // systemd's size probe: far bottom-right, then ask.
        buffer.feed("\(esc)[32766;32766H\(esc)[6n")
        #expect(buffer.takeReplies() == [Data("\(esc)[32;100R".utf8)])
        #expect(buffer.trimmedLines == ["", "", "abcd"])
    }

    @Test func otherQueriesAreNeverAnswered() {
        var buffer = TerminalBuffer()
        buffer.feed("\(esc)[?6n\(esc)[c\(esc)[0c\(esc)[>c\(esc)[=c\(esc)[x\(esc)Z")
        buffer.feed("\(esc)]10;?\u{07}\(esc)]11;?\(esc)\\\(esc)[21t\(esc)[14t\(esc)P$qm\(esc)\\\(esc)[1n\(esc)[n")
        #expect(buffer.takeReplies().isEmpty)
    }

    @Test func replyFloodIsCapped() {
        var buffer = TerminalBuffer()
        buffer.feed(String(repeating: "\(esc)[6n", count: 1_000))
        let replies = buffer.takeReplies()
        #expect(replies.count == TerminalBuffer.maxPendingReplies)
        #expect(TerminalBuffer.maxPendingReplies == 16)
        #expect(buffer.takeReplies().isEmpty)
    }

    @Test func randomBytesFuzzStaysBounded() {
        var buffer = TerminalBuffer(columns: 80, rows: 24)
        var generator = SplitMix64(seed: 0x4E49_444F)
        let chunk = 64 * 1024
        var total = 0
        // Bias towards ESC, '[', ']' and digits so the parser spends time in every state.
        let alphabet: [UInt8] = [0x1B, 0x1B, 0x5B, 0x5D, 0x3B, 0x3F, 0x30, 0x35, 0x0A, 0x0D, 0x07, 0x08, 0x9C, 0xC3, 0xE2]
        while total < 10 * 1024 * 1024 {
            var bytes = [UInt8](repeating: 0, count: chunk)
            for index in bytes.indices {
                let value = generator.next()
                bytes[index] = value & 1 == 0 ? UInt8(truncatingIfNeeded: value >> 8)
                    : alphabet[Int((value >> 8) % UInt64(alphabet.count))]
            }
            buffer.feed(Data(bytes))
            #expect(buffer.takeReplies().count <= TerminalBuffer.maxPendingReplies)
            total += chunk
            #expect(buffer.pendingEscapeCount <= TerminalBuffer.maxPendingEscape)
        }
        #expect(buffer.scrollbackCount <= TerminalBuffer.scrollbackLimit)
        #expect(buffer.lines.count == 24)
        #expect(buffer.lines.allSatisfy { $0.unicodeScalars.count <= 80 })
        #expect((0..<24).contains(buffer.cursor.row))
        #expect((0..<80).contains(buffer.cursor.column))
    }

    @Test func resizeKeepsTheCursorOnScreen() {
        var buffer = TerminalBuffer(columns: 20, rows: 6)
        buffer.feed("1\r\n2\r\n3\r\n4\r\n5\r\n6")
        buffer.resize(columns: 4, rows: 3)
        #expect(buffer.columns == 4)
        #expect(buffer.rows == 3)
        #expect(buffer.trimmedLines == ["4", "5", "6"])
        #expect(buffer.cursor == TerminalBuffer.Position(row: 2, column: 1))
        buffer.resize(columns: 30, rows: 8)
        #expect(buffer.lines.count == 8)
        #expect(buffer.lines[2] == "6")
        // Nonsense sizes are clamped, never zero.
        buffer.resize(columns: 0, rows: -3)
        #expect(buffer.columns >= 1)
        #expect(buffer.rows >= 1)
    }

    /// Unicode format characters (Cf: bidi overrides, zero-width joiners, BOM…) could make the
    /// console show text other than what the guest sent: they are drawn as U+FFFD.
    @Test func formatCharactersAreReplaced() {
        var buffer = TerminalBuffer(columns: 20, rows: 3)
        buffer.feed("a\u{202E}b\u{200B}c\u{2066}d\u{FEFF}e\u{00AD}f")
        #expect(buffer.lines[0] == "a\u{FFFD}b\u{FFFD}c\u{FFFD}d\u{FFFD}e\u{FFFD}f")
        // Ordinary non-ASCII text is untouched.
        buffer.feed("\r\nperché ü €")
        #expect(buffer.lines[1] == "perché ü €")
    }

    /// Every change bumps `generation`; reading does not.
    @Test func generationChangesOnEveryMutation() {
        var buffer = TerminalBuffer(columns: 20, rows: 3)
        var last = buffer.generation
        func changed() -> Bool {
            defer { last = buffer.generation }
            return buffer.generation != last
        }
        buffer.feed("x")
        #expect(changed())
        _ = buffer.lines
        _ = buffer.text
        #expect(!changed())
        buffer.resize(columns: 30, rows: 4)
        #expect(changed())
        buffer.feed("\u{1B}[6n")
        #expect(changed())
        _ = buffer.takeReplies()
        #expect(changed())
        // Two buffers never share a generation (a new session's buffer always redraws).
        #expect(TerminalBuffer().generation != TerminalBuffer().generation)
    }

    /// The text of a selection that spans scrollback and screen: trailing spaces trimmed per line.
    @Test func selectionTextSpansScrollbackAndScreen() {
        var buffer = TerminalBuffer(columns: 20, rows: 2)
        buffer.feed("one   \r\ntwo\r\nthree")
        #expect(buffer.scrollbackCount == 1)
        let start = TerminalBuffer.Position(row: 0, column: 1)
        let end = TerminalBuffer.Position(row: 2, column: 2)
        #expect(buffer.text(from: start, to: end) == "ne\ntwo\nthr")
        // Reversed ends give the same text; a range past the end is clamped.
        #expect(buffer.text(from: end, to: start) == "ne\ntwo\nthr")
        #expect(buffer.text(from: .init(row: 2, column: 0), to: .init(row: 9, column: 99)) == "three")
    }

    @Test func screenTextForAccessibility() {
        var buffer = TerminalBuffer(columns: 20, rows: 3)
        buffer.feed("a\r\nb")
        #expect(buffer.text == "a\nb")
    }
}

/// Deterministic generator for the fuzz test.
private struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

@MainActor
struct TerminalModelTests {
    /// A large chunk of guest output is parsed in slices that give the main actor back in between
    /// (audit NV-6): the main actor also runs every VM, so one guest's console never holds it for
    /// a whole chunk.
    @Test func feedGivesTheMainActorBackBetweenSlices() async {
        let console = TestConsole()
        let model = TerminalModel(console: console)
        // 1000 lines of 100 bytes: a 100 KB chunk, several slices.
        console.emit(String(repeating: String(repeating: "x", count: 98) + "\r\n", count: 1_000))
        var turns = 0
        while model.buffer.scrollbackCount == 0, turns < 1_000 {
            await Task.yield()
            turns += 1
        }
        // The first progress this task sees: part of the chunk, never all of it at once.
        #expect(model.buffer.scrollbackCount > 0)
        #expect(model.buffer.scrollbackCount < 969, "the whole chunk was parsed in one main-actor turn")
        while model.buffer.scrollbackCount < 969, turns < 2_000 {
            await Task.yield()
            turns += 1
        }
        #expect(model.buffer.scrollbackCount == 969)
        console.finish()
    }
}
