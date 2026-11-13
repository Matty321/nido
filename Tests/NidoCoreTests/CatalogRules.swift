// SPDX-License-Identifier: Apache-2.0
import Foundation

/// The rules every String Catalog of Nido keeps (see docs/LOCALIZATION.md). One source file,
/// compiled into two test targets: NidoCoreTests (SwiftPM, `LocalizationCatalogTests`) and the
/// app's NidoTests (a file reference in the Xcode project, `AppCatalogTests`), so NidoCore's
/// catalog and the app's catalog are held to the same rules. Pure Foundation on purpose.
///
/// Every check returns its problems as lines ("<key>: <problem>"); an empty list means the
/// catalog keeps the rule.
enum CatalogRules {
    /// The five languages of Nido; English is the source language and the key text.
    static let languages = ["en", "it", "de", "es", "fr"]

    /// Put this in an entry's `comment` when its integer placeholder is not a count (a port, a
    /// PID, a percentage, a version): the entry then needs no plural variations.
    static let notACountMarker = "[not a count]"

    // MARK: - Catalog model (the parts of Xcode's .xcstrings format Nido uses)

    struct Catalog: Decodable {
        var sourceLanguage: String
        var version: String
        var strings: [String: Entry]
    }

    struct Entry: Decodable {
        var comment: String?
        var extractionState: String?
        var shouldTranslate: Bool?
        var localizations: [String: Localization]?
    }

    struct Localization: Decodable {
        var stringUnit: StringUnit?
        var variations: Variations?
        var substitutions: [String: Substitution]?
    }

    struct StringUnit: Decodable {
        var state: String?
        var value: String?
    }

    /// `plural` (`zero one two few many other`) and `device` (`mac`, `other`…): each case holds
    /// a string unit or further variations.
    struct Variations: Decodable {
        var plural: [String: Localization]?
        var device: [String: Localization]?
    }

    /// `%#@name@` in a value refers to `substitutions[name]`: its own plural variations, where
    /// `%arg` stands for the argument `argNum` formatted with `formatSpecifier`.
    struct Substitution: Decodable {
        var argNum: Int?
        var formatSpecifier: String?
        var variations: Variations?
    }

    static func load(_ url: URL) throws -> Catalog {
        try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: url))
    }

    // MARK: - Rules

    /// The file itself: source language English, format version 1.0.
    static func formatProblems(_ catalog: Catalog) -> [String] {
        var problems: [String] = []
        if catalog.sourceLanguage != "en" { problems.append("sourceLanguage is \(catalog.sourceLanguage), not en") }
        if catalog.version != "1.0" { problems.append("version is \(catalog.version), not 1.0") }
        return problems
    }

    /// `everyKeyHasAllLanguages`: each entry has a non-empty, `translated` value (or plural
    /// variations whose every case is) in en, it, de, es and fr. English may be left out when the
    /// key text is the English and the entry has no variations (Xcode's own convention). Entries
    /// marked "Don't translate" (`shouldTranslate: false`) are skipped.
    static func missingLanguages(_ catalog: Catalog) -> [String] {
        var problems: [String] = []
        for (key, entry) in catalog.strings.sorted(by: { $0.key < $1.key }) where entry.shouldTranslate != false {
            let localizations = entry.localizations ?? [:]
            let anyVariations = localizations.values.contains { $0.variations != nil || $0.substitutions != nil }
            for language in languages {
                guard let localization = localizations[language] else {
                    if language == "en", !key.isEmpty, !anyVariations { continue }
                    problems.append("\(show(key)): no \(language)")
                    continue
                }
                let units = stringUnits(of: localization)
                if units.isEmpty { problems.append("\(show(key)): \(language) has no value") }
                for unit in units {
                    if unit.state != "translated" {
                        problems.append("\(show(key)): \(language) is \(unit.state ?? "without state"), not translated")
                    }
                    if (unit.value ?? "").isEmpty { problems.append("\(show(key)): \(language) is empty") }
                }
            }
        }
        return problems
    }

    /// `placeholdersMatch`: every language passes the same arguments, in the same positions and
    /// of the same types, as the key (the English format string the code looks up): `%@` and
    /// `%1$@` are the same argument, reordering with `%2$@ … %1$@` is allowed. Plural cases count
    /// together (a `one` case may write "One VM" without `%lld`).
    static func placeholderMismatches(_ catalog: Catalog) -> [String] {
        var problems: [String] = []
        for (key, entry) in catalog.strings.sorted(by: { $0.key < $1.key }) {
            let expected = arguments(in: key)
            if !expected.conflicts.isEmpty { problems.append("\(show(key)): the key uses one position twice") }
            for language in languages {
                guard let localization = entry.localizations?[language] else { continue }
                let found = arguments(of: localization)
                if !found.conflicts.isEmpty {
                    problems.append("\(show(key)): \(language) gives one position two types")
                } else if found.types != expected.types {
                    problems.append("\(show(key)): \(language) has \(describe(found.types)), the key has \(describe(expected.types))")
                }
            }
        }
        return problems
    }

    /// `pluralKeysHaveVariations`: a key with an integer placeholder (`%lld`, `%d`, `%llu`…) is a
    /// count, so each of the five languages needs plural variations with at least `one` and
    /// `other` (directly, or in every `%#@…@` substitution). A comment with `[not a count]` opts
    /// an entry out. Any plural variation, anywhere, needs `one` and `other`.
    static func pluralProblems(_ catalog: Catalog) -> [String] {
        var problems: [String] = []
        for (key, entry) in catalog.strings.sorted(by: { $0.key < $1.key }) where entry.shouldTranslate != false {
            let isCount = arguments(in: key).types.values.contains(where: isInteger)
                && !(entry.comment ?? "").contains(notACountMarker)
            for language in languages {
                let localization = entry.localizations?[language]
                let plurals = localization.map(pluralCases(of:)) ?? []
                for cases in plurals where !(cases.contains("one") && cases.contains("other")) {
                    problems.append("\(show(key)): \(language) plural without one and other (\(cases.sorted().joined(separator: ", ")))")
                }
                if isCount && plurals.isEmpty {
                    problems.append("\(show(key)): \(language) needs plural variations (or \(notACountMarker) in the comment)")
                }
            }
        }
        return problems
    }

    // MARK: - String units and plural cases

    /// Every string unit of a localization: its own, its variations', its substitutions'.
    static func stringUnits(of localization: Localization) -> [StringUnit] {
        var units: [StringUnit] = []
        if let unit = localization.stringUnit { units.append(unit) }
        if let variations = localization.variations { units += stringUnits(of: variations) }
        for substitution in (localization.substitutions ?? [:]).values {
            if let variations = substitution.variations { units += stringUnits(of: variations) }
        }
        return units
    }

    private static func stringUnits(of variations: Variations) -> [StringUnit] {
        let cases = Array((variations.plural ?? [:]).values) + Array((variations.device ?? [:]).values)
        return cases.flatMap(stringUnits(of:))
    }

    /// The case names of every plural variation in a localization (one set per variation).
    static func pluralCases(of localization: Localization) -> [Set<String>] {
        var found: [Set<String>] = []
        if let variations = localization.variations { found += pluralCases(of: variations) }
        for substitution in (localization.substitutions ?? [:]).values {
            if let variations = substitution.variations { found += pluralCases(of: variations) }
        }
        return found
    }

    private static func pluralCases(of variations: Variations) -> [Set<String>] {
        var found: [Set<String>] = []
        if let plural = variations.plural {
            found.append(Set(plural.keys))
            found += plural.values.flatMap(pluralCases(of:))
        }
        for device in (variations.device ?? [:]).values { found += pluralCases(of: device) }
        return found
    }

    // MARK: - Format arguments

    /// The arguments a format string takes: position (1-based) to type (length modifier and
    /// conversion, e.g. `@`, `lld`, `f`; flags, width and precision do not change the argument).
    struct Arguments: Equatable {
        var types: [Int: String] = [:]
        var conflicts: Set<Int> = []

        mutating func add(_ type: String, at position: Int) {
            if let known = types[position], known != type { conflicts.insert(position) }
            types[position] = type
        }

        mutating func merge(_ other: Arguments) {
            for (position, type) in other.types { add(type, at: position) }
            conflicts.formUnion(other.conflicts)
        }
    }

    /// One token of a format string.
    enum Token: Equatable {
        case literal(String)
        /// `%[n$][flags][width][.precision][length]conversion`; `type` is length + conversion.
        case specifier(position: Int?, type: String)
        /// `%#@name@`: a substitution.
        case substitution(String)
        /// `%arg`: the argument of the substitution it sits in.
        case substitutionArgument
    }

    /// Splits a format string the way Foundation reads it. `%%` is a literal `%`. A `%` that
    /// starts no valid specifier stays literal (so "50% done" in a key without arguments is
    /// text; the space flag is not supported on purpose, it would read "% d" as a specifier).
    static func tokens(of format: String, keepingPercentEscapes: Bool = false) -> [Token] {
        var tokens: [Token] = []
        var literal = ""
        let scalars = Array(format.unicodeScalars)
        var i = 0
        func flush() {
            if !literal.isEmpty { tokens.append(.literal(literal)); literal = "" }
        }
        while i < scalars.count {
            guard scalars[i] == "%" else {
                literal.unicodeScalars.append(scalars[i]); i += 1
                continue
            }
            if i + 1 < scalars.count, scalars[i + 1] == "%" {
                literal += keepingPercentEscapes ? "%%" : "%"; i += 2
                continue
            }
            if let (token, length) = specifier(in: scalars, at: i) {
                flush()
                tokens.append(token)
                i += length
            } else {
                literal += "%"; i += 1
            }
        }
        flush()
        return tokens
    }

    private static let lengthModifiers = ["hh", "h", "ll", "l", "q", "z", "t", "j", "L"]
    private static let conversions = Set("@dDiuUxXoOfFeEgGaAcCsSp".unicodeScalars)

    /// Reads one specifier starting at the `%` at `start`; nil if none starts there.
    private static func specifier(in s: [Unicode.Scalar], at start: Int) -> (Token, Int)? {
        let rest = String(String.UnicodeScalarView(s[(start + 1)...].prefix(64)))
        if rest.hasPrefix("arg"), !(rest.dropFirst(3).first.map { $0.isLetter || $0.isNumber } ?? false) {
            return (.substitutionArgument, 4)
        }
        if rest.hasPrefix("#@"), let close = rest.dropFirst(2).firstIndex(of: "@") {
            let name = String(rest[rest.index(rest.startIndex, offsetBy: 2)..<close])
            if !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) {
                return (.substitution(name), 1 + 2 + name.unicodeScalars.count + 1)
            }
        }
        var i = start + 1
        func digits() -> String {
            var text = ""
            while i < s.count, ("0"..."9").contains(s[i]) { text.unicodeScalars.append(s[i]); i += 1 }
            return text
        }
        var position: Int?
        let leading = digits()
        if !leading.isEmpty, i < s.count, s[i] == "$" {
            position = Int(leading); i += 1
        } else {
            i = start + 1
        }
        while i < s.count, "-+0#'".unicodeScalars.contains(s[i]) { i += 1 }
        _ = digits()
        if i < s.count, s[i] == "." { i += 1; _ = digits() }
        var length = ""
        for modifier in lengthModifiers where i + modifier.unicodeScalars.count <= s.count {
            if String(String.UnicodeScalarView(s[i..<(i + modifier.unicodeScalars.count)])) == modifier {
                length = modifier; i += modifier.unicodeScalars.count
                break
            }
        }
        guard i < s.count, conversions.contains(s[i]) else { return nil }
        let type = normalized(length + String(s[i]))
        return (.specifier(position: position, type: type), i + 1 - start)
    }

    /// `%lf` and `%f` take the same double; everything else is compared as written.
    private static func normalized(_ type: String) -> String {
        type == "lf" ? "f" : type
    }

    static func isInteger(_ type: String) -> Bool {
        guard let conversion = type.last else { return false }
        return "dDiuU".contains(conversion)
    }

    /// The arguments of a plain format string (a key, or one string unit).
    static func arguments(in format: String, substitutions: [String: Substitution] = [:]) -> Arguments {
        var arguments = Arguments()
        var next = 1
        for token in tokens(of: format) {
            switch token {
            case .literal, .substitutionArgument:
                continue
            case .specifier(let position, let type):
                if let position {
                    arguments.add(type, at: position)
                } else {
                    arguments.add(type, at: next); next += 1
                }
            case .substitution(let name):
                let substitution = substitutions[name]
                // `%#@name@` takes the next argument slot like any specifier; `argNum` names it.
                let position = substitution?.argNum ?? next
                next += 1
                let specifier = substitution?.formatSpecifier ?? "@"
                let type = (tokens(of: "%" + specifier).first).flatMap { token -> String? in
                    if case .specifier(_, let type) = token { return type }
                    return nil
                } ?? specifier
                arguments.add(type, at: position)
            }
        }
        return arguments
    }

    /// The arguments of a localization: the union over its string units (plural cases count
    /// together), with `%#@…@` resolved through its substitutions.
    static func arguments(of localization: Localization) -> Arguments {
        let substitutions = localization.substitutions ?? [:]
        var result = Arguments()
        var units: [StringUnit] = []
        if let unit = localization.stringUnit { units.append(unit) }
        if let variations = localization.variations { units += stringUnits(of: variations) }
        for unit in units {
            result.merge(arguments(in: unit.value ?? "", substitutions: substitutions))
        }
        // Inside a substitution `%arg` is the substitution's own argument (already counted);
        // any other specifier there must be positional.
        for substitution in substitutions.values {
            for unit in substitution.variations.map(stringUnits(of:)) ?? [] {
                for token in tokens(of: unit.value ?? "") {
                    if case .specifier(let position?, let type) = token { result.add(type, at: position) }
                }
            }
        }
        return result
    }

    private static func describe(_ types: [Int: String]) -> String {
        types.isEmpty ? "no arguments"
            : types.sorted { $0.key < $1.key }.map { "%\($0.key)$\($0.value)" }.joined(separator: " ")
    }

    private static func show(_ key: String) -> String {
        "\"" + key.replacingOccurrences(of: "\n", with: "\\n") + "\""
    }
}

// MARK: - Keys in code

/// Finds the keys code passes to `L10n.string(` and checks them against a catalog, the way
/// Xcode extracts `String.LocalizationValue` keys:
/// - an interpolation `\(x)` becomes a format specifier (`%@` for strings and objects, `%lld`
///   for `Int`, `%llu` for `UInt`, `%lf` for `Double`; `\(x, specifier: "%.1f")` uses its own);
///   source text does not say the type of `x`, so any specifier matches an interpolation there;
/// - with at least one interpolation a literal `%` becomes `%%`; without, the key is the
///   literal as written;
/// - escapes (`\n`, `\"`, `\u{…}`) are decoded, multi-line `"""` literals lose their
///   indentation like the compiler does, calls may span lines and nest in interpolations;
/// - not checked (documented in docs/LOCALIZATION.md): a key that is not one literal
///   (a variable, a `+` expression, a ternary), a raw string `#"…"#`, and a call inside a
///   comment.
enum CodeKeys {
    enum Part: Equatable {
        case literal(String)
        case interpolation(specifier: String?)
    }

    struct Call: Equatable {
        var line: Int
        var parts: [Part]
    }

    static let callee = "L10n.string("

    /// Every `L10n.string(` call whose key is one string literal.
    static func calls(in source: String) -> [Call] {
        var lexer = Lexer(Array(source.unicodeScalars))
        lexer.scanCode(stopAtClosingParen: false)
        return lexer.calls
    }

    /// Whether a call's key is in the catalog's keys.
    static func isInCatalog(_ parts: [Part], keys: Set<String>) -> Bool {
        let hasInterpolation = parts.contains { if case .interpolation = $0 { return true } else { return false } }
        guard hasInterpolation else {
            let key = parts.map { if case .literal(let text) = $0 { return text } else { return "" } }.joined()
            return keys.contains(key)
        }
        // With arguments the runtime key writes a literal `%` as `%%`: compare escaped text.
        var code = skeleton(of: parts)
        code.literals = code.literals.map { $0.replacingOccurrences(of: "%", with: "%%") }
        return keys.contains { key in
            let catalog = skeleton(of: CatalogRules.tokens(of: key, keepingPercentEscapes: true))
            guard let catalog, catalog.literals == code.literals,
                  catalog.specifiers.count == code.specifiers.count else { return false }
            return zip(code.specifiers, catalog.specifiers).allSatisfy { wanted, found in
                guard found.position == nil else { return false }
                guard let wanted else { return true }
                return wanted == found.type
            }
        }
    }

    /// Literal runs and specifiers of a call, interpolations in order.
    private static func skeleton(of parts: [Part]) -> (literals: [String], specifiers: [String?]) {
        var literals = [""]
        var specifiers: [String?] = []
        for part in parts {
            switch part {
            case .literal(let text):
                literals[literals.count - 1] += text
            case .interpolation(let specifier):
                let type = specifier.flatMap { spec -> String? in
                    if case .specifier(_, let type)? = CatalogRules.tokens(of: spec).first { return type }
                    return nil
                }
                specifiers.append(type)
                literals.append("")
            }
        }
        return (literals, specifiers)
    }

    /// Literal runs and specifiers of a catalog key; nil when it has substitutions or `%arg`.
    private static func skeleton(of tokens: [CatalogRules.Token])
        -> (literals: [String], specifiers: [(position: Int?, type: String)])? {
        var literals = [""]
        var specifiers: [(position: Int?, type: String)] = []
        for token in tokens {
            switch token {
            case .literal(let text):
                literals[literals.count - 1] += text
            case .specifier(let position, let type):
                specifiers.append((position, type))
                literals.append("")
            case .substitution, .substitutionArgument:
                return nil
            }
        }
        return (literals, specifiers)
    }

    /// A small Swift lexer: enough to skip comments and string literals correctly and to read
    /// the literal right after `L10n.string(`.
    private struct Lexer {
        let s: [Unicode.Scalar]
        var i = 0
        var line = 1
        var calls: [Call] = []

        init(_ scalars: [Unicode.Scalar]) { s = scalars }

        func at(_ text: String, _ index: Int? = nil) -> Bool {
            var j = index ?? i
            for scalar in text.unicodeScalars {
                guard j < s.count, s[j] == scalar else { return false }
                j += 1
            }
            return true
        }

        mutating func advance(_ count: Int = 1) {
            for _ in 0..<count where i < s.count {
                if s[i] == "\n" { line += 1 }
                i += 1
            }
        }

        static func isIdentifier(_ c: Unicode.Scalar) -> Bool {
            c.properties.isAlphabetic || ("0"..."9").contains(c) || c == "_"
        }

        /// Code until the end, or until the `)` that closes an interpolation.
        mutating func scanCode(stopAtClosingParen: Bool) {
            var depth = 0
            while i < s.count {
                if at("//") {
                    while i < s.count, s[i] != "\n" { advance() }
                } else if at("/*") {
                    skipBlockComment()
                } else if s[i] == "#", rawStringStart() != nil {
                    skipRawString()
                } else if s[i] == "\"" {
                    _ = readStringLiteral()
                } else if at(CodeKeys.callee), i == 0 || !Self.isIdentifier(s[i - 1]) {
                    readCall()
                    depth += 1 // readCall consumed the call's `(`; its `)` comes later
                } else if s[i] == "(" {
                    depth += 1; advance()
                } else if s[i] == ")" {
                    if depth == 0, stopAtClosingParen { return }
                    depth -= 1; advance()
                } else {
                    advance()
                }
            }
        }

        mutating func skipBlockComment() {
            var depth = 0
            while i < s.count {
                if at("/*") { depth += 1; advance(2) } else if at("*/") {
                    depth -= 1; advance(2)
                    if depth == 0 { return }
                } else { advance() }
            }
        }

        mutating func skipTrivia() {
            while i < s.count {
                if s[i].properties.isWhitespace { advance() } else if at("//") {
                    while i < s.count, s[i] != "\n" { advance() }
                } else if at("/*") { skipBlockComment() } else { return }
            }
        }

        /// Number of `#` before a `"` at the cursor, if a raw string starts here.
        func rawStringStart() -> Int? {
            var j = i
            while j < s.count, s[j] == "#" { j += 1 }
            return j > i && j < s.count && s[j] == "\"" ? j - i : nil
        }

        /// Skips `#"…"#` / `#"""…"""#` (any number of `#`).
        mutating func skipRawString() {
            guard let hashes = rawStringStart() else { return }
            advance(hashes)
            let close = "\"" + String(repeating: "#", count: hashes)
            let multiline = at("\"\"\"")
            advance(multiline ? 3 : 1)
            let end = multiline ? "\"\"\"" + String(repeating: "#", count: hashes) : close
            while i < s.count, !at(end) { advance() }
            advance(end.unicodeScalars.count)
        }

        mutating func readCall() {
            let callLine = line
            advance(CodeKeys.callee.unicodeScalars.count)
            skipTrivia()
            guard i < s.count, s[i] == "\"" else { return } // not a literal key: skipped
            let parts = readStringLiteral()
            skipTrivia()
            // Only a key that is the literal alone ("a" + b is not a literal key).
            if i < s.count, s[i] == ")" || s[i] == "," { calls.append(Call(line: callLine, parts: parts)) }
        }

        /// Reads `"…"` or `"""…"""` at the cursor into literal text and interpolations.
        mutating func readStringLiteral() -> [Part] {
            if at("\"\"\"") { return readMultilineLiteral() }
            advance()
            var parts: [Part] = []
            var text = ""
            while i < s.count, s[i] != "\"", s[i] != "\n" {
                if s[i] == "\\" {
                    readEscape(into: &text, parts: &parts)
                } else {
                    text.unicodeScalars.append(s[i]); advance()
                }
            }
            advance()
            if !text.isEmpty { parts.append(.literal(text)) }
            return parts
        }

        /// `"""` literals: the closing delimiter's indentation is removed from every line, the
        /// newlines after the opening and before the closing delimiter are not part of the text,
        /// and a `\` at the end of a line joins it to the next.
        mutating func readMultilineLiteral() -> [Part] {
            advance(3)
            while i < s.count, s[i] != "\n" { advance() }
            advance()
            let indent = closingIndent()
            var parts: [Part] = []
            var text = ""
            var lineStart = true
            while i < s.count {
                if lineStart {
                    var skipped = 0
                    while skipped < indent, i < s.count, s[i] == " " || s[i] == "\t" { advance(); skipped += 1 }
                    lineStart = false
                    if at("\"\"\"") { advance(3); break }
                }
                if s[i] == "\\" {
                    var j = i + 1
                    while j < s.count, s[j] == " " || s[j] == "\t" { j += 1 }
                    if j < s.count, s[j] == "\n" {
                        advance(j - i + 1); lineStart = true
                        continue
                    }
                    readEscape(into: &text, parts: &parts)
                } else if s[i] == "\n" {
                    advance(); lineStart = true
                    var j = i
                    while j < s.count, s[j] == " " || s[j] == "\t" { j += 1 }
                    if !at("\"\"\"", j) { text += "\n" }
                } else {
                    text.unicodeScalars.append(s[i]); advance()
                }
            }
            if !text.isEmpty { parts.append(.literal(text)) }
            return parts
        }

        /// Indentation of the line that holds the closing `"""` (looking ahead, cursor unmoved).
        func closingIndent() -> Int {
            var j = i
            while j < s.count {
                var k = j
                while k < s.count, s[k] == " " || s[k] == "\t" { k += 1 }
                if at("\"\"\"", k) { return k - j }
                while j < s.count, s[j] != "\n" { j += 1 }
                j += 1
            }
            return 0
        }

        /// The escape at the cursor (a `\`): appends to `text`, or ends `text` and adds an
        /// interpolation part.
        mutating func readEscape(into text: inout String, parts: inout [Part]) {
            advance()
            guard i < s.count else { return }
            let c = s[i]
            switch c {
            case "(":
                if !text.isEmpty { parts.append(.literal(text)); text = "" }
                advance()
                let start = i
                scanCode(stopAtClosingParen: true)
                let expression = String(String.UnicodeScalarView(s[start..<min(i, s.count)]))
                advance() // the closing )
                parts.append(.interpolation(specifier: Self.specifier(in: expression)))
            case "n": text += "\n"; advance()
            case "t": text += "\t"; advance()
            case "r": text += "\r"; advance()
            case "0": text += "\0"; advance()
            case "u":
                advance()
                guard i < s.count, s[i] == "{" else { return }
                advance()
                var hex = ""
                while i < s.count, s[i] != "}" { hex.unicodeScalars.append(s[i]); advance() }
                advance()
                if let value = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(value) { text.unicodeScalars.append(scalar) }
            default:
                text.unicodeScalars.append(c); advance() // \\ \" \'
            }
        }

        /// `specifier: "%.1f"` in an interpolation, as in `\(size, specifier: "%.1f")`.
        static func specifier(in expression: String) -> String? {
            guard let label = expression.range(of: "specifier:") else { return nil }
            let rest = expression[label.upperBound...].drop { $0.isWhitespace }
            guard rest.first == "\"" else { return nil }
            let body = rest.dropFirst()
            guard let end = body.firstIndex(of: "\"") else { return nil }
            return String(body[..<end])
        }
    }
}
