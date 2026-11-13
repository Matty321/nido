// SPDX-License-Identifier: Apache-2.0
import Foundation
import NidoCore
import Testing
@testable import Nido

struct ReleaseNotesTests {
    static let languages = ["en", "it", "de", "es", "fr"]

    /// The bundled CHANGELOG.md of one language (`<language>.lproj`), whatever language the tests run in.
    static func bundledChangelog(_ language: String) throws -> String {
        let url = try #require(
            Bundle.main.url(forResource: "CHANGELOG", withExtension: "md", subdirectory: nil, localization: language),
            "no \(language).lproj/CHANGELOG.md in the app")
        // Without a localized copy the lookup falls back to an unlocalized CHANGELOG.md.
        #expect(url.deletingLastPathComponent().lastPathComponent == "\(language).lproj",
                "CHANGELOG.md is not localized: \(url.path)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// The `## [x.y.z] – date` headings of a changelog, in order.
    static func headings(_ text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false).filter { $0.hasPrefix("## [") }.map(String.init)
    }

    /// Each release's outline: its `###` headings and `- ` bullets, in order ("H", "B"); the
    /// text is not compared, so every language can word it its own way.
    static func outline(_ release: ReleaseNotes.Release) -> [String] {
        release.body.split(separator: "\n").compactMap { line in
            line.hasPrefix("### ") ? "H" : line.hasPrefix("- ") ? "B" : nil
        }
    }

    /// One version everywhere: the app's MARKETING_VERSION, `nido --version` and the newest
    /// section of the changelog.
    @Test func versionAndChangelogAgree() throws {
        #expect(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String == NidoVersion.current)
        let notes = ReleaseNotes.bundled()
        #expect(notes.releases.first?.version == NidoVersion.current)
        #expect(notes.releases.first?.body.isEmpty == false)
    }

    /// The repository's CHANGELOG.md is the English notes; the app's `en.lproj` copy is the same file.
    @Test func bundledEnglishMatchesRoot() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let canonical = try String(contentsOf: repository.appendingPathComponent("CHANGELOG.md"), encoding: .utf8)
        #expect(try Self.bundledChangelog("en") == canonical,
                "App/Nido/ReleaseNotes/en.lproj/CHANGELOG.md must be a copy of CHANGELOG.md")
    }

    /// Every language has the same releases, with the same `## [x.y.z] – date` headings in the same
    /// order, each with notes and the same outline of `###` headings and bullets, and the notes are
    /// written in that language (not a copy of another).
    @Test func everyLanguageHasTheSameSections() throws {
        let english = try Self.bundledChangelog("en")
        let expected = Self.headings(english)
        #expect(expected.count >= 16)
        var texts: [String: String] = [:]
        for language in Self.languages {
            let text = try Self.bundledChangelog(language)
            texts[language] = text
            #expect(Self.headings(text) == expected, "\(language): the headings differ from en")
            let releases = ReleaseNotes.parse(text).releases
            #expect(releases.map(\.version) == ReleaseNotes.parse(english).releases.map(\.version))
            #expect(releases.allSatisfy { !$0.body.isEmpty }, "\(language): a release without notes")
            for (release, reference) in zip(releases, ReleaseNotes.parse(english).releases) {
                #expect(Self.outline(release) == Self.outline(reference),
                        "\(language) \(release.version): the ### headings and bullets differ from en")
            }
        }
        #expect(Set(texts.values).count == Self.languages.count, "two languages share the same notes")
    }

    /// Sparkle compares CFBundleVersion, so it must follow the version (0.7.6 is 706).
    @Test func buildNumberMatchesBundle() {
        #expect(Bundle.main.infoDictionary?["CFBundleVersion"] as? String == String(NidoVersion.build))
    }

    @Test func parsesSections() {
        let notes = ReleaseNotes.parse("""
            # Novità di Nido
            Introduzione.

            ## [1.10.0] – 2026-01-05
            ### Nuovo
            - uno

            ## [non una versione]
            ## [1.9.2]
            - due
            """)
        #expect(notes.releases == [
            ReleaseNotes.Release(version: "1.10.0", date: "5 gennaio 2026", body: "### Nuovo\n- uno\n\n## [non una versione]"),
            ReleaseNotes.Release(version: "1.9.2", date: nil, body: "- due"),
        ])
    }

    /// The dates follow the language of the notes, never a fixed Italian.
    @Test func datesFollowTheLocale() {
        let text = "## [1.0.0] – 2026-01-05\n- uno"
        #expect(ReleaseNotes.parse(text, locale: Locale(identifier: "en_US")).releases.first?.date == "January 5, 2026")
        #expect(ReleaseNotes.parse(text, locale: Locale(identifier: "de_DE")).releases.first?.date == "5. Januar 2026")
        #expect(ReleaseNotes.parse(text, locale: Locale(identifier: "fr_FR")).releases.first?.date == "5 janvier 2026")
        #expect(ReleaseNotes.parse(text, locale: Locale(identifier: "es_ES")).releases.first?.date == "5 de enero de 2026")
    }

    @Test func versionsCompareByNumber() {
        #expect(ReleaseNotes.isVersion("0.10.0", newerThan: "0.9.1"))
        #expect(ReleaseNotes.isVersion("1.0", newerThan: "0.99.99"))
        #expect(!ReleaseNotes.isVersion("0.3.0", newerThan: "0.3.0"))
        #expect(!ReleaseNotes.isVersion("0.3.0", newerThan: "0.3.1"))
        #expect(!ReleaseNotes.isVersion("0.3", newerThan: "0.3.0"))
    }

    /// The notes open once per new version: the first launch, after an update, never again for
    /// the same version, never after a downgrade.
    @Test func notesOpenOncePerVersion() throws {
        let suite = "nido-release-notes-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let seen = ReleaseNotesSeen(defaults: defaults)
        #expect(seen.shouldShow(current: "0.3.0"))
        seen.markSeen("0.3.0")
        #expect(!seen.shouldShow(current: "0.3.0"))
        #expect(seen.shouldShow(current: "0.3.1"))
        #expect(!seen.shouldShow(current: "0.2.0"))
    }
}
