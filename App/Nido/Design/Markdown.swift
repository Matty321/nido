// SPDX-License-Identifier: Apache-2.0
import Foundation

/// The block structure of the Markdown that Nido shows: a chat answer from a model, the release
/// notes. Only what those texts use: paragraphs, headings, bullet and numbered lists, fenced code,
/// quotes and rules. The inline syntax (bold, italic, inline code) is left to
/// `AttributedString(markdown:)` per block, so that a block shows its text as typed when the
/// inline syntax is incomplete.
///
/// A text that is still arriving parses the same way: an unclosed fence is a code block that is
/// not `closed` yet, so a streamed answer never jumps between layouts once the fence opens.
enum MarkdownBlock: Equatable, Sendable {
    case paragraph(String)
    case heading(level: Int, text: String)
    /// `marker` is "•" for a bullet, "3." for a numbered item; `depth` counts the indentation
    /// levels (two spaces or a tab each).
    case listItem(marker: String, depth: Int, text: String)
    case code(language: String?, text: String, closed: Bool)
    case quote(String)
    case rule

    /// Parses `text` into blocks, line by line (linear in the text's length).
    static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [Substring] = []
        var quote: [Substring] = []
        // The open fence. Its lines live apart: a binding of a tuple that held them would share
        // the array and copy all of it on every append (quadratic in a guest's long answer).
        var fence: (marker: Character, length: Int, language: String?)?
        var fenceLines: [Substring] = []
        // The last list item, still open to indented continuation lines; joined once when it ends.
        var item: (marker: String, depth: Int, lines: [Substring])?

        func flushItem() {
            guard let open = item else { return }
            item = nil
            blocks.append(.listItem(marker: open.marker, depth: open.depth, text: open.lines.joined(separator: "\n")))
        }
        func append(_ block: MarkdownBlock) {
            flushItem()
            blocks.append(block)
        }
        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            append(.paragraph(paragraph.joined(separator: "\n")))
            paragraph = []
        }
        func flushQuote() {
            guard !quote.isEmpty else { return }
            append(.quote(quote.joined(separator: "\n")))
            quote = []
        }

        // "\r\n" is one Character in Swift: split on any line break, not on "\n" alone.
        for line in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            if let open = fence {
                if let close = fenceMarker(line), close.marker == open.marker, close.length >= open.length,
                    close.info.isEmpty
                {
                    append(.code(language: open.language, text: fenceLines.joined(separator: "\n"), closed: true))
                    fence = nil
                    fenceLines = []
                } else {
                    fenceLines.append(line)
                }
                continue
            }
            if let open = fenceMarker(line) {
                flushParagraph()
                flushQuote()
                fence = (open.marker, open.length, open.info.isEmpty ? nil : open.info)
                fenceLines = []
                continue
            }
            let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
            if trimmed.isEmpty {
                flushParagraph()
                flushQuote()
                continue
            }
            if trimmed.first == ">" {
                flushParagraph()
                var rest = trimmed.dropFirst()
                if rest.first == " " { rest = rest.dropFirst() }
                quote.append(rest)
                continue
            }
            flushQuote()
            if isRule(trimmed) {
                flushParagraph()
                append(.rule)
                continue
            }
            if let heading = heading(trimmed) {
                flushParagraph()
                append(heading)
                continue
            }
            if case .listItem(let marker, let depth, let text)? = listItem(line) {
                flushParagraph()
                flushItem()
                item = (marker, depth, [Substring(text)])
                continue
            }
            // A line indented under a list item continues it.
            if paragraph.isEmpty, line.first == " " || line.first == "\t", item != nil {
                item?.lines.append(trimmed)
                continue
            }
            paragraph.append(trimmed)
        }
        if let open = fence {
            append(.code(language: open.language, text: fenceLines.joined(separator: "\n"), closed: false))
        }
        flushParagraph()
        flushQuote()
        flushItem()
        return blocks
    }

    /// "```swift" or "~~~": the fence character, its run length (3 or more) and the info text.
    /// Up to three spaces of indentation, as in CommonMark.
    private static func fenceMarker(_ line: Substring) -> (marker: Character, length: Int, info: String)? {
        let indent = line.prefix(while: { $0 == " " })
        guard indent.count <= 3 else { return nil }
        let rest = line.dropFirst(indent.count)
        guard let marker = rest.first, marker == "`" || marker == "~" else { return nil }
        let run = rest.prefix(while: { $0 == marker })
        guard run.count >= 3 else { return nil }
        let info = rest.dropFirst(run.count).trimmingCharacters(in: .whitespaces)
        // A backtick fence's info text cannot hold a backtick (CommonMark): "```a```" is inline code.
        if marker == "`", info.contains("`") { return nil }
        return (marker, run.count, info)
    }

    private static func isRule(_ line: Substring) -> Bool {
        let marks = line.filter { $0 != " " && $0 != "\t" }
        guard marks.count >= 3, let mark = marks.first, mark == "-" || mark == "*" || mark == "_" else { return false }
        return marks.allSatisfy { $0 == mark }
    }

    private static func heading(_ line: Substring) -> MarkdownBlock? {
        let hashes = line.prefix(while: { $0 == "#" })
        guard (1...6).contains(hashes.count) else { return nil }
        let rest = line.dropFirst(hashes.count)
        guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        // Closing hashes ("## Titolo ##") are not part of the text.
        while text.hasSuffix("#") { text.removeLast() }
        return .heading(level: hashes.count, text: text.trimmingCharacters(in: .whitespaces))
    }

    private static func listItem(_ line: Substring) -> MarkdownBlock? {
        var columns = 0
        var rest = line[...]
        while let first = rest.first, first == " " || first == "\t" {
            columns += first == "\t" ? 2 : 1
            rest = rest.dropFirst()
        }
        let depth = min(columns / 2, 6)
        if let bullet = rest.first, bullet == "-" || bullet == "*" || bullet == "+" {
            let after = rest.dropFirst()
            guard after.first == " " || after.first == "\t" else { return nil }
            return .listItem(marker: "•", depth: depth, text: after.trimmingCharacters(in: .whitespaces))
        }
        let digits = rest.prefix(while: { $0.isASCII && $0.isNumber })
        guard (1...9).contains(digits.count) else { return nil }
        let afterDigits = rest.dropFirst(digits.count)
        guard let delimiter = afterDigits.first, delimiter == "." || delimiter == ")" else { return nil }
        let after = afterDigits.dropFirst()
        guard after.first == " " || after.first == "\t" else { return nil }
        return .listItem(marker: digits + ".", depth: depth, text: after.trimmingCharacters(in: .whitespaces))
    }
}

extension MarkdownBlock {
    /// The inline syntax of `text` (bold, italic, strikethrough, inline code, links), whitespace
    /// kept. Only web links (`isWebLink`) stay links: any other scheme a model may write (file,
    /// javascript, an app's own) is plain text. A text that does not parse is shown as typed.
    static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false, interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible)
        guard var parsed = try? AttributedString(markdown: text, options: options) else {
            return AttributedString(text)
        }
        for run in parsed.runs {
            if let link = run.link, !isWebLink(link) { parsed[run.range].link = nil }
        }
        return parsed
    }

    /// `http` or `https` with a host: the only links an answer may carry (opened by the browser).
    /// Not with a user or password (`https://apple.com@evil.com` goes to evil.com) and not to the
    /// Mac itself (`localhost`, loopback, unspecified addresses): a model's link never reaches a
    /// service of the Mac.
    static func isWebLink(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
            url.user() == nil, url.password() == nil,
            let host = url.host()?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]")),
            !host.isEmpty
        else { return false }
        let local = host == "localhost" || host.hasSuffix(".localhost") || host.hasPrefix("127.")
            || host == "::1" || host == "0.0.0.0" || host == "::"
        return !local
    }
}
