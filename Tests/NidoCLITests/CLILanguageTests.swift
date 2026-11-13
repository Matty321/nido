// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import NidoCLI
@_spi(Testing) @testable import NidoCore

/// The language of the `nido` command. What depends on the process's language is checked on the
/// built executable, with `NIDO_LANGUAGE` in its environment: this test process stays pinned to
/// Italian (`ItalianCopy`) and never pins another language.
@Suite(.italian) struct CLILanguageTests {
    /// `nido` next to this test bundle (`swift build` puts both in the same products directory),
    /// with NidoCore's catalog beside it.
    static let nido: URL = Bundle(for: BundleToken.self).bundleURL
        .deletingLastPathComponent().appendingPathComponent("nido")

    struct Output {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    /// Runs `nido arguments` with `NIDO_LANGUAGE=language` and, when given, `NIDO_ROOT=root`.
    static func run(_ arguments: [String], language: String, root: URL? = nil) throws -> Output {
        try #require(
            FileManager.default.isExecutableFile(atPath: nido.path),
            "nido is not built next to the tests: \(nido.path)")
        var environment = ProcessInfo.processInfo.environment
        environment["NIDO_LANGUAGE"] = language
        environment["NIDO_ROOT"] = root?.path
        let process = Process()
        process.executableURL = nido
        process.arguments = arguments
        process.environment = environment
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        try process.run()
        // Read before waiting: a full pipe would otherwise block the child.
        let stdout = out.fileHandleForReading.readDataToEndOfFile()
        let stderr = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Output(
            status: process.terminationStatus, stdout: String(decoding: stdout, as: UTF8.self),
            stderr: String(decoding: stderr, as: UTF8.self))
    }

    /// A temporary NIDO_ROOT holding one stopped Linux VM, "debian".
    static func rootWithOneVM() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nido-cli-language-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let config = VMConfig(
            id: UUID(), name: try VMName("debian"), guest: .linux, cpuCount: 2,
            memoryBytes: 4 << 30, diskBytes: 20 << 30, macAddress: "02:00:00:00:00:01")
        _ = try VMBundle.create(config: config, paths: NidoPaths(root: root))
        return root
    }

    /// The offsets at which the header's columns start (two or more spaces end a column).
    static func columnStarts(_ header: String) -> [Int] {
        let characters = Array(header)
        var starts = [0]
        var index = 0
        while index < characters.count {
            if characters[index] == " ", index + 1 < characters.count, characters[index + 1] == " " {
                while index < characters.count, characters[index] == " " { index += 1 }
                starts.append(index)
            } else {
                index += 1
            }
        }
        return starts
    }

    @Test func envOverridesSystem() throws {
        let root = try Self.rootWithOneVM()
        defer { try? FileManager.default.removeItem(at: root) }

        let english = try Self.run(["list"], language: "en", root: root)
        #expect(english.status == 0, "\(english.stderr)")
        let englishLines = english.stdout.split(separator: "\n").map(String.init)
        #expect(englishLines.first?.split(separator: " ").map(String.init) == ["NAME", "STATE", "SYSTEM", "CPU", "MEMORY"])
        #expect(englishLines.last?.contains("stopped") == true)

        let italian = try Self.run(["list"], language: "it", root: root)
        #expect(italian.status == 0, "\(italian.stderr)")
        let italianLines = italian.stdout.split(separator: "\n").map(String.init)
        #expect(italianLines.first?.split(separator: " ").map(String.init) == ["NOME", "STATO", "SISTEMA", "CPU", "MEMORIA"])
        #expect(italianLines.last?.contains("ferma") == true)
    }

    /// Every column of `nido list` starts where its localized header does, in every language.
    @Test(arguments: ["en", "it", "de", "es", "fr"])
    func tablesStayAligned(language: String) throws {
        let root = try Self.rootWithOneVM()
        defer { try? FileManager.default.removeItem(at: root) }
        let output = try Self.run(["list"], language: language, root: root)
        let lines = output.stdout.split(separator: "\n").map(String.init)
        try #require(lines.count == 2, "\(output.stdout)\(output.stderr)")
        let starts = Self.columnStarts(lines[0])
        #expect(starts.count == 5, "\(lines[0])")
        let row = Array(lines[1])
        for start in starts.dropFirst() {
            #expect(start < row.count && row[start] != " " && row[start - 1] == " ", "\(lines[0])\n\(lines[1])")
        }
    }

    @Test func helpIsLocalized() throws {
        let german = try Self.run(["create", "--help"], language: "de")
        #expect(german.stdout.contains("Erstellt eine Linux-VM aus einem Cloud-Image"), "\(german.stdout)")
        #expect(german.stdout.contains("Name der VM."))
        let english = try Self.run(["create", "--help"], language: "en")
        #expect(english.stdout.contains("Create a Linux VM from a cloud image"), "\(english.stdout)")
        let italian = try Self.run(["--help"], language: "it")
        #expect(italian.stdout.contains("Nido: gestore di macchine virtuali per macOS."), "\(italian.stdout)")
        // ArgumentParser's own scaffolding stays English.
        #expect(german.stdout.contains("USAGE:"))
    }

    @Test func errorsAreLocalized() throws {
        let root = try Self.rootWithOneVM()
        defer { try? FileManager.default.removeItem(at: root) }
        let english = try Self.run(["delete", "missing", "--yes"], language: "en", root: root)
        #expect(english.status != 0)
        #expect(english.stderr.hasPrefix("Error: "), "\(english.stderr)")
        let french = try Self.run(["delete", "missing", "--yes"], language: "fr", root: root)
        #expect(french.stderr.hasPrefix("Erreur\u{00A0}: "), "\(french.stderr)")
        let italian = try Self.run(["delete", "missing", "--yes"], language: "it", root: root)
        #expect(italian.stderr.hasPrefix("Errore: "), "\(italian.stderr)")
    }

    /// German restores a snapshot with "wiederherstellen" (Restore), never "zurücksetzen"
    /// (Reset), and reorders the placeholders.
    @Test func germanRestoreReordersItsPlaceholders() {
        let (vm, snapshot, rest) = ("debian", "vor-update", "Spätere Änderungen gehen verloren.")
        #expect(L10n.string("Restore \(vm) to snapshot \(snapshot)? \(rest) [y/N] ", language: "de")
            == "Schnappschuss vor-update von debian wiederherstellen? Spätere Änderungen gehen verloren. [j/N] ")
        #expect(L10n.string("VM \(vm) restored to snapshot \(snapshot). \(rest)", language: "de")
            == "Schnappschuss vor-update von VM debian wiederhergestellt. Spätere Änderungen gehen verloren.")
        #expect(L10n.string("Restore \(vm) to snapshot \(snapshot)? \(rest) [y/N] ", language: "en")
            == "Restore debian to snapshot vor-update? Spätere Änderungen gehen verloren. [y/N] ")
    }

    @Test func confirmAcceptsLocalizedYes() {
        for language in ["en", "it", "de", "es", "fr"] {
            for yes in ["y", "yes", "Y", " YES "] {
                #expect(CLISupport.isAffirmative(yes, language: language), "\(language): \(yes)")
            }
            for no in ["", "n", "no", "N", "nein", "non"] {
                #expect(!CLISupport.isAffirmative(no, language: language), "\(language): \(no)")
            }
            #expect(!CLISupport.isAffirmative(nil, language: language))
        }
        for yes in ["s", "si", "sì", "Sì"] { #expect(CLISupport.isAffirmative(yes, language: "it")) }
        for yes in ["j", "ja", "Ja"] { #expect(CLISupport.isAffirmative(yes, language: "de")) }
        for yes in ["s", "si", "sí", "Sí"] { #expect(CLISupport.isAffirmative(yes, language: "es")) }
        for yes in ["o", "oui", "Oui"] { #expect(CLISupport.isAffirmative(yes, language: "fr")) }
        // Another language's yes is not taken for one.
        #expect(!CLISupport.isAffirmative("s", language: "en"))
        #expect(!CLISupport.isAffirmative("ja", language: "fr"))
        #expect(!CLISupport.isAffirmative("oui", language: "de"))
        // The process's language: Italian in this test process.
        #expect(CLISupport.isAffirmative("sì"))
    }

    /// Every question that ends with a `[y/N]`-style hint offers, in each language, a letter that
    /// language's confirmation accepts.
    @Test func promptsOfferTheLanguagesYes() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: repository.appendingPathComponent("Sources/NidoCore/Resources/Localizable.xcstrings"))
        let catalog = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try #require(catalog["strings"] as? [String: Any])
        let prompts = strings.keys.filter { $0.hasSuffix("[y/N] ") }.sorted()
        #expect(prompts.count >= 10)
        let hint = /\[(\w+)\/N\] $/
        for key in prompts {
            let localizations = (strings[key] as? [String: Any])?["localizations"] as? [String: Any] ?? [:]
            for language in ["en", "it", "de", "es", "fr"] {
                // The values as written (plural cases included); English is the key without an entry.
                let texts = localizations[language].map(Self.values(of:)) ?? (language == "en" ? [key] : [])
                #expect(!texts.isEmpty, "\(language): \(key)")
                for text in texts {
                    let letter = try #require(text.firstMatch(of: hint), "\(language): \(text)").1
                    #expect(CLISupport.isAffirmative(String(letter), language: language), "\(language): \(text)")
                }
            }
        }
    }

    /// Every `value` under a catalog localization (its string unit or its plural cases).
    static func values(of node: Any) -> [String] {
        guard let dictionary = node as? [String: Any] else { return [] }
        if let unit = dictionary["stringUnit"] as? [String: Any], let value = unit["value"] as? String { return [value] }
        return dictionary.values.flatMap(values(of:))
    }
}

private final class BundleToken {}
