// SPDX-License-Identifier: Apache-2.0
import AppKit
import Darwin
import Foundation
import NidoCore
import Testing

@testable import Nido

/// Keys and paste to the bytes a VT terminal sends.
struct TerminalInputTests {
    private func bytes(_ characters: String?, ignoring: String? = nil, special: NSEvent.SpecialKey? = nil,
                       keyCode: UInt16 = 0, _ modifiers: NSEvent.ModifierFlags = []) -> [UInt8]? {
        TerminalInput.bytes(characters: characters, charactersIgnoringModifiers: ignoring ?? characters,
                            specialKey: special, keyCode: keyCode, modifiers: modifiers).map { Array($0) }
    }

    @Test func printableText() {
        #expect(bytes("a") == [0x61])
        #expect(bytes("è") == Array("è".utf8))
        #expect(bytes("A", ignoring: "a", [.shift]) == [0x41])
    }

    @Test func editingKeys() {
        #expect(bytes("\r", special: .carriageReturn) == [0x0D])
        #expect(bytes("\u{3}", special: .enter) == [0x0D])
        #expect(bytes("\u{7F}", special: .delete) == [0x7F])
        #expect(bytes("\t", special: .tab) == [0x09])
        #expect(bytes("\u{19}", special: .backTab, [.shift]) == Array("\u{1B}[Z".utf8))
        #expect(bytes("\u{1B}", keyCode: 53) == [0x1B])
        #expect(bytes("\u{F728}", special: .deleteForward) == Array("\u{1B}[3~".utf8))
    }

    @Test func arrowsAndNavigation() {
        #expect(bytes("\u{F700}", special: .upArrow) == Array("\u{1B}[A".utf8))
        #expect(bytes("\u{F701}", special: .downArrow) == Array("\u{1B}[B".utf8))
        #expect(bytes("\u{F703}", special: .rightArrow) == Array("\u{1B}[C".utf8))
        #expect(bytes("\u{F702}", special: .leftArrow) == Array("\u{1B}[D".utf8))
        #expect(bytes("\u{F729}", special: .home) == Array("\u{1B}[H".utf8))
        #expect(bytes("\u{F72B}", special: .end) == Array("\u{1B}[F".utf8))
        #expect(bytes("\u{F72C}", special: .pageUp) == Array("\u{1B}[5~".utf8))
        #expect(bytes("\u{F72D}", special: .pageDown) == Array("\u{1B}[6~".utf8))
    }

    @Test func controlCombos() {
        #expect(bytes("\u{3}", ignoring: "c", [.control]) == [0x03])
        #expect(bytes("\u{4}", ignoring: "d", [.control]) == [0x04])
        #expect(bytes(nil, ignoring: "z", [.control]) == [0x1A])
        #expect(bytes("", ignoring: "[", [.control]) == [0x1B])
    }

    @Test func commandShortcutsStayWithTheApp() {
        #expect(bytes("w", [.command]) == nil)
        #expect(bytes("q", [.command]) == nil)
        #expect(bytes("f", [.command, .control]) == nil)
    }

    @Test func unmappedFunctionKeysSendNothing() {
        #expect(bytes("\u{F704}", special: .f1) == nil)
    }

    @Test func pasteTurnsNewlinesIntoReturns() {
        #expect(Array(TerminalInput.paste("ls -l\nexit\r\n", bracketed: false)) == Array("ls -l\rexit\r".utf8))
    }

    @Test func bracketedPasteWrapsAndCannotBeEscaped() {
        let data = TerminalInput.paste("a\u{1B}[201~rm -rf /\n", bracketed: true)
        #expect(String(decoding: data, as: UTF8.self) == "\u{1B}[200~a[201~rm -rf /\r\u{1B}[201~")
    }

    @Test func pasteIsBounded() {
        let huge = String(repeating: "x", count: 1_000_000)
        #expect(TerminalInput.paste(huge, bracketed: false).count == TerminalInput.maxPaste)
        // Bracketed, with its markers, a max-size paste still fits the console's input queue.
        let bracketed = TerminalInput.paste(huge, bracketed: true)
        #expect(bracketed.count == TerminalInput.maxPaste + 12)
        #expect(bracketed.count <= SerialConsole.maxPendingInput / 2 + 12)
    }

    @Test func pasteNeverSplitsACharacter() {
        let text = String(repeating: "è", count: TerminalInput.maxPaste)  // 2 bytes each
        let data = TerminalInput.paste(text, bracketed: false)
        #expect(String(data: data, encoding: .utf8) != nil)
    }

    /// The whole max-size bracketed paste reaches the guest, closing marker included.
    @Test func maxSizeBracketedPasteReachesTheGuestWhole() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nido-paste-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: dir) }
        let console = try SerialConsole(logURL: dir.appendingPathComponent("console.log"))
        defer { console.close() }
        let paste = TerminalInput.paste(String(repeating: "x", count: 1_000_000), bracketed: true)

        console.send(paste)

        var received = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        let fd = console.guestReadHandle.fileDescriptor
        while received.count < paste.count {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&pfd, 1, 5000) > 0 else { break }
            let n = read(fd, &buffer, buffer.count)
            guard n > 0 else { break }
            received.append(contentsOf: buffer[0..<n])
        }
        #expect(received.count == paste.count)
        #expect(received.suffix(6) == Data("\u{1B}[201~".utf8))
        #expect(received.prefix(6) == Data("\u{1B}[200~".utf8))
    }
}
