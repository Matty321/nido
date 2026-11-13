// SPDX-License-Identifier: Apache-2.0
import Darwin
import XCTest

/// The VM settings (S08) and the preferences (S10).
final class SettingsTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nido-settings-ui-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    @MainActor
    func testChangeCPUAndSaveWritesConfig() throws {
        try makeBundle("debian-13")
        let app = launch()
        defer { app.terminate() }

        let library = app.windows["Nido"]
        XCTAssertTrue(library.waitForExistence(timeout: 10))
        card("debian-13", in: library).buttons["Impostazioni"].click()

        let window = app.windows["Impostazioni di debian-13"]
        XCTAssertTrue(window.waitForExistence(timeout: 10), "Le impostazioni non si sono aperte")
        XCTAssertTrue(window.staticTexts["CPU e memoria valgono dal prossimo avvio di debian-13."].exists)
        let save = window.buttons["settings-save"]
        XCTAssertFalse(save.isEnabled, "Salva deve essere disattivato senza modifiche")
        XCTAssertFalse(window.staticTexts["settings-locked-notice"].exists)

        window.buttons["Aumenta CPU"].click()
        window.buttons["Aumenta CPU"].click()
        XCTAssertTrue(save.isEnabled)
        snapshot(window, app: app, name: "S08-Impostazioni-VM-arrestata")
        save.click()
        XCTAssertTrue(window.staticTexts["settings-saved"].waitForExistence(timeout: 5))

        let config = try JSONSerialization.jsonObject(
            with: Data(contentsOf: bundleURL("debian-13").appendingPathComponent("config.json"))) as? [String: Any]
        XCTAssertEqual(config?["cpuCount"] as? Int, 4)
        XCTAssertEqual(config?["memoryBytes"] as? UInt64, UInt64(4) << 30)
        XCTAssertEqual(config?["macAddress"] as? String, "52:54:00:12:34:56")

        // Generale: name and MAC, read-only.
        window.buttons["settings-section-Generale"].click()
        XCTAssertTrue(window.staticTexts["52:54:00:12:34:56"].waitForExistence(timeout: 5))
        // Accesso, a feature of a later version, is there but disabled; Rete (M3d) is enabled.
        XCTAssertFalse(window.buttons["settings-section-Accesso"].isEnabled)
        XCTAssertTrue(window.buttons["settings-section-Rete"].isEnabled)

        // Condivisione (M3a): enabled, empty, with "Aggiungi cartella…" (the panel is not driven).
        let sharing = window.buttons["settings-section-Condivisione"]
        XCTAssertTrue(sharing.isEnabled)
        sharing.click()
        XCTAssertTrue(window.descendants(matching: .any)["share-empty"].waitForExistence(timeout: 5))
        XCTAssertTrue(window.buttons["share-add"].isEnabled)
        // Rosetta: the toggle is there (enabled or not depends on this Mac); never installed here.
        XCTAssertTrue(window.descendants(matching: .any)["rosetta-toggle"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testFieldsLockWhenTheVMRuns() throws {
        try makeBundle("debian-13")
        let app = launch(extra: ["-NidoFakeSessions"])
        defer { if app.state != .notRunning { app.terminate() } }

        let library = app.windows["Nido"]
        XCTAssertTrue(library.waitForExistence(timeout: 10))
        let card = card("debian-13", in: library)
        card.buttons["Impostazioni"].click()
        let settings = app.windows["Impostazioni di debian-13"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        XCTAssertTrue(settings.buttons["Aumenta CPU"].isEnabled)

        // Start the VM from the library: the open settings lock themselves.
        library.click()
        card.buttons["Avvia"].click()
        let vmWindow = app.windows["debian-13"]
        XCTAssertTrue(vmWindow.waitForExistence(timeout: 10))
        XCTAssertTrue(vmWindow.staticTexts["In esecuzione"].waitForExistence(timeout: 10))

        XCTAssertTrue(settings.staticTexts["settings-locked-notice"].waitForExistence(timeout: 10),
                      "Mancano l'avviso e il blocco con la VM in esecuzione")
        XCTAssertEqual(settings.staticTexts["settings-locked-notice"].value as? String, "Arresta debian-13 per cambiare CPU e memoria.")
        XCTAssertFalse(settings.buttons["Aumenta CPU"].isEnabled)
        XCTAssertFalse(settings.buttons["Diminuisci Memoria"].isEnabled)
        XCTAssertFalse(settings.buttons["settings-save"].isEnabled)
        // To the front, from the Window menu: the VM window may cover it.
        app.menuBars.menuBarItems["Finestra"].click()
        app.menuBars.menuItems["Impostazioni di debian-13"].click()
        snapshot(settings, app: app, name: "S08-Impostazioni-VM-in-esecuzione")

        // "Arresta" in the notice stops the VM and unlocks the fields.
        settings.buttons["settings-stop"].click()
        XCTAssertTrue(settings.staticTexts["settings-locked-notice"].waitForNonExistence(timeout: 15))
        XCTAssertTrue(settings.buttons["Aumenta CPU"].isEnabled)
    }

    @MainActor
    func testPreferencesOpenWithCommandComma() throws {
        let app = launch()
        defer { app.terminate() }
        XCTAssertTrue(app.windows["Nido"].waitForExistence(timeout: 10))
        app.typeKey(",", modifierFlags: .command)

        let window = app.windows.matching(NSPredicate(format: "title != 'Nido'")).firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10), "⌘, non apre le preferenze: \(app.windows.allElementsBoundByIndex.map(\.title))")
        XCTAssertTrue(window.staticTexts["Cartella delle VM"].waitForExistence(timeout: 5))
        XCTAssertTrue(window.buttons["Mostra nel Finder"].exists)
        XCTAssertTrue(window.staticTexts["Apache License 2.0"].exists)
        XCTAssertTrue(window.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Nido 0.' OR value BEGINSWITH 'Nido 0.'")).firstMatch.exists)
        snapshot(window, app: app, name: "S10-Preferenze")
    }

    /// The close, minimise and zoom buttons sit in the middle of the 52 pt bar, level with the
    /// title, as in the VM settings (S08): the Settings scene must not keep a taller toolbar.
    @MainActor
    func testPreferencesWindowButtonsCenterInTheBar() throws {
        let app = launch()
        defer { app.terminate() }
        XCTAssertTrue(app.windows["Nido"].waitForExistence(timeout: 10))
        app.typeKey(",", modifierFlags: .command)

        let window = app.windows.matching(NSPredicate(format: "title != 'Nido'")).firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        let close = window.buttons[XCUIIdentifierCloseWindow]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        let title = window.staticTexts["Impostazioni di Nido"]
        XCTAssertTrue(title.exists)

        let barCenter = window.frame.minY + 26
        XCTAssertEqual(close.frame.midY, barCenter, accuracy: 4, "I pulsanti della finestra non sono al centro della barra")
        XCTAssertEqual(close.frame.midY, title.frame.midY, accuracy: 4, "I pulsanti della finestra non sono allineati al titolo")
    }

    /// Generale › Lingua: the system and the five languages, each named in itself. Nothing is chosen:
    /// a choice writes Nido's real defaults (the UI tests' app has the same bundle identifier) and
    /// quits the app to open it again.
    @MainActor
    func testPreferencesOfferTheLanguages() throws {
        let app = launch()
        defer { app.terminate() }
        XCTAssertTrue(app.windows["Nido"].waitForExistence(timeout: 10))
        app.typeKey(",", modifierFlags: .command)

        let window = app.windows.matching(NSPredicate(format: "title != 'Nido'")).firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        XCTAssertTrue(window.staticTexts["Lingua"].waitForExistence(timeout: 5))
        XCTAssertTrue(window.staticTexts["Nido si chiude e si riapre nella lingua scelta. Con una VM accesa, prima chiede."].exists)
        let picker = window.popUpButtons["preferences-language"]
        XCTAssertTrue(picker.exists, "Manca il menu della lingua")
        snapshot(window, app: app, name: "S10-Preferenze-Lingua")

        picker.click()
        for item in ["Come il sistema", "English", "Italiano", "Deutsch", "Español", "Français"] {
            XCTAssertTrue(picker.menuItems[item].waitForExistence(timeout: 5), "Manca \(item)")
        }
        app.typeKey(.escape, modifierFlags: [])
    }

    // MARK: - Fixtures

    @MainActor
    private func launch(extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(it)", "-AppleLocale", "it_IT", "-NidoRoot", root.path, "-ApplePersistenceIgnoreState", "YES",
                               "-NSWindow Frame library", "100 100 1100 720 0 0 1440 870"] + extra
        app.launch()
        return app
    }

    private func card(_ name: String, in window: XCUIElement) -> XCUIElement {
        let card = window.descendants(matching: .any).matching(identifier: name).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 10), "Manca la scheda di \(name)")
        return card
    }

    private func snapshot(_ window: XCUIElement, app: XCUIApplication, name: String) {
        app.activate()
        let attachment = XCTAttachment(screenshot: window.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func bundleURL(_ name: String) -> URL {
        root.appendingPathComponent("\(name).nidovm", isDirectory: true)
    }

    private func makeBundle(_ name: String) throws {
        let config: [String: Any] = [
            "schemaVersion": 1, "id": UUID().uuidString, "name": name, "guest": "linux",
            "cpuCount": 2, "memoryBytes": UInt64(4) << 30, "diskBytes": UInt64(32) << 30,
            "macAddress": "52:54:00:12:34:56", "clipboardSharing": false,
        ]
        let url = bundleURL(name)
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        XCTAssertTrue(FileManager.default.createFile(
            atPath: url.appendingPathComponent("config.json").path,
            contents: try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys]),
            attributes: [.posixPermissions: 0o600]))
    }
}
