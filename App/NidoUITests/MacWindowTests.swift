// SPDX-License-Identifier: Apache-2.0
import XCTest

/// The window and the settings of a macOS VM (M3b) with fake sessions (`-NidoFakeSessions`,
/// DEBUG): no guest boots, so the screen is the empty background; the panel, the bar, closing
/// and reopening the window and S08 are real.
final class MacWindowTests: XCTestCase {
    private var root: URL!
    private let key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHk2Lw9QeXbT4mZr7Vd1cN8sJpFa3uYoG6tRqE0iWzK5 tu@mac"

    override func setUpWithError() throws {
        continueAfterFailure = false
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nido-macwin-ui-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    /// S07 macOS: no views strip, "Accesso da terminale" opens by itself (nido ssh never worked),
    /// Chiudi and the bar; closing the window keeps the VM running and Apri brings it back.
    @MainActor
    func testTerminalAccessPanelAndClosingKeepsTheVMRunning() throws {
        try makeMacBundle("macos-agenti")
        let app = launch()
        defer { if app.state != .notRunning { app.terminate() } }

        let library = app.windows["Nido"]
        XCTAssertTrue(library.waitForExistence(timeout: 10))
        card("macos-agenti", in: library).buttons["Avvia"].click()
        let window = app.windows["macos-agenti"]
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        XCTAssertTrue(window.staticTexts["In esecuzione"].waitForExistence(timeout: 10))
        XCTAssertFalse(window.descendants(matching: .any).matching(identifier: "vm-tabs").firstMatch.exists,
                       "La finestra macOS non deve avere Schermo · Monitor · AI")

        let panel = window.descendants(matching: .any).matching(identifier: "terminal-access").firstMatch
        XCTAssertTrue(panel.waitForExistence(timeout: 5), "Il pannello Accesso da terminale non si è aperto")
        XCTAssertTrue(panel.staticTexts["Attiva Login remoto"].exists)
        XCTAssertTrue(panel.staticTexts["nido ssh macos-agenti"].exists)
        XCTAssertTrue(panel.buttons["terminal-access-authorize-action"].exists)
        snapshot(window, app: app, name: "S07-Finestra-macOS-Accesso-da-terminale")
        panel.buttons["terminal-access-close"].click()
        XCTAssertFalse(panel.waitForExistence(timeout: 2))
        window.buttons["vm-terminalAccess"].click()
        XCTAssertTrue(panel.waitForExistence(timeout: 5))
        panel.buttons["terminal-access-close"].click()
        snapshot(window, app: app, name: "S07-Finestra-macOS-in-esecuzione")

        // Closing asks nothing and the VM goes on.
        window.buttons[XCUIIdentifierCloseWindow].click()
        XCTAssertTrue(window.waitForNonExistence(timeout: 5), "La chiusura ha chiesto di arrestare la VM macOS")
        XCTAssertTrue(card("macos-agenti", in: library).staticTexts["In esecuzione"].waitForExistence(timeout: 5))
        card("macos-agenti", in: library).buttons["Apri"].click()
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        XCTAssertTrue(window.staticTexts["In esecuzione"].waitForExistence(timeout: 5))
    }

    /// S08 for macOS: "Nome utente per nido ssh" in Generale, no Rosetta, no Guest Tools.
    @MainActor
    func testMacSettings() throws {
        try makeMacBundle("macos-agenti")
        let app = launch()
        defer { app.terminate() }

        let library = app.windows["Nido"]
        XCTAssertTrue(library.waitForExistence(timeout: 10))
        card("macos-agenti", in: library).buttons["Impostazioni"].click()
        let window = app.windows["Impostazioni di macos-agenti"]
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        window.buttons["settings-section-Generale"].click()
        let field = window.textFields["settings-ssh-user"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, "agente")
        XCTAssertFalse(window.buttons["settings-section-Guest Tools"].exists)
        window.buttons["settings-section-Condivisione"].click()
        XCTAssertFalse(window.descendants(matching: .any).matching(identifier: "rosetta-toggle").firstMatch.exists)
        snapshot(window, app: app, name: "S08-Impostazioni-macOS-Condivisione")
    }

    // MARK: - Fixtures

    @MainActor
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(it)", "-AppleLocale", "it_IT", "-NidoRoot", root.path, "-ApplePersistenceIgnoreState", "YES",
                               "-NSWindow Frame library", "100 100 1100 720 0 0 1440 870", "-NidoFakeSessions"]
        app.launch()
        return app
    }

    @MainActor
    private func card(_ name: String, in window: XCUIElement) -> XCUIElement {
        let card = window.descendants(matching: .any).matching(identifier: name).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 10), "Manca la scheda di \(name)")
        return card
    }

    @MainActor
    private func snapshot(_ window: XCUIElement, app: XCUIApplication, name: String) {
        app.activate()
        let attachment = XCTAttachment(screenshot: window.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func makeMacBundle(_ name: String) throws {
        let config: [String: Any] = [
            "schemaVersion": 4, "id": UUID().uuidString, "name": name, "guest": "macos",
            "cpuCount": 4, "memoryBytes": UInt64(8) << 30, "diskBytes": UInt64(64) << 30,
            "macAddress": "52:54:00:12:34:58", "clipboardSharing": false, "sshUser": "agente", "osVersion": "26.6",
        ]
        let url = root.appendingPathComponent("\(name).nidovm", isDirectory: true)
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        XCTAssertTrue(FileManager.default.createFile(
            atPath: url.appendingPathComponent("config.json").path,
            contents: try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys]),
            attributes: [.posixPermissions: 0o600]))
        XCTAssertTrue(FileManager.default.createFile(
            atPath: url.appendingPathComponent("authorized_key.pub").path, contents: Data((key + "\n").utf8),
            attributes: [.posixPermissions: 0o600]))
    }
}
