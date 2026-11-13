// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import NidoCore

@Suite struct ConsoleSanitizerTests {
    private func clean(_ chunks: [String]) -> String {
        var sanitizer = ConsoleSanitizer()
        var out = Data()
        for chunk in chunks { out.append(sanitizer.sanitize(Data(chunk.utf8))) }
        return String(decoding: out, as: UTF8.self)
    }

    private func clean(_ text: String) -> String { clean([text]) }

    @Test func osc52ClipboardWriteIsDropped() {
        #expect(clean("a\u{1B}]52;c;ZWNobyBwd25lZA==\u{07}b") == "ab")
        #expect(clean("a\u{1B}]52;c;ZWNobw==\u{1B}\\b") == "ab")
    }

    @Test func titleSetAndReportAreDropped() {
        #expect(clean("\u{1B}]0;evil title\u{1B}\\login: ") == "login: ")
        #expect(clean("x\u{1B}[21ty") == "xy")
        #expect(clean("\u{1B}[>0;1c\u{1B}[6n") == "")
    }

    @Test func csiSgrAndCursorMovesAreDropped() {
        #expect(clean("\u{1B}[1;31mERRORE\u{1B}[0m ok\u{1B}[2J\u{1B}[H") == "ERRORE ok")
        #expect(clean("\u{1B}[?1049h\u{1B}[?2004l") == "")
    }

    @Test func stringSequencesAreDropped() {
        #expect(clean("a\u{1B}Pq#0;2;0;0;0\u{1B}\\b") == "ab")  // DCS (sixel)
        #expect(clean("a\u{1B}_apc\u{1B}\\b\u{1B}^pm\u{1B}\\c\u{1B}Xsos\u{1B}\\d") == "abcd")
        #expect(clean("a\u{1B}(Bb\u{1B}=c\u{1B}7d") == "abcd")  // charset, keypad, save cursor
    }

    @Test func c1ControlsAreDropped() {
        // U+009B is CSI, U+009D is OSC: the sequences they start go too.
        #expect(clean("a\u{9B}31mb") == "ab")
        #expect(clean("a\u{9D}0;title\u{07}b") == "ab")
        #expect(clean("a\u{9D}0;title\u{9C}b") == "ab")
        #expect(clean("a\u{85}b") == "ab")
        // Raw 8-bit C1 bytes are not valid UTF-8: dropped as well.
        var sanitizer = ConsoleSanitizer()
        #expect(sanitizer.sanitize(Data([0x61, 0x9B, 0x33, 0x31, 0x6D, 0x62])) == Data("a31mb".utf8))
    }

    @Test func textNewlinesAndTabsArePreserved() {
        let text = "Debian GNU/Linux 13 vm hvc0\r\n\r\nvm login: \tcaffè ✓ 🐧\n"
        #expect(clean(text) == text)
    }

    @Test func otherControlsAreDropped() {
        #expect(clean("a\u{07}b\u{08}c\u{00}d\u{7F}e\u{0E}f") == "abcdef")
    }

    @Test func sequencesSplitAcrossChunksAreHandled() {
        #expect(clean(["a\u{1B}", "]52;c;", "QUFB", "\u{07}b"]) == "ab")
        #expect(clean(["a\u{1B}]0;t\u{1B}", "\\b"]) == "ab")
        #expect(clean(["x\u{1B}[", "31", "my"]) == "xy")
        // A multi-byte character split between chunks.
        var sanitizer = ConsoleSanitizer()
        let bytes = Array("è🐧".utf8)
        var out = Data()
        for byte in bytes { out.append(sanitizer.sanitize(Data([byte]))) }
        #expect(String(decoding: out, as: UTF8.self) == "è🐧")
    }

    /// An escape string that never ends cannot hide the console forever nor grow the state.
    @Test func stateIsBounded() {
        var sanitizer = ConsoleSanitizer()
        _ = sanitizer.sanitize(Data("\u{1B}]52;c;".utf8))
        for _ in 0..<256 {
            _ = sanitizer.sanitize(Data(repeating: 0x41, count: 4096))
            #expect(sanitizer.pendingByteCount <= 4)
        }
        // Past the bound the text shows again (still sanitised).
        let after = sanitizer.sanitize(Data("login: ".utf8))
        #expect(String(decoding: after, as: UTF8.self).hasSuffix("login: "))
    }
}

@Suite struct EscapingControlsTests {
    @Test func controlsAreWrittenOutAndTextIsKept() {
        #expect(ConsoleSanitizer.escapingControls("/Users/è/a b") == "/Users/è/a b")
        #expect(ConsoleSanitizer.escapingControls("/x\u{1B}]52;c;y\u{07}") == "/x\\u{1B}]52;c;y\\u{7}")
        #expect(ConsoleSanitizer.escapingControls("a\nb\tc\u{7F}\u{9B}") == "a\\u{A}b\\u{9}c\\u{7F}\\u{9B}")
    }
}
