// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@_spi(Testing) @testable import NidoCore

/// NidoError's descriptions in each language, through `localizedDescription(language:)` (never the
/// process-wide pin); `errorDescription` follows the pinned Italian.
@Suite(.italian) struct NidoErrorLocalizationTests {
    @Test func englishGermanItalian() {
        let error = NidoError.invalidName("x y")
        #expect(error.localizedDescription(language: "en")
            == "invalid VM name: “x y” (letters, digits, '.', '_', '-'; up to 63 characters)")
        #expect(error.localizedDescription(language: "de")
            == "ungültiger VM-Name: „x y“ (Buchstaben, Ziffern, '.', '_', '-'; höchstens 63 Zeichen)")
        #expect(error.localizedDescription(language: "it")
            == "nome VM non valido: \"x y\" (lettere, cifre, '.', '_', '-'; massimo 63 caratteri)")
        #expect(error.errorDescription == error.localizedDescription(language: "it"))
    }

    @Test func spanishAndFrench() {
        let error = NidoError.notRunning("debian")
        #expect(error.localizedDescription(language: "es") == "la VM debian no está en ejecución")
        #expect(error.localizedDescription(language: "fr") == "la VM debian n’est pas en marche")
    }

    /// A language outside the five gets English, never a key or Italian.
    @Test func otherLanguagesGetEnglish() {
        #expect(NidoError.downloadDeclined.localizedDescription(language: "ja") == "download canceled")
    }

    /// Sizes inside a sentence follow the language: decimal comma in Italian, point in English.
    @Test func sizesFollowTheLanguage() {
        let error = NidoError.insufficientSpace(needed: 3 << 29, available: 1 << 30)
        // The number format keeps the system's region, so English shows the machine's separator.
        let separator = L10n.locale(for: "en").decimalSeparator ?? "."
        #expect(error.localizedDescription(language: "en") == "not enough space: 1\(separator)5 GiB needed, 1 GiB available")
        #expect(error.localizedDescription(language: "it") == "spazio insufficiente: servono 1,5 GiB, disponibili 1 GiB")
    }

    /// A summary of what was left out agrees with its first count (pinned Italian).
    @Test func leftOutSummaryAgreesWithTheFirstCount() {
        func summary(_ blocks: Int, _ flows: Int) -> String? {
            EgressEvent(kind: .suppressed(blocks: blocks, flows: flows), proto: .other, ip: nil, port: nil).blockDescription
        }
        #expect(summary(2, 3) == "altri 2 blocchi e 3 flussi non mostrati")
        #expect(summary(1, 3) == "non mostrati: 1 blocco e 3 flussi")
        #expect(summary(1, 0) == "1 altro blocco non mostrato")
    }
}

/// Catalog entries that are more than a lookup: plural cases next to other arguments, reordered
/// arguments, French spacing. Checked through `L10n.string(_:language:)`, never the pin.
struct NidoCoreCopyTests {
    @Test func pluralNextToAnotherArgument() {
        let line = "blocked tcp"
        #expect(L10n.string("\(line) (seen \(1) more times before)", language: "en") == "blocked tcp (seen once before)")
        #expect(L10n.string("\(line) (seen \(4) more times before)", language: "en") == "blocked tcp (seen 4 more times before)")
        #expect(L10n.string("\(line) (seen \(1) more times before)", language: "it") == "blocked tcp (e un'altra volta prima)")
        #expect(L10n.string("\(line) (seen \(4) more times before)", language: "it") == "blocked tcp (e altre 4 volte prima)")
        #expect(L10n.string("\(line) (seen \(1) more times before)", language: "de") == "blocked tcp (und schon einmal zuvor)")
        #expect(L10n.string("\(line) (seen \(1) more times before)", language: "es") == "blocked tcp (y otra vez antes)")
    }

    @Test func germanReordersArguments() {
        let (destination, seconds) = ("1.2.3.4:443", "10")
        #expect(L10n.string("blocked \(2) more times to \(destination) in the last \(seconds) s", language: "de")
            == "in den letzten 10 s noch 2-mal zu 1.2.3.4:443 blockiert")
        #expect(L10n.string("blocked \(2) more times to \(destination) in the last \(seconds) s", language: "en")
            == "blocked 2 more times to 1.2.3.4:443 in the last 10 s")
    }

    /// German moves the resume error out of the sentence (it may start with a capital): the
    /// numbered placeholders still take each argument.
    @Test func germanMovesTheResumeErrorAfterTheSentence() {
        let error = NidoError.failedAndNotResumed("snapshot failed", resumeError: "Die VM antwortet nicht")
        #expect(error.localizedDescription(language: "de")
            == "snapshot failed; außerdem wurde die VM nicht fortgesetzt und ist angehalten. Grund: Die VM antwortet nicht")
        #expect(error.localizedDescription(language: "en")
            == "snapshot failed; also, the VM didn’t resume (Die VM antwortet nicht): it’s paused")
    }

    /// Spanish puts the count before the noun in the plural case, with numbered placeholders.
    @Test func spanishSnapshotsNotCopied() {
        let source = "debian"
        #expect(L10n.string("\(source)’s \(1) snapshots weren’t copied.", language: "es")
            == "La única instantánea de debian no se ha copiado.")
        #expect(L10n.string("\(source)’s \(3) snapshots weren’t copied.", language: "es")
            == "No se han copiado las 3 instantáneas de debian.")
    }

    /// A singular case that leaves the count out still places the other arguments right.
    @Test func spelledOutSingularKeepsTheOtherArguments() {
        let (destination, seconds) = ("1.2.3.4:443", "10")
        #expect(L10n.string("blocked \(1) more times to \(destination) in the last \(seconds) s", language: "de")
            == "in den letzten 10 s noch einmal zu 1.2.3.4:443 blockiert")
        #expect(L10n.string("blocked \(1) more times to \(destination) in the last \(seconds) s", language: "en")
            == "blocked once more to 1.2.3.4:443 in the last 10 s")
        #expect(L10n.string("blocked \(1) more times in the last \(seconds) s", language: "fr")
            == "bloqué une fois de plus au cours des 10 dernières secondes")
        #expect(L10n.string("blocked \(1) more times in the last \(seconds) s", language: "it")
            == "bloccato ancora 1 volta negli ultimi 10 s")
    }

    /// Lost-uplink reasons are stored as codes and shown in the language asked; older free text
    /// (Italian) is shown as it is.
    @Test func uplinkLossCodes() {
        #expect(UplinkLoss.text(UplinkLoss.signal(9), language: "en") == "gvproxy was stopped by signal 9")
        #expect(UplinkLoss.text(UplinkLoss.exit(137), language: "it") == "gvproxy si è chiuso (codice 137)")
        #expect(UplinkLoss.text(UplinkLoss.socketClosed, language: "de") == "Der Socket von gvproxy wurde geschlossen")
        #expect(UplinkLoss.text(UplinkLoss.socketUnresponsive, language: "fr") == "le socket de gvproxy ne répond plus")
        #expect(UplinkLoss.text("gvproxy è stato chiuso dal segnale 9", language: "en") == "gvproxy è stato chiuso dal segnale 9")
        #expect(UplinkLoss.text("gvproxy-exit:", language: "en") == "gvproxy-exit:")
    }

    /// French puts a no-break space before a colon.
    @Test func frenchSpacing() {
        #expect(NidoError.notFound("x").localizedDescription(language: "fr") == "introuvable\u{00A0}: x")
    }

    /// Italian keeps today's text, with singular forms where a count can be 1.
    @Test func italianSingulars() {
        #expect(L10n.string("\(1) more blocks not shown", language: "it") == "1 altro blocco non mostrato")
        #expect(L10n.string("\(5) more blocks not shown", language: "it") == "altri 5 blocchi non mostrati")
        #expect(L10n.string("\(5) more blocks not shown", language: "en") == "5 more blocks not shown")
    }
}
