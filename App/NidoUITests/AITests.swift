// SPDX-License-Identifier: Apache-2.0
import XCTest

/// The AI view (S15), the library's templates and the Hugging Face token (S10), without a guest:
/// `-NidoFakeSessions` runs the VM without booting it and `-NidoFakeAIRouter` keeps the token in
/// memory (never the user's Keychain, never the network).
final class AITests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nido-ai-ui-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    /// Locale and Remoto side by side; the first activation of the bridge shows the privacy sheet.
    @MainActor
    func testAIViewShowsBothModesAndPrivacySheet() throws {
        try makeBundle("debian-ai")
        let app = launch(extra: ["-NidoFakeSessions", "-NidoFakeAIRouter"])
        defer { app.terminate() }
        let library = app.windows["Nido"]
        XCTAssertTrue(library.waitForExistence(timeout: 10))
        card("debian-ai", in: library).buttons["Avvia"].click()
        let window = app.windows["debian-ai"]
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        window.buttons["vm-tab-AI"].click()
        XCTAssertTrue(element("ai-locale", in: window).waitForExistence(timeout: 5))
        XCTAssertTrue(element("ai-remoto", in: window).exists)

        window.buttons["ai-bridge-enable"].click()
        let privacy = element("ai-bridge-privacy", in: app)
        XCTAssertTrue(privacy.waitForExistence(timeout: 5), "Manca l'avviso sulla privacy")
        XCTAssertTrue(app.staticTexts["Attivare il ponte AI per debian-ai?"].exists)
        app.buttons["confirm-cancel"].click()
        XCTAssertTrue(privacy.waitForNonExistence(timeout: 5))
        XCTAssertTrue(window.buttons["ai-bridge-enable"].exists, "Annulla non deve accendere il ponte")
    }

    /// A template has its own section, with Nuova VM… and Modifica modello, never Avvia.
    @MainActor
    func testTemplateSectionOffersNewVMNotStart() throws {
        try makeBundle("debian-13")
        try makeBundle("debian-ai-base", template: true)
        let app = launch()
        defer { app.terminate() }
        let library = app.windows["Nido"]
        XCTAssertTrue(library.waitForExistence(timeout: 10))
        XCTAssertTrue(element("library-templates", in: library).waitForExistence(timeout: 10))
        let template = card("debian-ai-base", in: library)
        XCTAssertTrue(template.buttons["Nuova VM…"].exists)
        XCTAssertTrue(template.buttons["Modifica modello"].exists)
        XCTAssertFalse(template.buttons["Avvia"].exists)

        template.buttons["Modifica modello"].click()
        XCTAssertTrue(app.staticTexts["Modificare debian-ai-base?"].waitForExistence(timeout: 5))
        app.buttons["confirm-cancel"].click()
    }

    /// No templates: no Modelli section.
    @MainActor
    func testNoTemplatesNoSection() throws {
        try makeBundle("debian-13")
        let app = launch()
        defer { app.terminate() }
        let library = app.windows["Nido"]
        XCTAssertTrue(library.waitForExistence(timeout: 10))
        _ = card("debian-13", in: library)
        XCTAssertFalse(element("library-templates", in: library).exists)
    }

    /// S10 Hugging Face: the token is saved and the field goes; the value is never shown again.
    @MainActor
    func testTokenIsSavedAndNeverShownAgain() throws {
        let app = launch(extra: ["-NidoFakeAIRouter"])
        defer { app.terminate() }
        XCTAssertTrue(app.windows["Nido"].waitForExistence(timeout: 10))
        app.typeKey(",", modifierFlags: .command)
        let window = app.windows.matching(NSPredicate(format: "title != 'Nido'")).firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        window.buttons["settings-section-Hugging Face"].click()
        // The DEBUG store starts with a token (the bridge works under -NidoFakeAIRouter): remove it.
        let remove = window.buttons["hf-token-remove"]
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        remove.click()
        let field = window.secureTextFields["hf-token-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.click()
        field.typeText("hf_uitestvalue123")
        window.buttons["hf-token-save"].click()
        XCTAssertTrue(window.buttons["hf-token-replace"].waitForExistence(timeout: 5))
        XCTAssertFalse(window.secureTextFields["hf-token-field"].exists)
        XCTAssertFalse(window.staticTexts["hf_uitestvalue123"].exists)
        window.buttons["hf-token-replace"].click()
        XCTAssertEqual(window.secureTextFields["hf-token-field"].value as? String ?? "", "")
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

    @MainActor
    private func element(_ identifier: String, in parent: XCUIElement) -> XCUIElement {
        parent.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @MainActor
    private func card(_ name: String, in window: XCUIElement) -> XCUIElement {
        let card = element(name, in: window)
        XCTAssertTrue(card.waitForExistence(timeout: 10), "Manca la scheda di \(name)")
        return card
    }

    private func makeBundle(_ name: String, template: Bool = false) throws {
        var config: [String: Any] = [
            "schemaVersion": template ? 3 : 1, "id": UUID().uuidString, "name": name, "guest": "linux",
            "cpuCount": 2, "memoryBytes": UInt64(4) << 30, "diskBytes": UInt64(32) << 30,
            "macAddress": "52:54:00:12:34:56", "clipboardSharing": false,
        ]
        if template { config["isTemplate"] = true }
        let url = root.appendingPathComponent("\(name).nidovm", isDirectory: true)
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        XCTAssertTrue(FileManager.default.createFile(
            atPath: url.appendingPathComponent("config.json").path,
            contents: try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys]),
            attributes: [.posixPermissions: 0o600]))
    }
}
