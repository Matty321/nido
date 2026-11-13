// SPDX-License-Identifier: Apache-2.0
import Foundation

/// A deliberately small YAML reader for validating the cloud-init documents Nido generates.
/// It understands comments, block maps, block lists, `|` literal blocks, double- and
/// single-quoted scalars, and one-line flow lists (`[a, b, 'c, d']`). It rejects tabs in
/// indentation, indentation that is not a multiple of two, children that are not indented
/// deeper than their parent, and unbalanced quotes or brackets. It is not a general parser.
indirect enum MiniYAML: Equatable {
    case scalar(String)
    case list([MiniYAML])
    case map([(key: String, value: MiniYAML)])

    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static func == (a: MiniYAML, b: MiniYAML) -> Bool {
        switch (a, b) {
        case (.scalar(let x), .scalar(let y)): x == y
        case (.list(let x), .list(let y)): x == y
        case (.map(let x), .map(let y)):
            x.count == y.count && zip(x, y).allSatisfy { $0.key == $1.key && $0.value == $1.value }
        default: false
        }
    }

    // MARK: Accessors

    subscript(key: String) -> MiniYAML? {
        guard case .map(let entries) = self else { return nil }
        return entries.first { $0.key == key }?.value
    }

    var keys: [String] {
        guard case .map(let entries) = self else { return [] }
        return entries.map(\.key)
    }

    var text: String? {
        guard case .scalar(let s) = self else { return nil }
        return s
    }

    var items: [MiniYAML]? {
        guard case .list(let l) = self else { return nil }
        return l
    }

    // MARK: Parsing

    private struct Line {
        let indent: Int
        let text: String  // without indentation
    }

    static func parse(_ document: String) throws -> MiniYAML {
        var raw = document.components(separatedBy: "\n")
        if raw.last == "" { raw.removeLast() }
        var lines: [Line] = []
        var literalIndent: Int? = nil  // indent of the key owning a literal block being read
        for (number, line) in raw.enumerated() {
            let indent = line.prefix(while: { $0 == " " }).count
            if line.dropFirst(indent).first == "\t" || (line.hasPrefix("\t")) {
                throw Failure(description: "line \(number + 1): tab in indentation")
            }
            let body = String(line.dropFirst(indent))
            if let owner = literalIndent {
                if body.isEmpty || indent > owner {
                    lines.append(Line(indent: body.isEmpty ? Int.max : indent, text: body))
                    continue
                }
                literalIndent = nil
            }
            if body.isEmpty || body.hasPrefix("#") { continue }
            guard indent % 2 == 0 else { throw Failure(description: "line \(number + 1): odd indentation") }
            lines.append(Line(indent: indent, text: body))
            if body.hasSuffix(" |") || body == "|" { literalIndent = indent }
        }
        var position = 0
        let value = try parseNode(lines, &position, indent: 0)
        guard position == lines.count else {
            throw Failure(description: "unexpected content: \(lines[position].text)")
        }
        return value
    }

    private static func parseNode(_ lines: [Line], _ p: inout Int, indent: Int) throws -> MiniYAML {
        guard p < lines.count, lines[p].indent == indent else {
            throw Failure(description: "bad indentation near \(p < lines.count ? lines[p].text : "end")")
        }
        return isListItem(lines[p].text)
            ? try parseList(lines, &p, indent: indent) : try parseMap(lines, &p, indent: indent)
    }

    private static func isListItem(_ text: String) -> Bool { text == "-" || text.hasPrefix("- ") }

    private static func parseList(_ lines: [Line], _ p: inout Int, indent: Int) throws -> MiniYAML {
        var result: [MiniYAML] = []
        while p < lines.count, lines[p].indent == indent, isListItem(lines[p].text) {
            let rest = lines[p].text == "-" ? "" : String(lines[p].text.dropFirst(2))
            if rest.isEmpty {
                p += 1
                guard p < lines.count, lines[p].indent > indent else {
                    throw Failure(description: "empty list item")
                }
                result.append(try parseNode(lines, &p, indent: lines[p].indent))
            } else if splitKey(rest) != nil {
                // "- key: value": the map continues on the following lines at indent + 2.
                var inner = Array(lines[p...])
                inner[0] = Line(indent: indent + 2, text: rest)
                var q = 0
                result.append(try parseMap(inner, &q, indent: indent + 2))
                p += q
            } else {
                p += 1
                result.append(try parseScalar(rest))
            }
        }
        return .list(result)
    }

    private static func parseMap(_ lines: [Line], _ p: inout Int, indent: Int) throws -> MiniYAML {
        var entries: [(key: String, value: MiniYAML)] = []
        while p < lines.count, lines[p].indent == indent, !isListItem(lines[p].text) {
            guard let (key, rest) = splitKey(lines[p].text) else {
                throw Failure(description: "not a mapping entry: \(lines[p].text)")
            }
            p += 1
            if rest.isEmpty {
                guard p < lines.count, lines[p].indent > indent, lines[p].indent != Int.max else {
                    entries.append((key, .scalar("")))  // YAML null
                    continue
                }
                entries.append((key, try parseNode(lines, &p, indent: lines[p].indent)))
            } else if rest == "|" {
                var block: [String] = []
                while p < lines.count, lines[p].indent > indent {
                    block.append(lines[p].text.isEmpty ? "" : String(repeating: " ", count: lines[p].indent - indent - 2) + lines[p].text)
                    p += 1
                }
                entries.append((key, .scalar(block.joined(separator: "\n") + "\n")))
            } else {
                entries.append((key, try parseScalar(rest)))
            }
        }
        if p < lines.count, lines[p].indent > indent, lines[p].indent != Int.max {
            throw Failure(description: "bad indentation near \(lines[p].text)")
        }
        return .map(entries)
    }

    /// Splits `key: rest` at the first `:` outside quotes that ends the key (followed by a space
    /// or the end of the line). Returns nil when the text is not a mapping entry.
    private static func splitKey(_ text: String) -> (String, String)? {
        guard let first = text.first, first != "\"", first != "'", first != "[" else { return nil }
        let chars = Array(text)
        for i in chars.indices where chars[i] == ":" && (i + 1 == chars.count || chars[i + 1] == " ") {
            let key = String(chars[..<i])
            let rest = String(chars[(i + 1)...]).trimmingCharacters(in: .whitespaces)
            return (key, rest)
        }
        return nil
    }

    private static func parseScalar(_ text: String) throws -> MiniYAML {
        if text.hasPrefix("[") { return .list(try parseFlow(text)) }
        if text.hasPrefix("\"") || text.hasPrefix("'") {
            let (value, end) = try parseQuoted(Array(text), from: 0)
            guard end == text.count else { throw Failure(description: "trailing text after quote: \(text)") }
            return .scalar(value)
        }
        return .scalar(text)
    }

    /// Reads a quoted scalar starting at `chars[start]`; returns the value and the index after it.
    private static func parseQuoted(_ chars: [Character], from start: Int) throws -> (String, Int) {
        let quote = chars[start]
        var value = ""
        var i = start + 1
        while i < chars.count {
            let c = chars[i]
            if quote == "\"", c == "\\" {
                guard i + 1 < chars.count else { break }
                value.append(chars[i + 1])
                i += 2
            } else if c == quote {
                if quote == "'", i + 1 < chars.count, chars[i + 1] == "'" {
                    value.append("'")
                    i += 2
                } else {
                    return (value, i + 1)
                }
            } else {
                value.append(c)
                i += 1
            }
        }
        throw Failure(description: "unbalanced quote: \(String(chars))")
    }

    private static func parseFlow(_ text: String) throws -> [MiniYAML] {
        let chars = Array(text)
        guard chars.last == "]" else { throw Failure(description: "unbalanced bracket: \(text)") }
        var items: [MiniYAML] = []
        var i = 1
        let end = chars.count - 1
        while i < end {
            while i < end, chars[i] == " " { i += 1 }
            guard i < end else { break }
            var item: String
            if chars[i] == "\"" || chars[i] == "'" {
                (item, i) = try parseQuoted(chars, from: i)
            } else {
                var j = i
                while j < end, chars[j] != "," { j += 1 }
                item = String(chars[i..<j]).trimmingCharacters(in: .whitespaces)
                if item.contains("[") || item.contains("]") {
                    throw Failure(description: "bracket in plain flow item: \(item)")
                }
                i = j
            }
            while i < end, chars[i] == " " { i += 1 }
            if i < end {
                guard chars[i] == "," else { throw Failure(description: "expected comma in: \(text)") }
                i += 1
            }
            items.append(.scalar(item))
        }
        return items
    }
}
