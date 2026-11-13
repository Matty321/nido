// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@_spi(Testing) @testable import NidoCore

/// Language checks go through `L10n.string(_:language:)` and `L10n.locale(for:)`, which never touch the
/// process-wide pin, so they can run in parallel with every other suite. Only `L10nPinTests` moves the pin.
struct L10nTests {
    @Test func pinnedItalianReturnsItalian() {
        #expect(L10n.string("Error", language: "it") == "Errore")
        #expect(L10n.string("Error", language: "de") == "Fehler")
        #expect(L10n.string("Error", language: "es") == "Error")
        #expect(L10n.string("Error", language: "fr") == "Erreur")
        #expect(L10n.string("Error", language: "en") == "Error")
    }

    @Test func unsupportedLanguageFallsBackToEnglish() {
        #expect(L10n.resolve(env: [:], preferred: ["ja"]) == "en")
        #expect(L10n.resolve(env: [:], preferred: ["ja-JP", "zh-Hans"]) == "en")
        #expect(L10n.string("Error", language: "ja") == "Error")
        #expect(L10n.locale(for: "ja", region: nil).identifier == "en")
    }

    @Test func missingKeyReturnsKeyText() {
        #expect(L10n.string("No such key in the catalog", language: "it") == "No such key in the catalog")
        #expect(L10n.string("No such key in the catalog", language: "en") == "No such key in the catalog")
    }

    @Test func envOverridesSystem() {
        #expect(L10n.resolve(env: ["NIDO_LANGUAGE": "de"], preferred: ["it"]) == "de")
        #expect(L10n.resolve(env: ["NIDO_LANGUAGE": "xx"], preferred: ["it"]) == "it")
        #expect(L10n.resolve(env: ["NIDO_LANGUAGE": ""], preferred: ["fr-CA"]) == "fr")
        #expect(L10n.resolve(env: [:], preferred: ["es-ES", "it"]) == "es")
        #expect(L10n.resolve(env: [:], preferred: []) == "en")
    }

    @Test func envValueIsNormalized() {
        #expect(L10n.resolve(env: ["NIDO_LANGUAGE": "de_DE"], preferred: ["it"]) == "de")
        #expect(L10n.resolve(env: ["NIDO_LANGUAGE": "fr-CA"], preferred: ["it"]) == "fr")
        #expect(L10n.resolve(env: ["NIDO_LANGUAGE": "DE"], preferred: ["it"]) == "de")
        #expect(L10n.resolve(env: ["NIDO_LANGUAGE": "Es_mx"], preferred: ["it"]) == "es")
        #expect(L10n.resolve(env: ["NIDO_LANGUAGE": "pt-BR"], preferred: ["it"]) == "it")
        #expect(L10n.resolve(env: ["NIDO_LANGUAGE": "-"], preferred: ["it"]) == "it")
    }

    @Test func regionVariantsResolveToTheirLanguage() {
        #expect(L10n.resolve(env: [:], preferred: ["de-CH"]) == "de")
        #expect(L10n.resolve(env: [:], preferred: ["es-MX"]) == "es")
        #expect(L10n.resolve(env: [:], preferred: ["es-419"]) == "es")
        #expect(L10n.resolve(env: [:], preferred: ["fr-CA"]) == "fr")
        #expect(L10n.resolve(env: [:], preferred: ["pt-BR"]) == "en")
        #expect(L10n.resolve(env: [:], preferred: ["ja"]) == "en")
    }

    @Test func localeKeepsTheSystemRegion() {
        #expect(L10n.locale(for: "en", region: "IT").decimalSeparator == ",")
        #expect(L10n.locale(for: "en", region: "US").decimalSeparator == ".")
        #expect(L10n.locale(for: "de", region: "CH").identifier == "de_CH")
        #expect(L10n.locale(for: "ja", region: "IT").identifier == "en_IT")
        #expect(L10n.locale(for: "fr", region: nil).identifier == "fr")
        #expect(L10n.locale(for: "fr", region: "").identifier == "fr")
    }

    @Test func localeFollowsLanguage() {
        #expect(L10n.locale(for: "fr", region: nil).identifier == "fr")
        #expect(L10n.locale(for: "it", region: nil).identifier == "it")
    }

    /// The real catalog is found by `swift test` (it ships beside the test bundle, not in Bundle.main).
    @Test func catalogBundleIsFound() {
        #expect(L10n.catalogBundle != Bundle.main)
        #expect(L10n.catalogBundle.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: "it") != nil)
    }
}

/// The one suite that moves the process-wide pin. It pins only Italian, the language the whole NidoCore and
/// NidoCLI test process is pinned to once later tasks localize NidoCore's text, so suites running in
/// parallel never see another language; it puts back the pin it found. `.serialized` keeps any future
/// test of this suite from overlapping it. Other languages are checked through `string(_:language:)`.
@Suite(.serialized) struct L10nPinTests {
    @Test func pinnedLanguageDrivesStringAndLocale() {
        let previous = L10n.pinned
        defer { L10n.pin(previous) }

        L10n.pin("it")
        #expect(L10n.pinned == "it")
        #expect(L10n.language == "it")
        #expect(L10n.locale.language.languageCode?.identifier == "it")
        #expect(L10n.string("Error") == "Errore")
    }
}
