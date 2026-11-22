// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import NidoCLI
@testable import NidoCore

@Suite(.italian) struct ImageCommandTests {
    @Test func catalogImageIsLookedUpById() throws {
        #expect(try CLISupport.catalogImage(id: "ubuntu-24.04", architecture: .arm64) == CloudImageCatalog.ubuntu2404)
        #expect(try CLISupport.catalogImage(id: "ubuntu-24.04", architecture: .x86_64) == CloudImageCatalog.ubuntu2404Amd64)
        #expect(throws: CLIError.unknownImage("fedora")) { _ = try CLISupport.catalogImage(id: "fedora") }
    }

    @Test func listShowsEveryCatalogImageAndItsCache() {
        let lines = CLISupport.imageListLines([
            (CloudImageCatalog.debian13, false), (CloudImageCatalog.ubuntu2604, true),
        ])
        #expect(lines == [
            "ID            SISTEMA           CACHE",
            "debian-13     Debian 13         no",
            "ubuntu-26.04  Ubuntu 26.04 LTS  scaricata",
        ])
    }

    @Test func statusAndUpdateMessages() {
        let image = CloudImageCatalog.ubuntu2404
        #expect(CLISupport.imageStatusLine(image, status: .current) == "ubuntu-24.04: aggiornata")
        #expect(CLISupport.imageStatusLine(image, status: .updateAvailable)
            == "ubuntu-24.04: nuova build disponibile (nido image update ubuntu-24.04)")
        #expect(CLISupport.imageStatusLine(image, status: .notCached)
            == "ubuntu-24.04: non scaricata (la prossima VM scarica la build attuale)")
        #expect(CLISupport.imageUpdateMessage(image, status: .current) == "ubuntu-24.04: già aggiornata, niente da scaricare.")
        #expect(CLISupport.imageUpdateMessage(image, status: .updateAvailable)
            == "ubuntu-24.04: scaricata e verificata la build attuale. Le VM già create non cambiano.")
    }

    @Test func debianBuildIsShownAndResetSaysWhatItForgot() {
        let image = CloudImageCatalog.debian13
        #expect(CLISupport.imageStatusLine(image, status: .current, build: "20261103-2651")
            == "debian-13: aggiornata (build 20261103-2651)")
        #expect(CLISupport.imageStatusLine(image, status: .updateAvailable, build: "20261110-2700")
            == "debian-13: nuova build disponibile 20261110-2700 (nido image update debian-13)")
        #expect(CLISupport.imageUpdateMessage(image, status: .updateAvailable, build: "20261110-2700")
            == "debian-13: scaricata e verificata la build attuale (20261110-2700). Le VM già create non cambiano.")
        #expect(CLISupport.imageResetMessage(image, removed: 0) == "debian-13: nessuna build o firma accettata da dimenticare.")
        #expect(CLISupport.imageResetMessage(image, removed: 2).hasPrefix("debian-13: dimenticate la build e la firma"))
    }

    // MARK: nido image macos

    private let offer = MacImageOffer(
        build: "26B131", version: "27.2",
        url: URL(string: "https://updates.cdn-apple.com/UniversalMac_27.2_26B131_Restore.ipsw")!)

    @Test func macOfferLineAndQuestion() {
        #expect(CLISupport.macImageOfferLine(offer, size: nil) == "macOS 27.2 (26B131) — dimensione sconosciuta, da Apple")
        #expect(CLISupport.macImageOfferLine(offer, size: 18 << 30) == "macOS 27.2 (26B131) — 18 GiB, da Apple")
        #expect(CLISupport.macImageOfferLine(offer, size: 27_487_790_694) == "macOS 27.2 (26B131) — 25,6 GiB, da Apple")
        #expect(CLISupport.macImageDownloadQuestion(offer, size: 27_487_790_694) == "Scaricare macOS 27.2 (25,6 GiB) da Apple? [s/N] ")
        #expect(CLISupport.macImageDownloadQuestion(offer, size: 18 << 30) == "Scaricare macOS 27.2 (18 GiB) da Apple? [s/N] ")
        #expect(CLISupport.macImageDownloadQuestion(offer, size: nil) == "Scaricare macOS 27.2 (dimensione sconosciuta) da Apple? [s/N] ")
    }

    @Test func macStateLineSaysWhatTheCacheHolds() {
        #expect(CLISupport.macImageStateLine(path: "/c/a.ipsw", complete: false, partial: 0) == nil)
        #expect(CLISupport.macImageStateLine(path: "/c/a.ipsw", complete: true, partial: 0) == "Già scaricata: /c/a.ipsw")
        #expect(CLISupport.macImageStateLine(path: "/c/a.ipsw", complete: false, partial: 3 << 30)
            == "Download parziale: 3 GiB già in /c/a.ipsw; nido image macos --download lo riprende.")
    }

    @Test func macDownloadedLinesQuoteAPathWithSpaces() {
        #expect(CLISupport.macImageDownloadedLines(path: "/c/a.ipsw")[1] == "Usalo con: nido create <name> --ipsw /c/a.ipsw")
        #expect(CLISupport.macImageDownloadedLines(path: "/My Mac/a'b.ipsw")[1]
            == "Usalo con: nido create <name> --ipsw '/My Mac/a'\\''b.ipsw'")
        #expect(CLISupport.macImagePausedMessage() == "Download in pausa: esegui lo stesso comando per riprenderlo.")
    }

    @Test func macOptionsNeedDownload() throws {
        try CLISupport.validateMacImageOptions(download: false, hasOutput: false, yes: false)
        try CLISupport.validateMacImageOptions(download: true, hasOutput: true, yes: true)
        #expect(throws: CLIError.macImageOptionNeedsDownload("--output")) {
            try CLISupport.validateMacImageOptions(download: false, hasOutput: true, yes: false)
        }
        #expect(throws: CLIError.macImageOptionNeedsDownload("--yes")) {
            try CLISupport.validateMacImageOptions(download: false, hasOutput: false, yes: true)
        }
        #expect(CLIError.macImageOptionNeedsDownload("--output").errorDescription == "--output funziona solo con --download")
    }

    @Test func macFailureSaysResumeOnlyWhenAPartialFileIsThere() {
        let error = NidoError.insufficientSpace(needed: 2 << 30, available: 1 << 30)
        // Out of space before the first byte: no partial file, nothing to resume.
        #expect(CLISupport.macImageFailureLines(error: error, partial: 0) == nil)
        // A write error midway (or a lost connection) left bytes: same command resumes them.
        for error: any Error in [POSIXError(.ENOSPC), URLError(.badServerResponse), NidoError.hostNotAllowed("evil.com")] {
            let lines = CLISupport.macImageFailureLines(error: error, partial: 300 << 10)
            #expect(lines?.count == 2)
            #expect(lines?.first == "Errore: \(CLISupport.message(for: error))")
            #expect(lines?.last == "Download in pausa: esegui lo stesso comando per riprenderlo.")
        }
    }

    @Test func macOtherCacheFileIsOneLine() {
        #expect(CLISupport.macImageOtherFileLine(path: "/c/macos/.old.ipsw.part", bytes: 3 << 30)
            == "Anche nella cache di macOS: /c/macos/.old.ipsw.part (3 GiB)")
    }
}
