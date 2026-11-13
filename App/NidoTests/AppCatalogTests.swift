// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing

/// The app's String Catalogs keep the rules of docs/LOCALIZATION.md: every key in all five
/// languages, the same placeholders everywhere, plural variations for counts. The rules are
/// `CatalogRules` (Tests/NidoCoreTests/CatalogRules.swift, compiled into this target too), the
/// same ones NidoCore's catalog keeps. The catalogs are read from the repository, as Xcode keeps them.
struct AppCatalogTests {
    static let appDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Nido")

    /// Localizable.xcstrings (the code's copy) and InfoPlist.xcstrings (Info.plist's copyright).
    static let catalogNames = ["Localizable", "InfoPlist"]

    static func catalog(_ name: String) throws -> CatalogRules.Catalog {
        try CatalogRules.load(appDirectory.appendingPathComponent("\(name).xcstrings"))
    }

    @Test(arguments: catalogNames) func everyKeyHasAllLanguages(_ name: String) throws {
        let catalog = try Self.catalog(name)
        let problems = CatalogRules.formatProblems(catalog) + CatalogRules.missingLanguages(catalog)
        #expect(problems.isEmpty, "\(name): \(problems.joined(separator: "\n"))")
    }

    @Test(arguments: catalogNames) func placeholdersMatch(_ name: String) throws {
        let problems = CatalogRules.placeholderMismatches(try Self.catalog(name))
        #expect(problems.isEmpty, "\(name): \(problems.joined(separator: "\n"))")
    }

    @Test(arguments: catalogNames) func pluralKeysHaveVariations(_ name: String) throws {
        let problems = CatalogRules.pluralProblems(try Self.catalog(name))
        #expect(problems.isEmpty, "\(name): \(problems.joined(separator: "\n"))")
    }

    // MARK: - Keys the code uses

    /// The parts of App/Nido whose copy is English keys (paths relative to App/Nido; a folder ends
    /// with "/"). Every key the compiler extracts from them must be in Localizable.xcstrings. Each
    /// area joins the list when it is localized; the rest is not localized yet and holds literals the
    /// catalog does not list (docs/LOCALIZATION.md, "The app's catalog and Xcode").
    static let localizedSources = [
        "AI/",
        "AppDelegate.swift",
        "CommandLinkCommands.swift",
        "Design/Components/",
        "Library/",
        "Monitor/",
        "Network/",
        "NidoApp.swift",
        "Provisioning/",
        // ReleaseNotes.swift (the CHANGELOG's parser and its dates) is localized separately.
        "ReleaseNotes/ReleaseNotesView.swift",
        "Settings/",
        "Snapshots/",
        "Updates/",
        "VMWindow/",
        "Wizard/",
    ]

    /// One key the compiler extracted (`SWIFT_EMIT_LOC_STRINGS`): a `.stringsdata` file per source
    /// file, next to the app's object files.
    struct ExtractedKey: Hashable {
        let key: String
        let source: String
        let line: Int
    }

    private struct StringsData: Decodable {
        struct Entry: Decodable {
            struct Location: Decodable { let startingLine: Int? }
            let key: String
            let location: Location?
        }

        let source: String
        let tables: [String: [Entry]]
    }

    /// The app's `Objects-normal/<arch>` folders in this build's derived data, found from the app
    /// that hosts the tests (`Build/Products/<configuration>/Nido.app`).
    static func objectDirectories() -> [URL] {
        let app = Bundle.main.bundleURL
        let configuration = app.deletingLastPathComponent().lastPathComponent
        let build = app.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let objects = build.appendingPathComponent(
            "Intermediates.noindex/Nido.build/\(configuration)/Nido.build/Objects-normal")
        let architectures = (try? FileManager.default.contentsOfDirectory(
            at: objects, includingPropertiesForKeys: nil)) ?? []
        return architectures.filter { $0.hasDirectoryPath }
    }

    /// What the compiler extracted: the keys, and every source file it compiled (a file without
    /// copy has a `.stringsdata` too). A `.stringsdata` whose source file is gone is left over from
    /// an earlier build (incremental derived data) and is skipped.
    struct Extraction {
        var keys: [ExtractedKey] = []
        var sources: Set<String> = []
    }

    static func extraction() throws -> Extraction {
        var keys: Set<ExtractedKey> = []
        var sources: Set<String> = []
        for directory in objectDirectories() {
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            for file in files where file.pathExtension == "stringsdata" {
                let data = try JSONDecoder().decode(StringsData.self, from: Data(contentsOf: file))
                guard FileManager.default.fileExists(atPath: data.source) else { continue }
                sources.insert(data.source)
                for entry in data.tables["Localizable"] ?? [] {
                    keys.insert(ExtractedKey(key: entry.key, source: data.source, line: entry.location?.startingLine ?? 0))
                }
            }
        }
        return Extraction(
            keys: keys.sorted { ($0.source, $0.line, $0.key) < ($1.source, $1.line, $1.key) }, sources: sources)
    }

    /// `source` relative to App/Nido, or nil outside it.
    static func relativePath(_ source: String) -> String? {
        let root = appDirectory.standardizedFileURL.path + "/"
        return source.hasPrefix(root) ? String(source.dropFirst(root.count)) : nil
    }

    static func matches(_ entry: String, _ relative: String) -> Bool {
        entry.hasSuffix("/") ? relative.hasPrefix(entry) : relative == entry
    }

    static func isLocalized(source: String) -> Bool {
        guard let relative = relativePath(source) else { return false }
        return localizedSources.contains { matches($0, relative) }
    }

    /// Each entry of `localizedSources` names files the compiler built: a typo or a renamed file
    /// would otherwise check nothing and pass.
    @Test func localizedSourcesExist() throws {
        let compiled = try Self.extraction().sources.compactMap(Self.relativePath)
        #expect(!compiled.isEmpty,
                "No .stringsdata next to the app's objects: build with SWIFT_EMIT_LOC_STRINGS = YES")
        let unmatched = Self.localizedSources.filter { entry in !compiled.contains { Self.matches(entry, $0) } }
        #expect(unmatched.isEmpty, "localizedSources entries that match no compiled file: \(unmatched)")
    }

    /// Every entry of the catalog is a key some code of the app uses: an entry no code looks up
    /// any more is dead (Xcode would mark it stale) and is deleted.
    @Test func catalogKeysAreUsed() throws {
        let used = Set(try Self.extraction().keys.map(\.key))
        #expect(!used.isEmpty,
                "No .stringsdata next to the app's objects: build with SWIFT_EMIT_LOC_STRINGS = YES")
        let unused = try Self.catalog("Localizable").strings.keys.filter { !used.contains($0) }.sorted()
        #expect(unused.isEmpty, "Entries no code uses:\n\(unused.joined(separator: "\n"))")
    }

    /// Every key that English code passes to SwiftUI or `String(localized:)` has its entry: a key
    /// without one would show English in every language.
    @Test func extractedKeysExistInCatalog() throws {
        let extracted = try Self.extraction().keys
        #expect(!extracted.isEmpty,
                "No .stringsdata next to the app's objects: build with SWIFT_EMIT_LOC_STRINGS = YES")
        let keys = Set(try Self.catalog("Localizable").strings.keys)
        let missing = extracted.filter { Self.isLocalized(source: $0.source) && !keys.contains($0.key) }
        #expect(missing.isEmpty, """
            Keys missing from App/Nido/Localizable.xcstrings:
            \(missing.map { "\($0.source):\($0.line): \($0.key)" }.joined(separator: "\n"))
            """)
    }
}
