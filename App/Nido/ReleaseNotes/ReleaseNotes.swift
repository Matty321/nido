// SPDX-License-Identifier: Apache-2.0
import Foundation
import NidoCore

/// The release notes: CHANGELOG.md, one section per version, "## [0.3.0] – 2026-10-26", newest
/// first. The app has one per language (`<lang>.lproj/CHANGELOG.md`); the English one is a copy of
/// the repository's, and a test keeps them equal.
struct ReleaseNotes: Equatable {
    struct Release: Equatable, Identifiable {
        let version: String
        /// "October 26, 2026" in the app's language, or nil when the heading has no date.
        let date: String?
        /// The section's Markdown, without its heading.
        let body: String
        var id: String { version }
    }

    let releases: [Release]

    /// The notes bundled with the app, in the language the app runs in (English when the app
    /// has no notes in that language); empty if the file is missing.
    static func bundled(_ bundle: Bundle = .main) -> ReleaseNotes {
        guard let url = bundle.url(forResource: "CHANGELOG", withExtension: "md"),
            let text = try? String(contentsOf: url, encoding: .utf8)
        else { return ReleaseNotes(releases: []) }
        return parse(text)
    }

    /// The sections of `text`, with their dates written for `locale`.
    static func parse(_ text: String, locale: Locale = .current) -> ReleaseNotes {
        var releases: [Release] = []
        var current: (version: String, date: String?, lines: [Substring])?
        func close() {
            guard let section = current else { return }
            let body = section.lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            releases.append(Release(version: section.version, date: section.date, body: body))
        }
        for line in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            if let heading = sectionHeading(line) {
                close()
                current = (heading.version, localizedDate(heading.isoDate, locale: locale), [])
            } else {
                current?.lines.append(line)
            }
        }
        close()
        return ReleaseNotes(releases: releases)
    }

    /// "## [0.3.0] – 2026-10-26": the version and the date as written ("2026-10-26").
    private static func sectionHeading(_ line: Substring) -> (version: String, isoDate: String)? {
        guard line.hasPrefix("## ["), let close = line.firstIndex(of: "]") else { return nil }
        let version = String(line[line.index(line.startIndex, offsetBy: 4)..<close])
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ Int($0) != nil }) else { return nil }
        let rest = line[line.index(after: close)...].trimmingCharacters(in: CharacterSet(charactersIn: " –-"))
        return (version, rest)
    }

    /// "2026-10-26" as a long date for `locale` ("October 26, 2026", "26 ottobre 2026").
    private static func localizedDate(_ iso: String, locale: Locale) -> String? {
        let utc = TimeZone(identifier: "UTC") ?? .gmt
        guard let date = try? Date(iso, strategy: .iso8601.year().month().day().dateSeparator(.dash)) else {
            return nil
        }
        return date.formatted(
            Date.FormatStyle(date: .long, time: .omitted, timeZone: utc).locale(locale))
    }

    /// Whether `version` comes after `other` ("0.10.0" after "0.9.1"); malformed parts count as 0.
    static func isVersion(_ version: String, newerThan other: String) -> Bool {
        let parts = { (text: String) in text.split(separator: ".").map { Int($0) ?? 0 } }
        let left = parts(version), right = parts(other)
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a > b }
        }
        return false
    }
}

/// Which version's notes the user has seen. The notes open by themselves once per new version:
/// at the first launch after an update (or the first launch at all).
struct ReleaseNotesSeen {
    static let key = "NidoReleaseNotesSeenVersion"
    let defaults: UserDefaults

    func shouldShow(current: String = NidoVersion.current) -> Bool {
        guard let seen = defaults.string(forKey: Self.key) else { return true }
        return ReleaseNotes.isVersion(current, newerThan: seen)
    }

    func markSeen(_ version: String = NidoVersion.current) {
        defaults.set(version, forKey: Self.key)
    }
}
