// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import Nido

/// Settings › General › Language: Nido's own `AppleLanguages`, the setting System Settings writes
/// for one app (Language & Region › Applications).
@Suite(.serialized)
struct AppLanguageSettingTests {
    private func makeDefaults() -> (UserDefaults, String) {
        let suite = "io.gitlab.pichierri.Nido.tests-language-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (defaults, suite)
    }

    @Test func withNothingSetNidoFollowsTheSystem() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(AppLanguageSetting(defaults: defaults, domain: suite).choice == nil)
    }

    @Test func choosingALanguageWritesOnlyThatLanguage() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        var setting = AppLanguageSetting(defaults: defaults, domain: suite)
        setting.choice = "de"
        #expect(defaults.persistentDomain(forName: suite)?["AppleLanguages"] as? [String] == ["de"])
        #expect(AppLanguageSetting(defaults: defaults, domain: suite).choice == "de")
    }

    @Test func theSystemChoiceRemovesTheKey() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        var setting = AppLanguageSetting(defaults: defaults, domain: suite)
        setting.choice = "fr"
        setting.choice = nil
        #expect(defaults.persistentDomain(forName: suite)?["AppleLanguages"] == nil)
        #expect(AppLanguageSetting(defaults: defaults, domain: suite).choice == nil)
    }

    /// System Settings may write a region ("it-IT"); a language Nido does not have reads as the system.
    @Test func aRegionReadsAsItsLanguageAndAnUnknownLanguageAsTheSystem() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["it-IT", "en"], forKey: "AppleLanguages")
        #expect(AppLanguageSetting(defaults: defaults, domain: suite).choice == "it")
        defaults.set(["ja"], forKey: "AppleLanguages")
        #expect(AppLanguageSetting(defaults: defaults, domain: suite).choice == nil)
    }

    /// Every language of the app, each named in itself.
    @Test func theLanguagesAreTheAppsOwnNamedInThemselves() {
        #expect(AppLanguageSetting.languages == ["en", "it", "de", "es", "fr"])
        #expect(AppLanguageSetting.languages.map(AppLanguageSetting.name) ==
            ["English", "Italiano", "Deutsch", "Español", "Français"])
        for language in AppLanguageSetting.languages where language != "en" {
            #expect(Bundle.main.localizations.contains(language), "no \(language).lproj")
        }
    }

    /// The helper waits for Nido's process to end, then opens the app: never before.
    @Test func theRelaunchWaitsForTheProcessToEnd() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("nido-relaunch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let opened = directory.appendingPathComponent("opened")

        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["1"]
        try sleeper.run()

        // `touch` stands in for `open`: the file appears when the helper "opens" the app.
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = Relauncher.arguments(pid: sleeper.processIdentifier, app: opened, open: "/usr/bin/touch")
        try helper.run()

        try await Task.sleep(for: .milliseconds(400))
        #expect(!FileManager.default.fileExists(atPath: opened.path), "opened before the process ended")
        sleeper.waitUntilExit()
        helper.waitUntilExit()
        #expect(helper.terminationStatus == 0)
        #expect(FileManager.default.fileExists(atPath: opened.path))
    }
}
