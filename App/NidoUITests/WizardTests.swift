// SPDX-License-Identifier: Apache-2.0
import XCTest

/// F01: from the empty library to a created Debian VM in at most 6 clicks, with a local image
/// (`-NidoImageFile`, DEBUG only) so "Scarica" never reaches the network.
final class WizardTests: XCTestCase {
    private var scratch: URL!
    private var clicks = 0

    override func setUpWithError() throws {
        continueAfterFailure = false
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("nido-wizard-ui-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: scratch, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }

    override func tearDownWithError() throws {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
    }

    @MainActor
    func testHappyPathClickCount() throws {
        let fm = FileManager.default
        let root = scratch.appendingPathComponent("VMs", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        // VMFactory clones any regular file and grows it to the disk size: 1 MiB of zeros will do
        // (the VM is not started here).
        let image = scratch.appendingPathComponent("base.raw")
        XCTAssertTrue(fm.createFile(atPath: image.path, contents: Data(count: 1 << 20)))
        // The preselected key is ~/.ssh/id_ed25519.pub: a HOME of our own holds a valid one.
        let home = scratch.appendingPathComponent("home", isDirectory: true)
        let ssh = home.appendingPathComponent(".ssh", isDirectory: true)
        try fm.createDirectory(at: ssh, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Data("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOO97YvP4YWGQwUFq+UeOnyDKkD29RZ8VdmeuGgPzeS6 test\n".utf8)
            .write(to: ssh.appendingPathComponent("id_ed25519.pub"))

        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(it)", "-AppleLocale", "it_IT", "-NidoRoot", root.path, "-NidoImageFile", image.path,
                               "-ApplePersistenceIgnoreState", "YES",
                               "-NSWindow Frame library", "100 100 1100 720 0 0 1440 870"]
        app.launchEnvironment["HOME"] = home.path
        app.launch()
        defer { app.terminate() }

        let window = app.windows["Nido"]
        XCTAssertTrue(window.waitForExistence(timeout: 10), "La finestra Nido non è comparsa")

        // 1. Crea VM (empty state).
        let create = window.buttons["Crea VM"]
        XCTAssertTrue(create.waitForExistence(timeout: 10))
        click(create)

        let wizard = app.descendants(matching: .any).matching(identifier: "wizard").firstMatch
        XCTAssertTrue(wizard.waitForExistence(timeout: 5), "La procedura guidata non si è aperta")
        let next = wizard.buttons["wizard-next"]
        waitForStep(1, in: wizard)
        // The system tiles are buttons (M3b): Debian 13 is "os-D", selected by default.
        XCTAssertTrue(wizard.buttons["os-D"].exists)

        // 2. Avanti → Download, which asks before anything is fetched.
        click(next)
        waitForStep(2, in: wizard)
        XCTAssertEqual(next.label, "Scarica")
        XCTAssertTrue(wizard.staticTexts["Origine"].exists)
        XCTAssertTrue(wizard.staticTexts["base.raw"].exists)
        snapshot(window, app: app, name: "S03-Download-conferma")

        // 3. Scarica → the image is ready and the wizard moves on to Risorse by itself.
        click(next)
        waitForStep(3, in: wizard, timeout: 15)
        XCTAssertEqual(next.label, "Avanti")
        snapshot(window, app: app, name: "S04-Risorse")

        // 4. Avanti → Accesso, with the preselected key.
        click(next)
        waitForStep(4, in: wizard)
        XCTAssertTrue(wizard.staticTexts["~/.ssh/id_ed25519.pub · ssh-ed25519"].exists)

        // 5. Avanti → Riepilogo.
        click(next)
        waitForStep(5, in: wizard)
        XCTAssertEqual(next.label, "Crea e avvia")

        // 6. Crea e avvia.
        click(next)
        XCTAssertTrue(wizard.waitForNonExistence(timeout: 30), "La procedura non si è chiusa dopo la creazione")

        XCTAssertLessThanOrEqual(clicks, 6, "Percorso F01 oltre 6 clic")
        let card = window.descendants(matching: .any).matching(identifier: "debian-13").firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 10), "La nuova VM non compare nella libreria")
        XCTAssertTrue(window.staticTexts["1 macchina virtuale"].waitForExistence(timeout: 5))
        let bundle = root.appendingPathComponent("debian-13.nidovm", isDirectory: true)
        for file in ["config.json", "disk.img", "seed.iso"] {
            XCTAssertTrue(fm.fileExists(atPath: bundle.appendingPathComponent(file).path), "Manca \(file)")
        }
    }

    /// S02 and S05 of M3c: the profiles, "Da modello" with no template, the phase 1 options on
    /// and Ollama off by default (nothing is created).
    @MainActor
    func testProfilesAndSoftwareOptions() throws {
        let fm = FileManager.default
        let root = scratch.appendingPathComponent("VMs", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let image = scratch.appendingPathComponent("base.raw")
        XCTAssertTrue(fm.createFile(atPath: image.path, contents: Data(count: 1 << 20)))
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(it)", "-AppleLocale", "it_IT", "-NidoRoot", root.path, "-NidoImageFile", image.path,
                               "-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        defer { app.terminate() }

        let window = app.windows["Nido"]
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        window.buttons["Crea VM"].click()
        let wizard = app.descendants(matching: .any).matching(identifier: "wizard").firstMatch
        XCTAssertTrue(wizard.waitForExistence(timeout: 5))
        XCTAssertTrue(wizard.buttons["profile-Debian Base"].exists)
        XCTAssertTrue(wizard.buttons["profile-Debian AI Starter"].exists)
        wizard.buttons["profile-Da modello"].click()
        XCTAssertTrue(wizard.staticTexts["Passo 1 di 2"].waitForExistence(timeout: 5))
        XCTAssertTrue(wizard.staticTexts["Nessun modello"].exists)
        XCTAssertFalse(wizard.buttons["wizard-next"].isEnabled)
        wizard.buttons["profile-Debian AI Starter"].click()
        waitForStep(1, in: wizard)
        wizard.buttons["wizard-next"].click()  // Download (asks first)
        wizard.buttons["wizard-next"].click()  // Scarica (local file) → Risorse
        waitForStep(3, in: wizard, timeout: 10)
        wizard.buttons["wizard-next"].click()
        waitForStep(4, in: wizard)
        XCTAssertTrue(wizard.staticTexts["Accesso e software"].exists)
        // The row's identifier sits on its container; the switch inside carries the value
        // (`NidoToggleRow` represents itself to accessibility as a Toggle).
        let row = wizard.descendants(matching: .any).matching(identifier: "option-ollama").firstMatch
        XCTAssertTrue(row.exists)
        let title = "Installa Ollama dopo il primo avvio"
        let ollama = wizard.switches[title].exists ? wizard.switches[title] : wizard.checkBoxes[title]
        XCTAssertTrue(ollama.exists, "Manca l'interruttore di Ollama")
        XCTAssertEqual("\(ollama.value ?? "nil")", "0", "Ollama è spento di default")
        XCTAssertFalse(wizard.textFields["option-model"].exists)
        wizard.buttons["wizard-cancel"].click()
    }

    /// F01 macOS: from the empty library to a macOS installation in at most 6 clicks, with a stand-in
    /// IPSW (`-NidoIPSWFile`) and the fake installer (`-NidoFakeMacInstaller`, DEBUG: it stops at
    /// 42 %, nothing is installed). Then "Continua nella libreria", the installing card, Mostra and
    /// Annulla… with its confirmation: the root stays empty.
    @MainActor
    func testMacOSPathClickCountAndCancel() throws {
        let fm = FileManager.default
        let root = scratch.appendingPathComponent("VMs", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let ipsw = scratch.appendingPathComponent("UniversalMac_26.6_Restore.ipsw")
        XCTAssertTrue(fm.createFile(atPath: ipsw.path, contents: Data([0x50, 0x4B, 0x03, 0x04])))
        let home = scratch.appendingPathComponent("home", isDirectory: true)
        let ssh = home.appendingPathComponent(".ssh", isDirectory: true)
        try fm.createDirectory(at: ssh, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Data("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOO97YvP4YWGQwUFq+UeOnyDKkD29RZ8VdmeuGgPzeS6 test\n".utf8)
            .write(to: ssh.appendingPathComponent("id_ed25519.pub"))

        let app = XCUIApplication()
        // The value-less flag goes last: before "-ApplePersistenceIgnoreState" the argument domain
        // would read that key as its value and the pairs after it would shift.
        app.launchArguments = ["-AppleLanguages", "(it)", "-AppleLocale", "it_IT", "-NidoRoot", root.path, "-NidoIPSWFile", ipsw.path,
                               "-ApplePersistenceIgnoreState", "YES",
                               "-NSWindow Frame library", "100 100 1100 720 0 0 1440 870", "-NidoFakeMacInstaller"]
        app.launchEnvironment["HOME"] = home.path
        app.launch()
        defer { app.terminate() }

        let window = app.windows["Nido"]
        XCTAssertTrue(window.waitForExistence(timeout: 10), "La finestra Nido non è comparsa")
        // 1. Crea VM (empty state).
        click(window.buttons["Crea VM"])
        let wizard = app.descendants(matching: .any).matching(identifier: "wizard").firstMatch
        XCTAssertTrue(wizard.waitForExistence(timeout: 5), "La procedura guidata non si è aperta")
        let next = wizard.buttons["wizard-next"]
        waitForStep(1, in: wizard)

        // 2. The macOS tile: chooses macOS and takes the IPSW (the open panel in release builds),
        // then Immagine macOS shows the check by itself.
        click(wizard.buttons["os-M"])
        waitForStep(2, in: wizard)
        XCTAssertTrue(wizard.staticTexts["Immagine macOS"].exists)
        XCTAssertTrue(wizard.staticTexts["macOS 26.6 (25G62)"].waitForExistence(timeout: 10))
        // 3. Avanti → Risorse.
        click(next)
        waitForStep(3, in: wizard)
        // 4. Avanti → Accesso, with the key and the user name (typed when the Mac's own is not valid).
        click(next)
        waitForStep(4, in: wizard)
        XCTAssertTrue(wizard.staticTexts["Nome utente in macOS"].exists)
        let user = wizard.textFields["ssh-user"]
        if (user.value as? String ?? "").isEmpty {
            user.click()
            user.typeText("agente")
        }
        // 5. Avanti → Riepilogo.
        click(next)
        waitForStep(5, in: wizard)
        XCTAssertEqual(next.label, "Crea e installa")
        // 6. Crea e installa.
        click(next)
        XCTAssertLessThanOrEqual(clicks, 6, "Percorso F01 macOS oltre 6 clic")
        XCTAssertTrue(wizard.staticTexts["Installazione di macOS 26.6"].waitForExistence(timeout: 10))
        XCTAssertTrue(next.label == "Continua nella libreria")
        XCTAssertFalse(wizard.buttons["wizard-back"].exists, "Niente Indietro durante l'installazione")

        // Continua nella libreria: the card keeps the progress.
        next.click()
        XCTAssertTrue(wizard.waitForNonExistence(timeout: 5))
        let card = window.descendants(matching: .any).matching(identifier: "macos").firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 5), "Manca la card dell'installazione")
        XCTAssertTrue(card.staticTexts["Installazione"].exists)
        XCTAssertTrue(window.staticTexts["1 macchina virtuale · 1 in installazione"].waitForExistence(timeout: 5))

        // Mostra: the same wizard, still installing.
        card.buttons["action-show-install"].click()
        XCTAssertTrue(wizard.waitForExistence(timeout: 5))
        XCTAssertTrue(wizard.staticTexts["Installazione di macOS 26.6"].exists)
        next.click()
        XCTAssertTrue(wizard.waitForNonExistence(timeout: 5))

        // Annulla… asks first; "Continua" keeps it, "Annulla l'installazione" stops it.
        card.buttons["action-cancel-install"].click()
        let confirm = app.descendants(matching: .any).matching(identifier: "confirm-sheet").firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        XCTAssertTrue(confirm.staticTexts["Annullare l'installazione di macos?"].exists)
        confirm.buttons["confirm-cancel"].click()
        XCTAssertTrue(card.exists)
        card.buttons["action-cancel-install"].click()
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.buttons["confirm-action"].click()
        XCTAssertTrue(card.waitForNonExistence(timeout: 10), "L'installazione annullata è rimasta nella libreria")
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: root.path).filter { !$0.hasPrefix(".") }, [])
    }

    // MARK: - Helpers

    @MainActor
    private func click(_ element: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 5))
        XCTAssertTrue(element.isEnabled, "\(element.label) è disattivato")
        element.click()
        clicks += 1
    }

    @MainActor
    private func waitForStep(_ step: Int, in wizard: XCUIElement, timeout: TimeInterval = 5) {
        let label = wizard.staticTexts["Passo \(step) di 5"]
        XCTAssertTrue(label.waitForExistence(timeout: timeout), "Il passo \(step) non è comparso")
    }

    @MainActor
    private func snapshot(_ window: XCUIElement, app: XCUIApplication, name: String) {
        app.activate()
        let attachment = XCTAttachment(screenshot: window.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
