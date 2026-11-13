// SPDX-License-Identifier: Apache-2.0
import AppKit
import Darwin
import XCTest

/// Screenshots of every M2, M3a, M3c and M3d screen at the design's 1100×720 pt window, in light and dark, with fixed
/// fake data that mirrors the FigCraft renders (`design/preview/screens`): the VM names, states and
/// resources of the renders, scripted fake VMs (`-NidoFakeStates`, DEBUG) and the wizard in fixed
/// states (`-NidoWizardFixture`, DEBUG). Each screenshot is an attachment named like its render
/// (e.g. `S01-Libreria-vuota-Chiaro`); `scripts/visual-check.sh --xcresult …` exports them to
/// `App/build/screens/` and compares them with the renders.
final class ScreenshotTests: XCTestCase, ScreenFixtures {
    private enum Appearance: String, CaseIterable {
        case light = "Chiaro"
        case dark = "Scuro"

        /// `-AppleInterfaceStyle Dark` forces dark; any other value forces light, whatever the Mac uses.
        var arguments: [String] { ["-AppleInterfaceStyle", self == .dark ? "Dark" : "Light"] }
    }

    private var scratch: URL!
    var root: URL!
    private var home: URL!
    var lockFDs: [Int32] = []

    override func setUpWithError() throws {
        continueAfterFailure = false
        // The wizard preselects ~/.ssh/id_ed25519.pub: a HOME of our own holds a valid one.
        (scratch, root, home) = try makeScreenScratch()
    }

    override func tearDownWithError() throws {
        releaseLocks()
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
    }

    // MARK: - S01

    @MainActor
    func testS01EmptyLibrary() throws {
        for appearance in Appearance.allCases {
            let app = launch(appearance)
            let window = libraryWindow(app)
            XCTAssertTrue(window.buttons["Crea VM"].waitForExistence(timeout: 10))
            capture(window, app: app, "S01-Libreria-vuota", appearance)
            app.terminate()
        }
    }

    @MainActor
    func testS01LibraryInEveryState() throws {
        try makeBundle("debian-13", cpu: 4, memoryGiB: 8, diskGiB: 64)
        try makeBundle("dev-box", cpu: 4, memoryGiB: 8, diskGiB: 128)
        try makeBundle("web-staging", cpu: 2, memoryGiB: 4, diskGiB: 32)
        try makeBundle("ci-runner", cpu: 2, memoryGiB: 4, diskGiB: 32)
        try makeBundle("sandbox", cpu: 2, memoryGiB: 2, diskGiB: 32)
        try makeBundle("test-arm", cpu: 4, memoryGiB: 8, diskGiB: 64)
        try makeBundle("vecchia-vm", config: Data("{ non è json".utf8))
        try makeBundle("archivio", cpu: 2, memoryGiB: 4, diskGiB: 32, suspended: true)
        for appearance in Appearance.allCases {
            // ci-runner is run by `nido start` in a Terminal: the lock is held by this process.
            try holdLock("ci-runner", owner: "cli")
            let app = launch(appearance, extra: [
                "-NidoFakeStates", "dev-box=starting,web-staging=running,sandbox=paused,test-arm=error",
            ])
            let window = libraryWindow(app)
            XCTAssertTrue(card("dev-box", in: window).staticTexts["Avvio in corso"].waitForExistence(timeout: 10))
            XCTAssertTrue(card("web-staging", in: window).staticTexts["In esecuzione"].waitForExistence(timeout: 10))
            XCTAssertTrue(card("ci-runner", in: window).staticTexts["In esecuzione (Terminale)"].waitForExistence(timeout: 10))
            XCTAssertTrue(card("sandbox", in: window).staticTexts["In pausa"].waitForExistence(timeout: 10))
            XCTAssertTrue(card("test-arm", in: window).staticTexts["Errore"].waitForExistence(timeout: 10))
            XCTAssertTrue(card("vecchia-vm", in: window).staticTexts["Illeggibile"].waitForExistence(timeout: 10))
            XCTAssertTrue(card("archivio", in: window).staticTexts["Sospesa"].waitForExistence(timeout: 10))
            XCTAssertTrue(card("archivio", in: window).buttons["Riprendi"].isEnabled)
            // The buttons of the render: Avvia disabled while starting, Riprendi, Riprova/Dettagli.
            XCTAssertFalse(card("dev-box", in: window).buttons["Avvia"].isEnabled)
            XCTAssertTrue(card("dev-box", in: window).buttons["Arresta"].isEnabled)
            XCTAssertTrue(card("sandbox", in: window).buttons["Riprendi"].isEnabled)
            XCTAssertTrue(card("sandbox", in: window).buttons["Arresta"].isEnabled)
            XCTAssertTrue(card("test-arm", in: window).buttons["Riprova"].isEnabled)
            XCTAssertTrue(card("test-arm", in: window).buttons["Dettagli"].isEnabled)
            capture(window, app: app, "S01-Libreria-VM-in-ogni-stato", appearance)

            // "Clona…" from the context menu of the stopped debian-13 (the sheet only: a copy of
            // the small fixture is instant, so "Copia in corso…" cannot be held for a screenshot).
            card("debian-13", in: window).staticTexts["4 CPU · 8 GiB di memoria · disco 64 GiB"].rightClick()
            let cloneItem = app.menuItems["Clona…"]
            XCTAssertTrue(cloneItem.waitForExistence(timeout: 5), "Manca Clona… nel menu della scheda")
            // Hover + Return instead of click(): after a click XCUITest looks for the item again in
            // the menu that just closed, which fails now and then.
            cloneItem.hover()
            app.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
            let cloneSheet = window.sheets.firstMatch
            XCTAssertTrue(cloneSheet.staticTexts["Clonare debian-13?"].waitForExistence(timeout: 5))
            capture(window, app: app, "S01-Libreria-Clona", appearance)
            cloneSheet.buttons["Annulla"].click()
            quit(app)
            releaseLocks()
        }
    }

    // MARK: - S02–S06

    @MainActor
    func testS02toS06Wizard() throws {
        let screens: [(fixture: String, name: String, marker: String)] = [
            ("system", "S02-Sistema", "Passo 1 di 5"),
            ("download-confirm", "S03-Download-conferma", "Origine"),
            ("download-progress", "S03-Download-avanzamento", "Download di Debian 13"),
            ("download-verify", "S03-Download-verifica", "Verifica dell'immagine"),
            ("download-checksum-error", "S03-Download-errore-checksum", "Download non riuscito"),
            ("resources", "S04-Risorse-valori", "Passo 3 di 5"),
            ("resources-over-limit", "S04-Risorse-fuori-limite", "Passo 3 di 5"),
            ("access", "S05-Accesso-e-software", "Chiave SSH pubblica"),
            ("summary", "S06-Riepilogo", "Passo 5 di 5"),
            ("creating", "S06-Creazione-in-corso", "Creazione di debian-13"),
            ("create-error", "S06-Creazione-errore", "Creazione non riuscita"),
        ]
        for appearance in Appearance.allCases {
            for screen in screens {
                let app = launch(appearance, extra: ["-NidoWizardFixture", screen.fixture])
                let window = libraryWindow(app)
                let wizard = app.descendants(matching: .any).matching(identifier: "wizard").firstMatch
                XCTAssertTrue(wizard.waitForExistence(timeout: 10), "La procedura non si è aperta (\(screen.fixture))")
                XCTAssertTrue(wizard.staticTexts[screen.marker].waitForExistence(timeout: 10),
                              "Manca \(screen.marker) in \(screen.name)")
                capture(window, app: app, screen.name, appearance)
                // The dialog on its own too: the native sheet is centred in the window, while the
                // design's dialog sits 64 pt below the top, so its content is compared separately.
                capture(wizard, app: app, screen.name, appearance, suffix: "-dialogo", checkSize: false)
                app.terminate()
            }
        }
    }

    /// The M3c variants of the wizard: from a template (two in the root), the RAM warning, Ollama
    /// after the first boot, the AI Starter and template summaries.
    @MainActor
    func testS02toS06WizardM3c() throws {
        let template = Self.templateConfig
        try makeBundle("debian-ai-base", cpu: 4, memoryGiB: 8, diskGiB: 64, extra: template)
        try makeBundle("debian-base", cpu: 2, memoryGiB: 2, diskGiB: 32, extra: template)
        let screens: [(fixture: String, name: String, marker: String)] = [
            ("system-template", "S02-Sistema-da-modello", "Passo 1 di 2"),
            ("resources-memory", "S04-Risorse-avviso-memoria", "Passo 3 di 5"),
            ("access-ollama", "S05-Accesso-e-software-Ollama", "Modello (facoltativo)"),
            ("summary-ai", "S06-Riepilogo-Debian-AI-Starter", "Passo 5 di 5"),
            ("summary-template", "S06-Riepilogo-da-modello", "Passo 2 di 2"),
        ]
        for appearance in Appearance.allCases {
            for screen in screens {
                let app = launch(appearance, extra: ["-NidoWizardFixture", screen.fixture])
                let window = libraryWindow(app)
                let wizard = app.descendants(matching: .any).matching(identifier: "wizard").firstMatch
                XCTAssertTrue(wizard.waitForExistence(timeout: 10), "La procedura non si è aperta (\(screen.fixture))")
                XCTAssertTrue(waitText(screen.marker, in: wizard, timeout: 10), "Manca \(screen.marker) in \(screen.name)")
                capture(window, app: app, screen.name, appearance)
                capture(wizard, app: app, screen.name, appearance, suffix: "-dialogo", checkSize: false)
                app.terminate()
            }
        }
    }

    /// The macOS path (M3b, ScreensMac.swift): S02–S06 macOS and the installing card of S01.
    @MainActor
    func testS02toS06WizardMac() throws {
        let screens: [(fixture: String, name: String, marker: String)] = [
            ("system-mac", "S02-Sistema-macOS", "Passo 1 di 5"),
            ("image-mac-empty", "S03-Immagine-macOS-nessun-file", "Nessun file scelto"),
            ("image-mac-checking", "S03-Immagine-macOS-controllo", "Controllo dell'immagine"),
            ("image-mac-compatible", "S03-Immagine-macOS-compatibile", "macOS 26.6 (25G62)"),
            ("image-mac-unsupported", "S03-Immagine-macOS-non-compatibile", "Passo 2 di 5"),
            ("resources-mac", "S04-Risorse-macOS", "Passo 3 di 5"),
            ("resources-mac-below-minimum", "S04-Risorse-macOS-sotto-il-minimo", "Passo 3 di 5"),
            ("access-mac", "S05-Accesso-macOS", "Nome utente in macOS"),
            ("summary-mac", "S06-Riepilogo-macOS", "Passo 5 di 5"),
            ("install-mac", "S06-Installazione-macOS-in-corso", "Installazione di macOS 26.6"),
            ("install-mac-cancel", "S06-Installazione-macOS-conferma-annullamento", "Installazione di macOS 26.6"),
            ("install-mac-error", "S06-Installazione-macOS-errore", "Installazione non riuscita"),
        ]
        for appearance in Appearance.allCases {
            for screen in screens {
                let app = launch(appearance, extra: ["-NidoWizardFixture", screen.fixture])
                let window = libraryWindow(app)
                let wizard = app.descendants(matching: .any).matching(identifier: "wizard").firstMatch
                XCTAssertTrue(wizard.waitForExistence(timeout: 10), "La procedura non si è aperta (\(screen.fixture))")
                XCTAssertTrue(waitText(screen.marker, in: wizard, timeout: 10), "Manca \(screen.marker) in \(screen.name)")
                capture(window, app: app, screen.name, appearance)
                capture(wizard, app: app, screen.name, appearance, suffix: "-dialogo", checkSize: false)
                app.terminate()
            }
            // S01: the wizard closed with "Continua nella libreria", the card keeps the progress.
            let app = launch(appearance, extra: ["-NidoWizardFixture", "library-mac-installing"])
            let window = libraryWindow(app)
            XCTAssertTrue(window.staticTexts["Installazione di macOS 26.6 · 42 % · circa 9 min"]
                .waitForExistence(timeout: 10))
            capture(window, app: app, "S01-Libreria-macOS-in-installazione", appearance)
            app.terminate()
        }
    }

    // MARK: - S07

    @MainActor
    func testS07VMWindowStates() throws {
        try makeBundle("debian-13", cpu: 4, memoryGiB: 8, diskGiB: 64)
        let screens: [(plan: String, name: String, state: String)] = [
            ("starting", "S07-Finestra-VM-avvio", "Avvio in corso"),
            ("running", "S07-Finestra-VM-in-esecuzione", "In esecuzione"),
            ("paused", "S07-Finestra-VM-in-pausa", "In pausa"),
            ("error", "S07-Finestra-VM-errore", "Errore"),
        ]
        for appearance in Appearance.allCases {
            for screen in screens {
                let app = launch(appearance, extra: ["-NidoFakeStates", "debian-13=\(screen.plan)"])
                let library = libraryWindow(app)
                let card = card("debian-13", in: library)
                // The VM was started at launch: its window opens from the card (Apri, Dettagli, or
                // a double click on a starting or paused card, whose buttons are Arresta and co.).
                switch screen.plan {
                case "running":
                    let open = card.buttons["Apri"]
                    XCTAssertTrue(open.waitForExistence(timeout: 10))
                    open.click()
                case "error":
                    XCTAssertTrue(card.staticTexts["Errore"].waitForExistence(timeout: 10))
                    XCTAssertTrue(card.buttons["Riprova"].exists)
                    card.buttons["Dettagli"].click()
                default:
                    let badge = screen.plan == "paused" ? "In pausa" : "Avvio in corso"
                    XCTAssertTrue(card.staticTexts[badge].waitForExistence(timeout: 10))
                    XCTAssertTrue(card.buttons[screen.plan == "paused" ? "Riprendi" : "Arresta"].exists)
                    card.staticTexts["4 CPU · 8 GiB di memoria · disco 64 GiB"].doubleClick()
                }
                let window = app.windows["debian-13"]
                XCTAssertTrue(window.waitForExistence(timeout: 10), "La finestra della VM non si è aperta")
                XCTAssertTrue(window.staticTexts[screen.state].waitForExistence(timeout: 10),
                              "Manca lo stato \(screen.state)")
                if screen.plan == "running" {
                    let terminal = window.descendants(matching: .any)["vm-terminal"]
                    XCTAssertTrue(waitForValue(of: terminal, containing: "debian-13 login:"), "Console: \(terminal.value ?? "")")
                }
                capture(window, app: app, screen.name, appearance)
                quit(app)
            }

            // Arrestata: run, then Arresta from the window's bar.
            let app = launch(appearance, extra: ["-NidoFakeStates", "debian-13=running"])
            let library = libraryWindow(app)
            let open = card("debian-13", in: library).buttons["Apri"]
            XCTAssertTrue(open.waitForExistence(timeout: 10))
            open.click()
            let window = app.windows["debian-13"]
            XCTAssertTrue(window.staticTexts["In esecuzione"].waitForExistence(timeout: 10))
            window.buttons["Arresta"].click()
            XCTAssertTrue(window.staticTexts["debian-13 è arrestata"].waitForExistence(timeout: 15))
            capture(window, app: app, "S07-Finestra-VM-arrestata", appearance)
            app.terminate()
        }
    }

    /// S07 sospesa: Sospendi from the bar of a running (fake) VM.
    @MainActor
    func testS07Suspended() throws {
        try makeBundle("debian-13", cpu: 4, memoryGiB: 8, diskGiB: 64)
        for appearance in Appearance.allCases {
            let app = launch(appearance, extra: ["-NidoFakeStates", "debian-13=running"])
            let open = card("debian-13", in: libraryWindow(app)).buttons["Apri"]
            XCTAssertTrue(open.waitForExistence(timeout: 10))
            open.click()
            let window = app.windows["debian-13"]
            XCTAssertTrue(window.staticTexts["In esecuzione"].waitForExistence(timeout: 10))
            window.buttons["Sospendi"].click()
            XCTAssertTrue(window.staticTexts["debian-13 è sospesa"].waitForExistence(timeout: 15))
            XCTAssertTrue(window.buttons["Riprendi"].exists)
            XCTAssertTrue(window.buttons["Snapshot"].exists)
            capture(window, app: app, "S07-Finestra-VM-sospesa", appearance)
            app.terminate()
        }
    }

    // MARK: - M3b macOS (S01 Clona, S07)

    /// S01 "Clona…" of a stopped macOS VM: the warning about the identity inside macOS, then the
    /// sheet of the finished clone with the guest steps. The other cards of the render (a running
    /// VM, an install in progress) are not in this fixture.
    @MainActor
    func testS01CloneMac() throws {
        try makeBundle("archivio", cpu: 2, memoryGiB: 4, diskGiB: 32, suspended: true)
        for appearance in Appearance.allCases {
            try makeMacBundle("macos-base", diskGiB: 64)
            try makeMacBundle("macos-agenti", diskGiB: 96)
            let app = launch(appearance)
            let window = libraryWindow(app)
            card("macos-base", in: window).staticTexts["4 CPU · 8 GiB di memoria · disco 64 GiB"].rightClick()
            let cloneItem = app.menuItems["Clona…"]
            XCTAssertTrue(cloneItem.waitForExistence(timeout: 5), "Manca Clona… nel menu della scheda")
            cloneItem.hover()
            app.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
            let sheet = window.sheets.firstMatch
            XCTAssertTrue(sheet.staticTexts["Clonare macos-base?"].waitForExistence(timeout: 5))
            capture(window, app: app, "S01-Libreria-Clona-macOS", appearance)
            sheet.buttons["Clona"].click()
            XCTAssertTrue(sheet.staticTexts["macos-base-copia è pronta"].waitForExistence(timeout: 20),
                          "Manca il riepilogo del clone macOS")
            capture(window, app: app, "S01-Libreria-Clona-macOS-completata", appearance)
            sheet.buttons["Fine"].click()
            app.terminate()
            for name in ["macos-base", "macos-base-copia", "macos-agenti"] {
                try? FileManager.default.removeItem(at: bundleURL(name))
            }
        }
    }

    /// S07 macOS with a fake session (`-NidoFakeSessions`): the screen is the empty background, the
    /// "Accesso da terminale" panel opens by itself (nido ssh never worked).
    @MainActor
    func testS07MacWindow() throws {
        try makeMacBundle("macos-agenti", diskGiB: 96)
        for appearance in Appearance.allCases {
            let app = launch(appearance, extra: ["-NidoFakeSessions"])
            card("macos-agenti", in: libraryWindow(app)).buttons["Avvia"].click()
            let window = app.windows["macos-agenti"]
            XCTAssertTrue(window.waitForExistence(timeout: 10), "La finestra della VM non si è aperta")
            XCTAssertTrue(window.staticTexts["In esecuzione"].waitForExistence(timeout: 10))
            let panel = element("terminal-access", in: window)
            XCTAssertTrue(panel.waitForExistence(timeout: 5), "Il pannello Accesso da terminale non si è aperto")
            capture(window, app: app, "S07-Finestra-macOS-Accesso-da-terminale", appearance)
            panel.buttons["terminal-access-close"].click()
            XCTAssertTrue(panel.waitForNonExistence(timeout: 5))
            capture(window, app: app, "S07-Finestra-macOS-in-esecuzione", appearance)
            quit(app)
        }
    }

    // MARK: - S09

    /// S09 with the VM stopped: no snapshot, then the list of the render, its two confirmation
    /// sheets and a failed create (the name is taken). Opened from S08 Generale.
    @MainActor
    func testS09SnapshotsStopped() throws {
        try makeBundle("debian-13", cpu: 4, memoryGiB: 8, diskGiB: 64, machineFiles: true)
        for appearance in Appearance.allCases {
            removeSnapshots("debian-13")
            var app = launch(appearance)
            var window = openSnapshotsFromSettings(app)
            XCTAssertTrue(window.descendants(matching: .any)["snapshots-empty"].waitForExistence(timeout: 10))
            capture(window, app: app, "S09-Snapshot-nessuno-snapshot", appearance)
            app.terminate()

            try makeSnapshot("debian-13", "installazione-pulita", "2026-10-22T09:15:00+02:00", savedState: false)
            try makeSnapshot("debian-13", "prima-dell-aggiornamento", "2026-10-24T10:42:00+02:00", savedState: true)
            try makeSnapshot("debian-13", "dopo-docker", "2026-10-24T16:05:00+02:00", savedState: true)
            app = launch(appearance)
            window = openSnapshotsFromSettings(app)
            XCTAssertTrue(window.staticTexts["dopo-docker"].waitForExistence(timeout: 10))
            capture(window, app: app, "S09-Snapshot-elenco", appearance)

            window.buttons["snapshot-restore-prima-dell-aggiornamento"].click()
            let restore = window.sheets.firstMatch
            XCTAssertTrue(restore.staticTexts["Ripristinare prima-dell-aggiornamento?"].waitForExistence(timeout: 5))
            capture(window, app: app, "S09-Snapshot-conferma-ripristino", appearance)
            restore.buttons["Annulla"].click()

            window.buttons["snapshot-delete-dopo-docker"].click()
            let delete = window.sheets.firstMatch
            XCTAssertTrue(delete.staticTexts["Eliminare dopo-docker?"].waitForExistence(timeout: 5))
            capture(window, app: app, "S09-Snapshot-conferma-eliminazione", appearance)
            delete.buttons["Annulla"].click()

            // A taken name: the create fails and the error panel says why.
            window.buttons["snapshot-create"].click()
            let name = window.sheets.firstMatch.textFields["snapshot-name"]
            XCTAssertTrue(name.waitForExistence(timeout: 5))
            name.doubleClick()
            name.typeKey("a", modifierFlags: .command)
            name.typeText("dopo-docker\r")
            XCTAssertTrue(window.descendants(matching: .any)["snapshots-error"].waitForExistence(timeout: 10))
            capture(window, app: app, "S09-Snapshot-errore", appearance)
            app.terminate()
        }
    }

    /// S09 with the VM running in the app (fake): the name sheet, then a live snapshot in progress
    /// (the fake session takes a few seconds to save its state). Opened from the VM window's bar.
    @MainActor
    func testS09SnapshotsRunning() throws {
        try makeBundle("debian-13", cpu: 4, memoryGiB: 8, diskGiB: 64, machineFiles: true)
        try makeSnapshot("debian-13", "installazione-pulita", "2026-10-22T09:15:00+02:00", savedState: false)
        try makeSnapshot("debian-13", "prima-dell-aggiornamento", "2026-10-24T10:42:00+02:00", savedState: true)
        try makeSnapshot("debian-13", "dopo-docker", "2026-10-24T16:05:00+02:00", savedState: true)
        for appearance in Appearance.allCases {
            let app = launch(appearance, extra: ["-NidoFakeStates", "debian-13=running"])
            let open = card("debian-13", in: libraryWindow(app)).buttons["Apri"]
            XCTAssertTrue(open.waitForExistence(timeout: 10))
            open.click()
            let vmWindow = app.windows["debian-13"]
            XCTAssertTrue(vmWindow.staticTexts["In esecuzione"].waitForExistence(timeout: 10))
            vmWindow.buttons["Snapshot"].click()
            let window = app.windows["Snapshot di debian-13"]
            XCTAssertTrue(window.waitForExistence(timeout: 10), "La finestra degli snapshot non si è aperta")
            window.buttons["snapshot-create"].click()
            let sheet = window.sheets.firstMatch
            XCTAssertTrue(sheet.textFields["snapshot-name"].waitForExistence(timeout: 5))
            XCTAssertEqual(sheet.textFields["snapshot-name"].value as? String, "snapshot-1")
            capture(window, app: app, "S09-Snapshot-nuovo-snapshot", appearance)
            sheet.buttons["Crea"].click()
            XCTAssertTrue(window.staticTexts["Creazione di snapshot-1"].waitForExistence(timeout: 5))
            capture(window, app: app, "S09-Snapshot-creazione-in-corso", appearance)
            // The row of the creating snapshot already shows its name: wait for the finished row,
            // so the quit does not have to wait for the save and the removal finds the snapshot.
            XCTAssertTrue(window.descendants(matching: .any)["snapshot-row-snapshot-1"].waitForExistence(timeout: 30))
            quit(app)
            removeSnapshot(named: "snapshot-1", of: "debian-13")
        }
    }

    // MARK: - S08, S10

    @MainActor
    func testS08SettingsStoppedAndRunning() throws {
        try makeBundle("debian-13", cpu: 4, memoryGiB: 8, diskGiB: 64)
        for appearance in Appearance.allCases {
            let app = launch(appearance, extra: ["-NidoFakeSessions"])
            let library = libraryWindow(app)
            let card = card("debian-13", in: library)
            card.buttons["Impostazioni"].click()
            let settings = app.windows["Impostazioni di debian-13"]
            XCTAssertTrue(settings.waitForExistence(timeout: 10), "Le impostazioni non si sono aperte")
            XCTAssertTrue(settings.staticTexts["CPU e memoria valgono dal prossimo avvio di debian-13."].exists)
            capture(settings, app: app, "S08-Impostazioni-VM-arrestata", appearance)

            // Start the VM from the library: the open settings lock themselves.
            library.click()
            card.buttons["Avvia"].click()
            let vmWindow = app.windows["debian-13"]
            XCTAssertTrue(vmWindow.staticTexts["In esecuzione"].waitForExistence(timeout: 10))
            XCTAssertTrue(settings.staticTexts["settings-locked-notice"].waitForExistence(timeout: 10))
            app.menuBars.menuBarItems["Finestra"].click()
            app.menuBars.menuItems["Impostazioni di debian-13"].click()
            capture(settings, app: app, "S08-Impostazioni-VM-in-esecuzione", appearance)
            quit(app)
        }
    }

    /// S08 Generale (snapshot summary) and Condivisione (two folders, one read-write, Rosetta on).
    /// The folders are /Users/Shared and /Applications (the render: /Users/anna/Progetti and
    /// /Volumes/Dati/dataset); they are only listed, never mounted.
    @MainActor
    func testS08GeneralAndSharing() throws {
        // Existing folders Nido allows to share (the sandboxed test runner cannot create any).
        let progetti = URL(fileURLWithPath: "/Users/Shared", isDirectory: true)
        let dataset = URL(fileURLWithPath: "/Applications", isDirectory: true)
        try makeBundle("debian-13", cpu: 4, memoryGiB: 8, diskGiB: 64, extra: [
            "schemaVersion": 2, "macAddress": "52:54:00:3a:9c:12", "rosetta": true,
            "guestMountsSharedFolders": true, "guestRegistersRosetta": true,
            "sharedFolders": [
                ["name": "progetti", "hostPath": progetti.path, "readOnly": true],
                ["name": "dataset", "hostPath": dataset.path, "readOnly": false],
            ],
        ])
        try makeSnapshot("debian-13", "installazione-pulita", "2026-10-22T09:15:00+02:00", savedState: false)
        try makeSnapshot("debian-13", "prima-dell-aggiornamento", "2026-10-24T10:42:00+02:00", savedState: true)
        try makeSnapshot("debian-13", "dopo-docker", "2026-10-24T16:05:00+02:00", savedState: true)
        for appearance in Appearance.allCases {
            let app = launch(appearance)
            card("debian-13", in: libraryWindow(app)).buttons["Impostazioni"].click()
            let settings = app.windows["Impostazioni di debian-13"]
            XCTAssertTrue(settings.waitForExistence(timeout: 10), "Le impostazioni non si sono aperte")
            settings.buttons["settings-section-Generale"].click()
            XCTAssertTrue(settings.buttons["Gestisci snapshot…"].waitForExistence(timeout: 5))
            capture(settings, app: app, "S08-Impostazioni-VM-generale", appearance)
            settings.buttons["settings-section-Condivisione"].click()
            XCTAssertTrue(settings.descendants(matching: .any)["share-row-dataset"].waitForExistence(timeout: 5))
            capture(settings, app: app, "S08-Impostazioni-VM-condivisione", appearance)
            app.terminate()
        }
    }

    @MainActor
    func testS10Preferences() throws {
        for appearance in Appearance.allCases {
            let app = launch(appearance)
            XCTAssertTrue(libraryWindow(app).exists)
            app.typeKey(",", modifierFlags: .command)
            let window = app.windows.matching(NSPredicate(format: "title != 'Nido'")).firstMatch
            XCTAssertTrue(window.waitForExistence(timeout: 10), "⌘, non apre le preferenze")
            XCTAssertTrue(window.staticTexts["Cartella delle VM"].waitForExistence(timeout: 5))
            capture(window, app: app, "S10-Preferenze", appearance)
            app.terminate()
        }
    }

    // MARK: - M3c (S01 modelli, S13 Monitor, S14 Preparazione, S15 AI, S10 Hugging Face)

    /// Launches with debian-ai running at once under a fake guest, opens its window on `tab`.
    @MainActor
    private func openAIWindow(_ appearance: Appearance, guest: String, tab: String) -> (XCUIApplication, XCUIElement) {
        let app = launch(appearance, extra: ["-NidoFakeStates", "debian-ai=running", "-NidoFakeGuest",
                                             "debian-ai=\(guest)", "-NidoFakeAIRouter"])
        let open = card("debian-ai", in: libraryWindow(app)).buttons["Apri"]
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        open.click()
        let window = app.windows["debian-ai"]
        XCTAssertTrue(window.staticTexts["In esecuzione"].waitForExistence(timeout: 10))
        if tab != "Schermo" { window.buttons["vm-tab-\(tab)"].click() }
        return (app, window)
    }

    @MainActor
    func testS13Monitor() throws {
        try makeAIBundle()
        let screens: [(guest: String, name: String, wait: String, delay: TimeInterval)] = [
            ("values", "S13-Monitor-valori", "protocollo 2.0", 0),
            ("alerts", "S13-Monitor-avvisi", "Disco quasi pieno", 0),
            ("waiting", "S13-Monitor-in-attesa", "In attesa del monitor del guest", 0),
            ("missing", "S13-Monitor-Guest-Tools-assenti", "Guest Tools non installati", 0),
            ("error", "S13-Monitor-errore", "Monitor non raggiungibile", 0),
            ("version", "S13-Monitor-versione-non-riconosciuta", "Versione dei Guest Tools non riconosciuta", 0),
            ("stale", "S13-Monitor-dati-vecchi", "Dati vecchi", 0),
            ("stops", "S13-Monitor-ultimo-campione", "Ultimo campione prima dell'arresto", 0),
        ]
        for appearance in Appearance.allCases {
            for screen in screens {
                let (app, window) = openAIWindow(appearance, guest: screen.guest, tab: "Monitor")
                XCTAssertTrue(waitText(screen.wait, in: window, timeout: 30), "\(screen.name): manca '\(screen.wait)'")
                capture(window, app: app, screen.name, appearance)
                quit(app)
            }
            // VM ferma: Arresta from the window, the Monitor tab then says so.
            let (app, window) = openAIWindow(appearance, guest: "values", tab: "Monitor")
            XCTAssertTrue(waitText("protocollo 2.0", in: window))
            window.buttons["Arresta"].click()
            XCTAssertTrue(waitText("La VM non è in esecuzione", in: window, timeout: 20))
            capture(window, app: app, "S13-Monitor-VM-ferma", appearance)
            app.terminate()
        }
    }

    @MainActor
    func testS14Provisioning() throws {
        let pending: [String: Any] = ["ollama": true, "model": "llama3.2:1b"]
        let screens: [(guest: String, name: String, wait: String, log: Bool)] = [
            ("waiting", "S14-Preparazione-fase-1", "Preparazione di debian-ai", false),
            ("values+phase2", "S14-Preparazione-fase-2", "46", false),
            ("values+phase2-fails", "S14-Preparazione-log", "nido-provision.log", true),
            ("values+phase2-done", "S14-Preparazione-completata", "debian-ai è pronta", false),
            ("values+phase2-fails", "S14-Preparazione-errore", "spazio insufficiente", false),
            ("values+ssh-key", "S14-Preparazione-chiave-SSH", "Terminale", false),
        ]
        for appearance in Appearance.allCases {
            for screen in screens {
                try? FileManager.default.removeItem(at: bundleURL("debian-ai"))
                try makeAIBundle(bridge: false, pending: pending)
                let (app, window) = openAIWindow(appearance, guest: screen.guest, tab: "Schermo")
                XCTAssertTrue(element("provisioning-panel", in: window).waitForExistence(timeout: 15),
                              "\(screen.name): manca il pannello della preparazione")
                if screen.log {
                    XCTAssertTrue(element("provisioning-log", in: window).waitForExistence(timeout: 15))
                    window.buttons["provisioning-log"].click()
                }
                XCTAssertTrue(waitText(screen.wait, in: window, timeout: 30), "\(screen.name): manca '\(screen.wait)'")
                capture(window, app: app, screen.name, appearance)
                quit(app)
            }
        }
    }

    @MainActor
    func testS15AI() throws {
        for appearance in Appearance.allCases {
            // Ollama assente e ponte spento.
            try? FileManager.default.removeItem(at: bundleURL("debian-ai"))
            try makeAIBundle(bridge: false)
            var (app, window) = openAIWindow(appearance, guest: "values", tab: "AI")
            XCTAssertTrue(window.buttons["ai-install-ollama"].waitForExistence(timeout: 15))
            XCTAssertTrue(window.buttons["ai-bridge-enable"].waitForExistence(timeout: 5))
            capture(window, app: app, "S15-AI-Ollama-assente-e-ponte-spento", appearance)
            // Avviso sulla privacy (first activation).
            window.buttons["ai-bridge-enable"].click()
            XCTAssertTrue(element("ai-bridge-privacy", in: app).waitForExistence(timeout: 5))
            capture(window, app: app, "S15-AI-avviso-privacy", appearance)
            app.buttons["confirm-cancel"].click()
            quit(app)

            // Modelli e limiti, the two confirmations, the catalog.
            try? FileManager.default.removeItem(at: bundleURL("debian-ai"))
            try makeAIBundle(logs: true)
            (app, window) = openAIWindow(appearance, guest: "values+ollama", tab: "AI")
            XCTAssertTrue(window.buttons["ai-remove-llama3.2:1b"].waitForExistence(timeout: 15))
            XCTAssertTrue(element("ai-bridge-allowed", in: window).waitForExistence(timeout: 10))
            capture(window, app: app, "S15-AI-modelli-e-limiti", appearance)
            window.buttons["ai-remove-llama3.2:1b"].click()
            XCTAssertTrue(app.buttons["confirm-action"].waitForExistence(timeout: 5))
            capture(window, app: app, "S15-AI-rimuovi-modello", appearance)
            app.buttons["confirm-cancel"].click()
            XCTAssertTrue(app.buttons["confirm-action"].waitForNonExistence(timeout: 5))
            window.buttons["ai-action-Disinstalla…"].click()
            XCTAssertTrue(app.buttons["confirm-action"].waitForExistence(timeout: 5))
            capture(window, app: app, "S15-AI-disinstalla-Ollama", appearance)
            app.buttons["confirm-cancel"].click()
            XCTAssertTrue(app.buttons["confirm-action"].waitForNonExistence(timeout: 5))
            window.buttons["ai-bridge-catalog"].click()
            XCTAssertTrue(element("ai-catalog-list", in: app).waitForExistence(timeout: 10))
            capture(window, app: app, "S15-AI-catalogo", appearance)
            app.buttons["confirm-cancel"].firstMatch.click()

            // Chat e registro.
            let mode = element("ai-locale-mode", in: window)
            segment("Chat", in: mode).click()
            let input = window.textFields["ai-chat-input"]
            XCTAssertTrue(input.waitForExistence(timeout: 5))
            input.click()
            input.typeText("Riassumi in tre punti cosa fa cloud-init al primo avvio.\r")
            XCTAssertTrue(waitText("Installa i pacchetti", in: window, timeout: 10))
            segment("Uso e registro", in: element("ai-remoto-mode", in: window)).click()
            XCTAssertTrue(element("ai-bridge-log", in: window).waitForExistence(timeout: 5))
            capture(window, app: app, "S15-AI-chat-e-registro", appearance)
            // The answer is Markdown (a numbered list); Interrompi stops it, then Copia copies
            // it as the model wrote it.
            XCTAssertTrue(element("ai-chat-answer", in: window).exists)
            window.buttons["ai-chat-stop"].click()
            let copy = window.buttons["ai-chat-copy"]
            XCTAssertTrue(copy.waitForExistence(timeout: 5))
            NSPasteboard.general.clearContents()
            copy.click()
            let copied = NSPasteboard.general.string(forType: .string) ?? ""
            XCTAssertTrue(copied.hasPrefix("1. Legge la configurazione"), copied)
            quit(app)

            // Ponte non disponibile in questa sessione.
            (app, window) = openAIWindow(appearance, guest: "values+ollama+no-bridge", tab: "AI")
            XCTAssertTrue(waitText("non è disponibile in questa sessione", in: window))
            capture(window, app: app, "S15-AI-ponte-non-disponibile", appearance)
            quit(app)
        }
    }

    /// S01 Modelli: two templates, debian-ai running with its bridge on, a suspended and a stopped VM;
    /// then "Salva come modello…" and "Modifica modello".
    @MainActor
    func testS01Templates() throws {
        try makeBundle("archivio", cpu: 2, memoryGiB: 4, diskGiB: 32, suspended: true)
        try makeAIBundle()
        try makeBundle("ricerca-01", cpu: 4, memoryGiB: 8, diskGiB: 64)
        let template = Self.templateConfig
        try makeBundle("debian-ai-base", cpu: 4, memoryGiB: 8, diskGiB: 64, extra: template)
        try makeBundle("debian-base", cpu: 2, memoryGiB: 2, diskGiB: 32, extra: template)
        for appearance in Appearance.allCases {
            let app = launch(appearance, extra: ["-NidoFakeStates", "debian-ai=running", "-NidoFakeGuest",
                                                 "debian-ai=values", "-NidoFakeAIRouter"])
            let window = libraryWindow(app)
            XCTAssertTrue(element("library-templates", in: window).waitForExistence(timeout: 10))
            XCTAssertTrue(card("debian-ai", in: window).staticTexts["In esecuzione"].waitForExistence(timeout: 10))
            XCTAssertTrue(waitText("Ponte AI attivo", in: card("debian-ai", in: window)))
            capture(window, app: app, "S01-Libreria-modelli-e-ponte-attivo", appearance)

            card("ricerca-01", in: window).staticTexts["4 CPU · 8 GiB di memoria · disco 64 GiB"].rightClick()
            let save = app.menuItems["Salva come modello…"]
            XCTAssertTrue(save.waitForExistence(timeout: 5), "Manca Salva come modello… nel menu della scheda")
            save.hover()
            app.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
            XCTAssertTrue(element("save-template-sheet", in: app).waitForExistence(timeout: 5))
            capture(window, app: app, "S01-Libreria-salva-come-modello", appearance)
            app.buttons["confirm-cancel"].firstMatch.click()

            card("debian-base", in: window).buttons["Modifica modello"].click()
            XCTAssertTrue(app.staticTexts["Modificare debian-base?"].waitForExistence(timeout: 5))
            capture(window, app: app, "S01-Libreria-modifica-modello", appearance)
            app.buttons["confirm-cancel"].firstMatch.click()
            quit(app)
        }
    }

    /// S10 Hugging Face: token saved (the fake store starts with one), replaced by an invalid value,
    /// removed.
    @MainActor
    func testS10HuggingFace() throws {
        for appearance in Appearance.allCases {
            let app = launch(appearance, extra: ["-NidoFakeAIRouter"])
            XCTAssertTrue(libraryWindow(app).exists)
            app.typeKey(",", modifierFlags: .command)
            let window = app.windows.matching(NSPredicate(format: "title != 'Nido'")).firstMatch
            XCTAssertTrue(window.waitForExistence(timeout: 10))
            window.buttons["settings-section-Hugging Face"].click()
            XCTAssertTrue(window.buttons["hf-token-replace"].waitForExistence(timeout: 5))
            capture(window, app: app, "S10-Preferenze-token-salvato", appearance)
            window.buttons["hf-token-remove"].click()
            let field = window.secureTextFields["hf-token-field"]
            XCTAssertTrue(field.waitForExistence(timeout: 5), "Manca il campo sicuro del token")
            capture(window, app: app, "S10-Preferenze-token-assente", appearance)
            field.click()
            field.typeText("non è un token")
            window.buttons["hf-token-save"].click()
            XCTAssertTrue(element("hf-token-error", in: window).waitForExistence(timeout: 5))
            capture(window, app: app, "S10-Preferenze-token-non-valido", appearance)
            app.terminate()
        }
    }

    /// S08 of a running VM: Condivisione (changes apply at once), Guest Tools (not installed),
    /// then the manual installer after an install that cannot reach the guest (no DHCP lease).
    @MainActor
    func testS08GuestToolsAndLiveSharing() throws {
        let key = home.appendingPathComponent(".ssh/id_ed25519.pub").path
        // A private key file next to it (never read by Nido, never used: no DHCP lease, so the
        // install stops at "non risponde via SSH" and offers the manual installer).
        XCTAssertTrue(FileManager.default.createFile(
            atPath: home.appendingPathComponent(".ssh/id_ed25519").path, contents: Data("segnaposto\n".utf8),
            attributes: [.posixPermissions: 0o600]))
        try makeBundle("debian-13", cpu: 4, memoryGiB: 4, diskGiB: 64,
                       extra: ["schemaVersion": 3, "guestMountsSharedFolders": true, "sshPublicKeyPath": key])
        for appearance in Appearance.allCases {
            let app = launch(appearance, extra: ["-NidoFakeSessions"])
            let library = libraryWindow(app)
            let card = card("debian-13", in: library)
            card.buttons["Impostazioni"].click()
            let settings = app.windows["Impostazioni di debian-13"]
            XCTAssertTrue(settings.waitForExistence(timeout: 10), "Le impostazioni non si sono aperte")
            library.click()
            card.buttons["Avvia"].click()
            XCTAssertTrue(app.windows["debian-13"].staticTexts["In esecuzione"].waitForExistence(timeout: 10))
            app.menuBars.menuBarItems["Finestra"].click()
            app.menuBars.menuItems["Impostazioni di debian-13"].click()
            settings.buttons["settings-section-Condivisione"].click()
            XCTAssertTrue(settings.buttons["share-add"].waitForExistence(timeout: 5))
            capture(settings, app: app, "S08-Impostazioni-VM-condivisione-a-VM-accesa", appearance)
            settings.buttons["settings-section-Guest Tools"].click()
            let install = settings.buttons["guest-tools-install"]
            XCTAssertTrue(install.waitForExistence(timeout: 5))
            capture(settings, app: app, "S08-Impostazioni-VM-Guest-Tools", appearance)
            install.click()
            XCTAssertTrue(element("guest-tools-manual", in: settings).waitForExistence(timeout: 60),
                          "Manca l'installazione manuale dopo un'installazione non riuscita")
            capture(settings, app: app, "S08-Impostazioni-VM-Guest-Tools-manuale", appearance)
            quit(app)
        }
    }

    // MARK: - M3d (S16 Rete, S08 Rete)

    /// S16: the Rete view of a VM window. Notifications are off (`-NidoNotifications denied`):
    /// new blocks show as a count on the Rete tab, then in the log with "Consenti" where a domain
    /// is named.
    @MainActor
    func testS16Network() throws {
        try makeNetworkBundle()
        for appearance in Appearance.allCases {
            let app = launch(appearance, extra: ["-NidoFakeStates", "debian-13=running", "-NidoNotifications", "denied"])
            let open = card("debian-13", in: libraryWindow(app)).buttons["Apri"]
            XCTAssertTrue(open.waitForExistence(timeout: 10))
            open.click()
            let window = app.windows["debian-13"]
            XCTAssertTrue(window.staticTexts["In esecuzione"].waitForExistence(timeout: 10))
            // Blocks after the app started watching: the count on the tab.
            appendEgress([
                (0, "name", "example.com", nil, 53, "udp", ["repeats": 2]),
                (0, "denyUnknown", nil, "198.51.100.23", 8443, "tcp", [:]),
                (0, "name", "telemetry.example.net", nil, 53, "udp", [:]),
            ], at: Date())
            XCTAssertTrue(waitForValue(of: window.buttons["vm-tab-Rete"], containing: "blocchi senza avviso", timeout: 15),
                          "Manca il contatore dei blocchi sulla scheda Rete")
            capture(window, app: app, "S16-Rete-contatore", appearance)
            window.buttons["vm-tab-Rete"].click()
            XCTAssertTrue(waitText("example.com:53", in: window))
            XCTAssertTrue(waitText("Le notifiche di Nido sono disattivate", in: window))
            capture(window, app: app, "S16-Rete-registro", appearance)
            // The switch sits at the row's trailing edge.
            element("network-blocked-only", in: window).coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).click()
            XCTAssertTrue(waitText("deb.debian.org:443", in: window))
            capture(window, app: app, "S16-Rete-registro-completo", appearance)
            quit(app)
        }
    }

    /// S08 Rete: the list of a controlled VM, the broad wildcard warning, and the switch of a VM
    /// on Apple's NAT with its explanation.
    @MainActor
    func testS08Network() throws {
        try makeNetworkBundle()
        for appearance in Appearance.allCases {
            let app = launch(appearance, extra: ["-NidoNotifications", "allowed", "-NidoFakeSessions"])
            card("debian-13", in: libraryWindow(app)).buttons["Impostazioni"].click()
            let settings = app.windows["Impostazioni di debian-13"]
            XCTAssertTrue(settings.waitForExistence(timeout: 10), "Le impostazioni non si sono aperte")
            settings.buttons["settings-section-Rete"].click()
            XCTAssertTrue(waitText("registry.ollama.ai", in: settings))
            capture(settings, app: app, "S08-Impostazioni-Rete", appearance)
            let field = element("network-new-domain", in: settings)
            field.click()
            field.typeText("*.co.uk")
            settings.buttons["network-add"].click()
            XCTAssertTrue(waitText("Aggiungere *.co.uk?", in: app))
            capture(settings, app: app, "S08-Impostazioni-Rete-avviso-jolly", appearance)
            app.buttons["confirm-cancel"].firstMatch.click()
            quit(app)
        }
        // A VM on Apple's NAT: the switch and what turning it on changes.
        try FileManager.default.removeItem(at: bundleURL("debian-13"))
        try makeNetworkBundle(controlled: false)
        try FileManager.default.removeItem(at: bundleURL("debian-13").appendingPathComponent("egress.json"))
        for appearance in Appearance.allCases {
            let app = launch(appearance, extra: ["-NidoNotifications", "allowed", "-NidoFakeSessions"])
            card("debian-13", in: libraryWindow(app)).buttons["Impostazioni"].click()
            let settings = app.windows["Impostazioni di debian-13"]
            XCTAssertTrue(settings.waitForExistence(timeout: 10), "Le impostazioni non si sono aperte")
            settings.buttons["settings-section-Rete"].click()
            XCTAssertTrue(waitText("La lista vale quando attivi la rete controllata", in: settings))
            capture(settings, app: app, "S08-Impostazioni-Rete-NAT", appearance)
            element("network-toggle", in: settings).coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).click()
            XCTAssertTrue(waitText("Attivare la rete controllata", in: app))
            capture(settings, app: app, "S08-Impostazioni-Rete-attiva", appearance)
            app.buttons["confirm-cancel"].firstMatch.click()
            quit(app)
        }
    }

    /// S08 Rete of a macOS VM (M3d): an existing VM on Apple's NAT, the switch's
    /// explanation for macOS (empty list, no Apple services), then the empty controlled list.
    @MainActor
    func testS08NetworkMac() throws {
        try makeMacBundle("macos-agenti", diskGiB: 96)
        for appearance in Appearance.allCases {
            let app = launch(appearance, extra: ["-NidoNotifications", "allowed", "-NidoFakeSessions"])
            card("macos-agenti", in: libraryWindow(app)).buttons["Impostazioni"].click()
            let settings = app.windows["Impostazioni di macos-agenti"]
            XCTAssertTrue(settings.waitForExistence(timeout: 10), "Le impostazioni non si sono aperte")
            settings.buttons["settings-section-Rete"].click()
            XCTAssertTrue(waitText("La lista vale quando attivi la rete controllata", in: settings))
            capture(settings, app: app, "S08-Impostazioni-Rete-macOS-NAT", appearance)
            element("network-toggle", in: settings).coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).click()
            XCTAssertTrue(waitText("Attivare la rete controllata", in: app))
            capture(settings, app: app, "S08-Impostazioni-Rete-macOS-attiva", appearance)
            app.buttons["confirm-cancel"].firstMatch.click()
            quit(app)
        }
        // A controlled macOS VM with its empty list.
        let config = bundleURL("macos-agenti").appendingPathComponent("config.json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: config)) as? [String: Any])
        json["schemaVersion"] = 5
        json["controlledNetwork"] = true
        try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]).write(to: config)
        for appearance in Appearance.allCases {
            let app = launch(appearance, extra: ["-NidoNotifications", "allowed", "-NidoFakeSessions"])
            card("macos-agenti", in: libraryWindow(app)).buttons["Impostazioni"].click()
            let settings = app.windows["Impostazioni di macos-agenti"]
            XCTAssertTrue(settings.waitForExistence(timeout: 10), "Le impostazioni non si sono aperte")
            settings.buttons["settings-section-Rete"].click()
            XCTAssertTrue(waitText("Nessun dominio permesso", in: settings))
            capture(settings, app: app, "S08-Impostazioni-Rete-macOS-controllata", appearance)
            quit(app)
        }
    }

    // MARK: - Helpers

    @MainActor
    private func launch(_ appearance: Appearance, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        // The design's 1100×720 window, whatever frame an earlier run saved in the defaults.
        app.launchArguments = ["-AppleLanguages", "(it)", "-AppleLocale", "it_IT", "-NidoRoot", root.path, "-ApplePersistenceIgnoreState", "YES",
                               "-NSWindow Frame library", "100 100 1100 720 0 0 1440 870"]
            + appearance.arguments + extra
        app.launchEnvironment["HOME"] = home.path
        app.launch()
        return app
    }

    /// Quits with live (fake) VMs: the quit alert, then the orderly stop.
    private func quit(_ app: XCUIApplication) {
        app.typeKey("q", modifierFlags: .command)
        let confirm = app.buttons["Arresta ed esci"].firstMatch
        if confirm.waitForExistence(timeout: 5) { confirm.click() }
        if !app.wait(for: .notRunning, timeout: 30) { app.terminate() }
    }

    /// The window's screenshot, named like its render. The pointer is parked outside the window and
    /// the animations get a moment to end first.
    private func capture(_ element: XCUIElement, app: XCUIApplication, _ name: String, _ appearance: Appearance,
                         suffix: String = "", checkSize: Bool = true) {
        app.activate()
        element.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
            .withOffset(CGVector(dx: -40, dy: -40)).hover()
        Thread.sleep(forTimeInterval: 1)
        let screenshot = element.screenshot()
        if checkSize {
            // 1100×720 pt, captured at 2× like the renders (`--scale 2`): 2200×1440 px.
            let frame = element.frame.size
            XCTAssertEqual(frame, CGSize(width: 1100, height: 720), "\(name): finestra di \(frame) pt")
            XCTAssertEqual(screenshot.image.size, CGSize(width: 2200, height: 1440),
                           "\(name): screenshot di \(screenshot.image.size) px")
        }
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "\(name)-\(appearance.rawValue)\(suffix)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// S08 → Generale → "Gestisci snapshot…": the S09 window of debian-13.
    @MainActor
    private func openSnapshotsFromSettings(_ app: XCUIApplication) -> XCUIElement {
        card("debian-13", in: libraryWindow(app)).buttons["Impostazioni"].click()
        let settings = app.windows["Impostazioni di debian-13"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10), "Le impostazioni non si sono aperte")
        settings.buttons["settings-section-Generale"].click()
        settings.buttons["Gestisci snapshot…"].click()
        let window = app.windows["Snapshot di debian-13"]
        XCTAssertTrue(window.waitForExistence(timeout: 10), "La finestra degli snapshot non si è aperta")
        return window
    }

}
