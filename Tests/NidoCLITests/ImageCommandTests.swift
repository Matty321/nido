// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import NidoCLI
@testable import NidoCore

@Suite(.italian) struct ImageCommandTests {
    @Test func catalogImageIsLookedUpById() throws {
        #expect(try CLISupport.catalogImage(id: "ubuntu-24.04") == CloudImageCatalog.ubuntu2404)
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
}
