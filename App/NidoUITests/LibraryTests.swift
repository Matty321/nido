// SPDX-License-Identifier: Apache-2.0
import Darwin
import XCTest

/// The library with fake bundles in a temporary `-NidoRoot`: one stopped VM, one run by the app,
/// one run by `nido start` (lock held by this test process) and one with a corrupted config.json.
final class LibraryTests: XCTestCase {
    private var root: URL!
    private var lockFDs: [Int32] = []

    override func setUpWithError() throws {
        continueAfterFailure = false
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nido-ui-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])

        try makeBundle("debian-13", cpu: 4, memoryGiB: 8, diskGiB: 64)
        try makeBundle("web-staging", cpu: 2, memoryGiB: 4, diskGiB: 32)
        try holdLock("web-staging", owner: "app")
        try makeBundle("ci-runner", cpu: 2, memoryGiB: 4, diskGiB: 32)
        try holdLock("ci-runner", owner: "cli")
        try makeBundle("vecchia-vm", config: Data("{ non è json".utf8))
    }

    override func tearDownWithError() throws {
        for fd in lockFDs {
            _ = flock(fd, LOCK_UN)
            _ = close(fd)
        }
        lockFDs = []
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    @MainActor
    func testCardsShowStates() throws {
        let app = XCUIApplication()
        // The design's 1100×720 window, whatever frame an earlier run saved in the defaults.
        app.launchArguments = ["-AppleLanguages", "(it)", "-AppleLocale", "it_IT", "-NidoRoot", root.path, "-ApplePersistenceIgnoreState", "YES",
                               "-NSWindow Frame library", "100 100 1100 720 0 0 1440 870"]
        app.launch()
        defer { app.terminate() }

        let window = app.windows["Nido"]
        XCTAssertTrue(window.waitForExistence(timeout: 10), "La finestra Nido non è comparsa")
        XCTAssertTrue(window.staticTexts["4 macchine virtuali · 2 in esecuzione"].waitForExistence(timeout: 10))

        let stopped = card("debian-13", in: window)
        XCTAssertTrue(stopped.staticTexts["Arrestata"].exists)
        XCTAssertTrue(stopped.staticTexts["4 CPU · 8 GiB di memoria · disco 64 GiB"].exists)
        XCTAssertTrue(stopped.buttons["Avvia"].isEnabled)
        XCTAssertTrue(stopped.buttons["Impostazioni"].isEnabled)

        let running = card("web-staging", in: window)
        XCTAssertTrue(running.staticTexts["In esecuzione"].exists)
        XCTAssertTrue(running.buttons["Apri"].isEnabled)
        XCTAssertTrue(running.buttons["Arresta"].isEnabled)

        let terminal = card("ci-runner", in: window)
        XCTAssertTrue(terminal.staticTexts["In esecuzione (Terminale)"].exists)
        XCTAssertFalse(terminal.buttons["Avvia"].isEnabled, "Avvia deve essere disattivato")
        XCTAssertTrue(terminal.buttons["Arresta"].isEnabled)

        let unreadable = card("vecchia-vm", in: window)
        XCTAssertTrue(unreadable.staticTexts["Illeggibile"].exists)
        XCTAssertTrue(unreadable.staticTexts["config.json danneggiato: la VM non si può aprire."].exists)
        XCTAssertTrue(unreadable.buttons["Mostra nel Finder"].exists)

        // The screenshot is of the window's screen area: bring Nido to the front first.
        app.activate()
        let screenshot = XCTAttachment(screenshot: window.screenshot())
        screenshot.name = "S01-Libreria"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        // Delete always asks first: Annulla keeps the VM.
        unreadable.buttons["Elimina"].click()
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5), "Manca la conferma di eliminazione")
        XCTAssertTrue(sheet.staticTexts["Eliminare vecchia-vm?"].exists)
        sheet.buttons["Annulla"].click()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 5))
        XCTAssertTrue(bundleExists("vecchia-vm"))

        // Elimina in the sheet removes it.
        unreadable.buttons["Elimina"].click()
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))
        sheet.buttons["Elimina"].click()
        XCTAssertTrue(unreadable.waitForNonExistence(timeout: 10), "La VM eliminata è ancora nella libreria")
        XCTAssertFalse(bundleExists("vecchia-vm"))
        XCTAssertTrue(window.staticTexts["3 macchine virtuali · 2 in esecuzione"].waitForExistence(timeout: 5))
    }

    /// "Clona…" in the context menu of a stopped VM: the sheet proposes `<nome>-copia`; the fake
    /// bundle has no disk, so the copy fails and says why in the sheet, which Annulla closes.
    @MainActor
    func testCloneSheetFromTheContextMenu() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(it)", "-AppleLocale", "it_IT", "-NidoRoot", root.path, "-ApplePersistenceIgnoreState", "YES",
                               "-NSWindow Frame library", "100 100 1100 720 0 0 1440 870"]
        app.launch()
        defer { app.terminate() }

        let window = app.windows["Nido"]
        XCTAssertTrue(window.waitForExistence(timeout: 10), "La finestra Nido non è comparsa")
        let stopped = card("debian-13", in: window)
        stopped.staticTexts["4 CPU · 8 GiB di memoria · disco 64 GiB"].rightClick()
        let item = app.menuItems["Clona…"]
        XCTAssertTrue(item.waitForExistence(timeout: 5), "Manca Clona… nel menu della scheda")
        item.click()

        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5), "Manca il foglio Clona")
        XCTAssertTrue(sheet.staticTexts["Clonare debian-13?"].exists)
        XCTAssertEqual(sheet.textFields["clone-name"].value as? String, "debian-13-copia")
        sheet.buttons["Clona"].click()
        XCTAssertTrue(sheet.staticTexts["clone-error"].waitForExistence(timeout: 10), "Manca il motivo dell'errore")
        XCTAssertFalse(bundleExists("debian-13-copia"))
        sheet.buttons["Annulla"].click()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 5))
    }

    /// "Nuova VM" in the toolbar of a library that already has VMs opens the wizard.
    @MainActor
    func testNewVMOpensTheWizardWithVMs() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(it)", "-AppleLocale", "it_IT", "-NidoRoot", root.path, "-ApplePersistenceIgnoreState", "YES",
                               "-NSWindow Frame library", "100 100 1100 720 0 0 1440 870"]
        app.launch()
        defer { app.terminate() }

        let window = app.windows["Nido"]
        XCTAssertTrue(window.waitForExistence(timeout: 10), "La finestra Nido non è comparsa")
        XCTAssertTrue(card("debian-13", in: window).exists)
        window.buttons["new-vm"].click()

        let wizard = app.descendants(matching: .any).matching(identifier: "wizard").firstMatch
        XCTAssertTrue(wizard.waitForExistence(timeout: 5), "Nuova VM non apre la procedura guidata")
    }

    // MARK: - Fixtures

    private func card(_ name: String, in window: XCUIElement) -> XCUIElement {
        let card = window.descendants(matching: .any).matching(identifier: name).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 10), "Manca la scheda di \(name)")
        return card
    }

    private func bundleURL(_ name: String) -> URL {
        root.appendingPathComponent("\(name).nidovm", isDirectory: true)
    }

    private func bundleExists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: bundleURL(name).path)
    }

    /// A bundle with a valid config.json (the VMConfig schema, version 1).
    private func makeBundle(_ name: String, cpu: Int, memoryGiB: UInt64, diskGiB: UInt64) throws {
        let config: [String: Any] = [
            "schemaVersion": 1, "id": UUID().uuidString, "name": name, "guest": "linux",
            "cpuCount": cpu, "memoryBytes": memoryGiB << 30, "diskBytes": diskGiB << 30,
            "macAddress": "52:54:00:12:34:56", "clipboardSharing": false,
        ]
        try makeBundle(name, config: JSONSerialization.data(withJSONObject: config, options: [.sortedKeys]))
    }

    private func makeBundle(_ name: String, config: Data) throws {
        let url = bundleURL(name)
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let configURL = url.appendingPathComponent("config.json")
        XCTAssertTrue(FileManager.default.createFile(
            atPath: configURL.path, contents: config, attributes: [.posixPermissions: 0o600]))
    }

    /// Holds the bundle lock the way BundleLock does: flock on `.lock` with "<pid> <owner>\n".
    /// The pid is this test process, which the test never asks the app to stop.
    private func holdLock(_ name: String, owner: String) throws {
        let path = bundleURL(name).appendingPathComponent(".lock").path
        let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        XCTAssertGreaterThanOrEqual(fd, 0)
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        let line = Array("\(getpid()) \(owner)\n".utf8)
        XCTAssertEqual(line.withUnsafeBytes { pwrite(fd, $0.baseAddress, $0.count, 0) }, line.count)
        lockFDs.append(fd)
    }
}
