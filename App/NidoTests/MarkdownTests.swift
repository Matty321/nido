// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import Nido

struct MarkdownTests {
    @Test func blocksOfATypicalAnswer() {
        let text = """
            # Titolo
            Un **paragrafo** con `codice`
            su due righe.

            - uno
            - due
              continua
              - annidato
            1. primo
            12) dodicesimo

            ```bash
            ls -la
            echo "ciao"
            ```
            > citazione
            > seconda

            ---
            fine
            """
        #expect(MarkdownBlock.parse(text) == [
            .heading(level: 1, text: "Titolo"),
            .paragraph("Un **paragrafo** con `codice`\nsu due righe."),
            .listItem(marker: "•", depth: 0, text: "uno"),
            .listItem(marker: "•", depth: 0, text: "due\ncontinua"),
            .listItem(marker: "•", depth: 1, text: "annidato"),
            .listItem(marker: "1.", depth: 0, text: "primo"),
            .listItem(marker: "12.", depth: 0, text: "dodicesimo"),
            .code(language: "bash", text: "ls -la\necho \"ciao\"", closed: true),
            .quote("citazione\nseconda"),
            .rule,
            .paragraph("fine"),
        ])
    }

    /// While an answer streams the fence may still be open: a code block that is not closed,
    /// whose text keeps growing, never a paragraph that later turns into code.
    @Test func openFenceWhileStreaming() {
        #expect(MarkdownBlock.parse("Ecco:\n```py") == [
            .paragraph("Ecco:"), .code(language: "py", text: "", closed: false),
        ])
        #expect(MarkdownBlock.parse("Ecco:\n```py\nprint(1)\n") == [
            .paragraph("Ecco:"), .code(language: "py", text: "print(1)\n", closed: false),
        ])
        // A shorter fence does not close a longer one; "~~~" fences work the same way.
        #expect(MarkdownBlock.parse("````\n```\n````") == [.code(language: nil, text: "```", closed: true)])
        #expect(MarkdownBlock.parse("~~~\na\n~~~") == [.code(language: nil, text: "a", closed: true)])
    }

    @Test func notBlocksWhenTheSyntaxDoesNotMatch() {
        #expect(MarkdownBlock.parse("#senza spazio") == [.paragraph("#senza spazio")])
        #expect(MarkdownBlock.parse("-senza spazio") == [.paragraph("-senza spazio")])
        #expect(MarkdownBlock.parse("2026.10 è una data") == [.paragraph("2026.10 è una data")])
        #expect(MarkdownBlock.parse("```a``` in linea") == [.paragraph("```a``` in linea")])
        #expect(MarkdownBlock.parse("## Titolo ##") == [.heading(level: 2, text: "Titolo")])
        #expect(MarkdownBlock.parse("") == [])
        #expect(MarkdownBlock.parse("riga\r\naltra") == [.paragraph("riga\naltra")])
    }

    @Test func inlineSyntax() {
        let text = MarkdownBlock.inline("**grassetto** *corsivo* `x`")
        #expect(String(text.characters) == "grassetto corsivo x")
        let intents = text.runs.compactMap { run -> String? in
            guard let intent = run.inlinePresentationIntent else { return nil }
            return "\(String(text[run.range].characters)):\(intent.rawValue)"
        }
        #expect(intents.contains("grassetto:\(InlinePresentationIntent.stronglyEmphasized.rawValue)"))
        #expect(intents.contains("corsivo:\(InlinePresentationIntent.emphasized.rawValue)"))
        #expect(intents.contains("x:\(InlinePresentationIntent.code.rawValue)"))
        #expect(text.runs.allSatisfy { $0.link == nil })
        // Unbalanced syntax (an answer still arriving) stays as typed.
        #expect(String(MarkdownBlock.inline("**gras").characters) == "**gras")
        // Whitespace is kept.
        #expect(String(MarkdownBlock.inline("a\n  b").characters) == "a\n  b")
    }

    /// Web links work (they open in the browser, never in Nido); any other scheme a model may
    /// write (file, javascript, a custom app scheme) is plain text.
    @Test func onlyWebLinksStayLinks() {
        let text = MarkdownBlock.inline(
            "[doc](https://example.com/a) [http](http://example.org) [file](file:///etc/passwd) "
                + "[js](javascript:alert(1)) [app](nido://x) <https://auto.example>")
        let links = text.runs.compactMap { run in run.link.map { (String(text[run.range].characters), $0.absoluteString) } }
        #expect(links.map(\.0) == ["doc", "http", "https://auto.example"])
        #expect(links.map(\.1) == ["https://example.com/a", "http://example.org", "https://auto.example"])
        #expect(String(text.characters).contains("file js app"))
        #expect(MarkdownBlock.isWebLink(URL(string: "https://x")!))
        #expect(!MarkdownBlock.isWebLink(URL(string: "file:///x")!))
        // An address that hides where it goes, or the Mac's own services: plain text.
        for disguised in ["http://apple.com@evil.com", "https://user:pw@example.com", "http://localhost:8080",
                          "http://127.0.0.1:11434/api", "http://[::1]/", "https://0.0.0.0/"] {
            #expect(!MarkdownBlock.isWebLink(URL(string: disguised)!), "\(disguised)")
        }
    }

    /// The parse stays linear in the text (audit NV-3, NV-2): a guest's chat answer made of many
    /// list continuation lines, or of many lines in an open fence, must cost about what a plain
    /// paragraph of as many lines costs, not quadratic time on the main actor that hosts every VM.
    @Test(arguments: [("- a\n", " b\n", 160_000), ("```\n", "x\n", 40_000)])
    func parseIsLinear(head: String, line: String, count: Int) {
        func cost(_ text: String) -> Duration {
            (0..<3).map { _ in ContinuousClock().measure { _ = MarkdownBlock.parse(text) } }.min()!
        }
        let shaped = cost(head + String(repeating: line, count: count))
        let plain = cost(String(repeating: "b\n", count: count))
        #expect(shaped < plain * 3, "\(count) lines took \(shaped / plain)× a paragraph's time")
    }
}
