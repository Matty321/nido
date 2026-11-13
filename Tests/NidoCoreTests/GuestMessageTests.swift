// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import NidoCore

/// The codes of `nido-provision` (Guest Tools) and the text Nido shows for each.
@Suite struct GuestMessageTests {
    /// provision.py as the Guest Tools payload ships it.
    private func provisionSource() throws -> String {
        let file = try #require(GuestToolsPayload.files.first {
            $0.path == "/opt/nido-guest-tools/nido_guest_tools/provision.py"
        })
        return try #require(Data(base64Encoded: file.base64).flatMap { String(data: $0, encoding: .utf8) })
    }

    /// The `MESSAGES` table of provision.py: code → English message, `%s` written `%@`.
    private func guestTable() throws -> [String: String] {
        let source = try provisionSource()
        let start = try #require(source.range(of: "\nMESSAGES = {\n"))
        let end = try #require(source.range(of: "\n}\n", range: start.upperBound..<source.endIndex))
        var table: [String: String] = [:]
        for line in source[start.upperBound..<end.lowerBound].split(separator: "\n") {
            let entry = line.trimmingCharacters(in: .whitespaces)
            if entry.hasPrefix("#") { continue }
            let parts = try #require(entry.firstMatch(of: /^"([a-z0-9_]+)": "(.*)",$/), "\(entry)")
            table[String(parts.1)] = String(parts.2).replacingOccurrences(of: "%s", with: "%@")
        }
        return table
    }

    /// Every code the Guest Tools of this Nido send has its text, with the same English message.
    @Test func everyGuestCodeIsKnown() throws {
        let guest = try guestTable()
        #expect(guest.count >= 25)
        #expect(guest == GuestMessage.templates)
    }

    /// The English text of each code is the guest's message itself, its values in place, and no
    /// language leaves a code or a value out.
    @Test func everyCodeHasItsTextInEveryLanguage() {
        for (code, template) in GuestMessage.templates {
            let count = template.components(separatedBy: "%@").count - 1
            let values = (0..<count).map { "value\($0)" }
            var message = template
            for value in values {
                message = message.replacingOccurrences(of: "%@", with: value, options: [],
                                                       range: message.range(of: "%@"))
            }
            #expect(GuestMessage.text("\(code): \(message)", language: "en") == message, "\(code)")
            for language in ["it", "de", "es", "fr"] {
                let text = GuestMessage.text("\(code): \(message)", language: language)
                #expect(text != message && text != "\(code): \(message)", "\(code) in \(language)")
                for value in values { #expect(text.contains(value), "\(code) in \(language) lacks \(value)") }
            }
        }
    }

    /// Italian is the message Guest Tools before 1.5.0 wrote, word for word.
    @Test func italianIsTheEarlierGuestText() {
        let cases: [(String, String)] = [
            ("ollama_not_installed: Ollama isn’t installed", "Ollama non è installato"),
            ("ollama_not_running: Ollama isn’t running: start it or install it",
             "Ollama non è in esecuzione: avvialo o installalo"),
            ("archive_from_mac_required: the Ollama archive comes from the Mac: install Ollama from the Nido app or update Nido",
             "l'archivio di Ollama arriva dal Mac: installa Ollama dall'app di Nido o aggiorna Nido"),
            ("ollama_files_damaged: the files of Ollama 0.40.10 are incomplete or damaged: install it again with Try Again",
             "i file di Ollama 0.40.10 sono incompleti o danneggiati: usa Riprova (installazione)"),
            ("user_create_failed: couldn’t create the user ollama: useradd: failure",
             "impossibile creare l'utente ollama: useradd: failure"),
            ("interrupted: interrupted: click Try Again", "interrotto: usa Riprova"),
        ]
        for (coded, italian) in cases {
            #expect(GuestMessage.text(coded, language: "it") == italian)
        }
    }
}
