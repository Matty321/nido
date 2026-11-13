// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing

/// NidoCore's String Catalog (shared by NidoCore, NidoCLI and `nido`) keeps the rules of
/// docs/LOCALIZATION.md: every key in all five languages, the same placeholders everywhere,
/// plural variations for counts, and every key the code looks up present. The rules live in
/// `CatalogRules.swift`, shared with the app's `AppCatalogTests`.
struct LocalizationCatalogTests {
    static let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let catalogURL = repository.appendingPathComponent("Sources/NidoCore/Resources/Localizable.xcstrings")

    static func catalog() throws -> CatalogRules.Catalog { try CatalogRules.load(catalogURL) }

    @Test func everyKeyHasAllLanguages() throws {
        let catalog = try Self.catalog()
        let problems = CatalogRules.formatProblems(catalog) + CatalogRules.missingLanguages(catalog)
        #expect(problems.isEmpty, "\(problems.joined(separator: "\n"))")
    }

    @Test func placeholdersMatch() throws {
        let problems = CatalogRules.placeholderMismatches(try Self.catalog())
        #expect(problems.isEmpty, "\(problems.joined(separator: "\n"))")
    }

    @Test func pluralKeysHaveVariations() throws {
        let problems = CatalogRules.pluralProblems(try Self.catalog())
        #expect(problems.isEmpty, "\(problems.joined(separator: "\n"))")
    }

    /// Every literal key passed to `L10n.string(` in `Sources/**` (NidoCore, NidoCLI, `nido`)
    /// is in the catalog, read the way Xcode extracts it (see `CodeKeys`).
    @Test func codeKeysExistInCatalog() throws {
        let keys = Set(try Self.catalog().strings.keys)
        let sources = Self.repository.appendingPathComponent("Sources")
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
        #expect(!files.isEmpty)
        var missing: [String] = []
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for call in CodeKeys.calls(in: source) where !CodeKeys.isInCatalog(call.parts, keys: keys) {
                let path = file.path.replacingOccurrences(of: Self.repository.path + "/", with: "")
                missing.append("\(path):\(call.line): \(Self.describe(call.parts))")
            }
        }
        #expect(missing.isEmpty, "keys missing from Localizable.xcstrings:\n\(missing.joined(separator: "\n"))")
    }

    static func describe(_ parts: [CodeKeys.Part]) -> String {
        parts.map {
            switch $0 {
            case .literal(let text): text.replacingOccurrences(of: "\n", with: "\\n")
            case .interpolation(let specifier): "\\(\(specifier ?? "…"))"
            }
        }.joined()
    }
}

/// The rules themselves, on small catalogs written here: each rule catches what it must, and
/// lets through what Xcode and the five languages legitimately do.
struct CatalogRulesTests {
    static func catalog(_ strings: String) throws -> CatalogRules.Catalog {
        let json = #"{ "sourceLanguage" : "en", "strings" : {"# + strings + #"}, "version" : "1.0" }"#
        return try JSONDecoder().decode(CatalogRules.Catalog.self, from: Data(json.utf8))
    }

    static func unit(_ value: String, _ state: String = "translated") -> String {
        #"{ "stringUnit" : { "state" : "\#(state)", "value" : "\#(value)" } }"#
    }

    static func plural(_ one: String, _ other: String) -> String {
        #"{ "variations" : { "plural" : { "one" : \#(unit(one)), "other" : \#(unit(other)) } } }"#
    }

    static func entry(_ key: String, _ languages: [String: String], comment: String? = nil) -> String {
        let body = languages.map { #""\#($0.key)" : \#($0.value)"# }.joined(separator: ", ")
        let note = comment.map { #""comment" : "\#($0)", "# } ?? ""
        return #""\#(key)" : { \#(note)"localizations" : { \#(body) } }"#
    }

    static func all(_ make: (String) -> String) -> [String: String] {
        Dictionary(uniqueKeysWithValues: ["it", "de", "es", "fr"].map { ($0, make($0)) })
    }

    @Test func completeEntryPasses() throws {
        let catalog = try Self.catalog(Self.entry("Cancel", Self.all { Self.unit("x-\($0)") }))
        #expect(CatalogRules.formatProblems(catalog).isEmpty)
        #expect(CatalogRules.missingLanguages(catalog).isEmpty)
        #expect(CatalogRules.placeholderMismatches(catalog).isEmpty)
        #expect(CatalogRules.pluralProblems(catalog).isEmpty)
    }

    @Test func missingEmptyOrUntranslatedLanguageIsCaught() throws {
        var languages = Self.all { Self.unit("x-\($0)") }
        languages["fr"] = nil
        #expect(CatalogRules.missingLanguages(try Self.catalog(Self.entry("Cancel", languages))) == [#""Cancel": no fr"#])
        languages["fr"] = Self.unit("")
        #expect(CatalogRules.missingLanguages(try Self.catalog(Self.entry("Cancel", languages))) == [#""Cancel": fr is empty"#])
        languages["fr"] = Self.unit("Annuler", "needs_review")
        #expect(CatalogRules.missingLanguages(try Self.catalog(Self.entry("Cancel", languages)))
            == [#""Cancel": fr is needs_review, not translated"#])
    }

    @Test func doNotTranslateEntriesAreSkipped() throws {
        let catalog = try Self.catalog(#""·" : { "shouldTranslate" : false }"#)
        #expect(CatalogRules.missingLanguages(catalog).isEmpty)
        #expect(CatalogRules.pluralProblems(catalog).isEmpty)
    }

    @Test func wrongFileFormatIsCaught() throws {
        let json = #"{ "sourceLanguage" : "it", "strings" : {}, "version" : "2.0" }"#
        let catalog = try JSONDecoder().decode(CatalogRules.Catalog.self, from: Data(json.utf8))
        #expect(CatalogRules.formatProblems(catalog).count == 2)
    }

    @Test func placeholdersMayMoveButNotChange() throws {
        var languages = Self.all { _ in Self.unit("%2$@ → %1$@") }
        let key = "Copy %@ to %@"
        #expect(CatalogRules.placeholderMismatches(try Self.catalog(Self.entry(key, languages))).isEmpty)
        languages["de"] = Self.unit("%@ nach")
        #expect(CatalogRules.placeholderMismatches(try Self.catalog(Self.entry(key, languages)))
            == [#""Copy %@ to %@": de has %1$@, the key has %1$@ %2$@"#])
        languages["de"] = Self.unit("%lld nach %@")
        #expect(CatalogRules.placeholderMismatches(try Self.catalog(Self.entry(key, languages))).count == 1)
        languages["de"] = Self.unit("100%% von %@ nach %@")
        #expect(CatalogRules.placeholderMismatches(try Self.catalog(Self.entry(key, languages))).isEmpty)
    }

    @Test func countsNeedPluralVariations() throws {
        let key = "%lld VMs"
        var languages = Self.all { _ in Self.plural("%lld VM", "%lld VM") }
        languages["en"] = Self.plural("%lld VM", "%lld VMs")
        #expect(CatalogRules.pluralProblems(try Self.catalog(Self.entry(key, languages))).isEmpty)
        #expect(CatalogRules.missingLanguages(try Self.catalog(Self.entry(key, languages))).isEmpty)
        #expect(CatalogRules.placeholderMismatches(try Self.catalog(Self.entry(key, languages))).isEmpty)

        // "One VM" without the number is a valid `one` case.
        languages["en"] = Self.plural("One VM", "%lld VMs")
        #expect(CatalogRules.placeholderMismatches(try Self.catalog(Self.entry(key, languages))).isEmpty)

        languages["es"] = Self.unit("%lld VM")
        #expect(CatalogRules.pluralProblems(try Self.catalog(Self.entry(key, languages)))
            == [#""%lld VMs": es needs plural variations (or [not a count] in the comment)"#])
        languages["es"] = #"{ "variations" : { "plural" : { "other" : \#(Self.unit("%lld VM")) } } }"#
        #expect(CatalogRules.pluralProblems(try Self.catalog(Self.entry(key, languages)))
            == [#""%lld VMs": es plural without one and other (other)"#])

        // English as the bare key cannot say "1 VMs" right.
        languages = Self.all { _ in Self.plural("%lld VM", "%lld VM") }
        #expect(CatalogRules.missingLanguages(try Self.catalog(Self.entry(key, languages))) == [#""%lld VMs": no en"#])
    }

    @Test func notACountOptsOut() throws {
        let languages = Self.all { _ in Self.unit("Porta %lld") }
        let plain = try Self.catalog(Self.entry("Port %lld", languages))
        #expect(CatalogRules.pluralProblems(plain).count == 5)
        let marked = try Self.catalog(Self.entry("Port %lld", languages, comment: "A TCP port. [not a count]"))
        #expect(CatalogRules.pluralProblems(marked).isEmpty)
    }

    @Test func substitutionsCountAsPluralsAndArguments() throws {
        let substituted = #"""
            { "stringUnit" : { "state" : "translated", "value" : "%#@vms@ in %@" },
              "substitutions" : { "vms" : { "argNum" : 1, "formatSpecifier" : "lld",
                "variations" : { "plural" : { "one" : \#(Self.unit("%arg VM")), "other" : \#(Self.unit("%arg VMs")) } } } } }
            """#
        var languages = Self.all { _ in substituted }
        languages["en"] = substituted
        let catalog = try Self.catalog(Self.entry("%lld VMs in %@", languages))
        #expect(CatalogRules.missingLanguages(catalog).isEmpty)
        #expect(CatalogRules.placeholderMismatches(catalog).isEmpty)
        #expect(CatalogRules.pluralProblems(catalog).isEmpty)
    }

    @Test func formatTokens() {
        #expect(CatalogRules.arguments(in: "%@ and %lld and %.1f, %llu").types == [1: "@", 2: "lld", 3: "f", 4: "llu"])
        #expect(CatalogRules.arguments(in: "%1$@ %1$lld").conflicts == [1])
        #expect(CatalogRules.arguments(in: "50% done").types.isEmpty)
        #expect(CatalogRules.arguments(in: "50%% of %@").types == [1: "@"])
        #expect(CatalogRules.arguments(in: "%2$@ %1$lld").types == [1: "lld", 2: "@"])
        #expect(CatalogRules.arguments(in: "%lf").types == CatalogRules.arguments(in: "%f").types)
    }
}

/// The scanner behind `codeKeysExistInCatalog`, on source text written here.
struct CodeKeysTests {
    @Test func literalKeys() {
        let source = #"""
            let a = L10n.string("Cancel")
            let b = L10n.string(
                "Error",
                language: "it")
            let c = L10n.string("Quote \" and \\ and \n and \u{2026}")
            """#
        #expect(CodeKeys.calls(in: source) == [
            .init(line: 1, parts: [.literal("Cancel")]),
            .init(line: 2, parts: [.literal("Error")]),
            .init(line: 5, parts: [.literal("Quote \" and \\ and \n and …")]),
        ])
    }

    @Test func interpolationsBecomeSpecifiers() {
        let source = #"""
            L10n.string("Delete \(name) (\(count) snapshots)?")
            L10n.string("\(size, specifier: "%.1f") GiB of \(L10n.string("total"))")
            L10n.string("50% of \(name)")
            """#
        let calls = CodeKeys.calls(in: source)
        // The call nested in an interpolation is found, and before the call around it.
        #expect(calls.map(\.line) == [1, 2, 2, 3])
        #expect(calls.first?.parts == [.literal("Delete "), .interpolation(specifier: nil), .literal(" ("),
                                       .interpolation(specifier: nil), .literal(" snapshots)?")])
        #expect(calls[1].parts == [.literal("total")])
        #expect(calls[2].parts == [.interpolation(specifier: "%.1f"), .literal(" GiB of "), .interpolation(specifier: nil)])
        #expect(calls[3].parts == [.literal("50% of "), .interpolation(specifier: nil)])

        let keys: Set = ["Delete %@ (%lld snapshots)?", "%.1f GiB of %@", "total", "50%% of %@"]
        #expect(calls.allSatisfy { CodeKeys.isInCatalog($0.parts, keys: keys) })
        #expect(!CodeKeys.isInCatalog(calls[0].parts, keys: ["Delete %@ (%lld snapshot)?"]))
        #expect(!CodeKeys.isInCatalog(calls[2].parts, keys: ["%lld GiB of %@"]))
        #expect(!CodeKeys.isInCatalog(calls[3].parts, keys: ["50% of %@"]))
        #expect(CodeKeys.isInCatalog([.literal("50% done")], keys: ["50% done"]))
    }

    @Test func multilineLiteral() {
        let source = "    L10n.string(\"\"\"\n        First line\n          indented \\\n        joined\n        \"\"\")\n"
        #expect(CodeKeys.calls(in: source) == [.init(line: 1, parts: [.literal("First line\n  indented joined")])])
    }

    @Test func skippedOnPurpose() {
        let source = #"""
            // L10n.string("in a comment")
            /* L10n.string("in a /* nested */ block") */
            let s = "L10n.string(\"inside a string\")"
            L10n.string(key)
            L10n.string("a" + b)
            L10n.string(#"raw"#)
            MyL10n.string("not ours")
            """#
        #expect(CodeKeys.calls(in: source).isEmpty)
    }
}
