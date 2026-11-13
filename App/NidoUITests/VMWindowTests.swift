// SPDX-License-Identifier: Apache-2.0
import Darwin
import XCTest

/// The VM window without a bootable VM: a lock held by another process, and a bundle that
/// cannot start. Neither starts a VM; the real boot is in `RealVMTests` (opt-in).
final class VMWindowTests: XCTestCase {
    private var root: URL!
    private var lockFDs: [Int32] = []

    override func setUpWithError() throws {
        continueAfterFailure = false
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nido-vmwin-ui-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }

    override func tearDownWithError() throws {
        for fd in lockFDs {
            _ = flock(fd, LOCK_UN)
            _ = close(fd)
        }
        lockFDs = []
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    /// S13: the views strip under the toolbar; the Monitor of a VM with no machine says it is
    /// not running, without polling anything.
    @MainActor
    func testMonitorTabOfAVMWithoutMachine() throws {
        try makeBundle("web-staging")
        try holdLock("web-staging", owner: "app")
        let app = launch()
        defer { app.terminate() }

        let library = app.windows["Nido"]
        XCTAssertTrue(library.waitForExistence(timeout: 10))
        card("web-staging", in: library).buttons["Apri"].click()
        let window = app.windows["web-staging"]
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        let tabs = window.descendants(matching: .any).matching(identifier: "vm-tabs").firstMatch
        XCTAssertTrue(tabs.waitForExistence(timeout: 5), "Manca la barra Schermo · Monitor · AI")
        window.buttons["vm-tab-Monitor"].click()
        XCTAssertTrue(window.staticTexts["La VM non è in esecuzione"].waitForExistence(timeout: 5))
        window.buttons["vm-tab-Schermo"].click()
        XCTAssertTrue(window.staticTexts["Errore"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testVMRunByAnotherProcessShowsErrorAndOneWindow() throws {
        try makeBundle("web-staging")
        // "app" owner, but the pid is this test process: another Nido, as far as the app knows.
        try holdLock("web-staging", owner: "app")
        let app = launch()
        defer { app.terminate() }

        let library = app.windows["Nido"]
        XCTAssertTrue(library.waitForExistence(timeout: 10))
        let card = card("web-staging", in: library)
        card.buttons["Apri"].click()

        let window = app.windows["web-staging"]
        XCTAssertTrue(window.waitForExistence(timeout: 10), "La finestra della VM non si è aperta")
        XCTAssertTrue(window.staticTexts["Errore"].waitForExistence(timeout: 10))
        let lockMessage = NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@",
                                      "già in esecuzione", "già in esecuzione")
        XCTAssertTrue(window.staticTexts.matching(lockMessage).firstMatch.exists, "Manca il messaggio sul lock")
        XCTAssertTrue(window.buttons["Riprova"].exists)
        XCTAssertTrue(window.buttons["Dettagli"].exists)
        snapshot(window, app: app, name: "S07-Finestra-VM-errore")

        // Apri again: the same window comes to the front, no second one.
        library.click()
        card.buttons["Apri"].click()
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        XCTAssertEqual(app.windows.matching(NSPredicate(format: "title == 'web-staging'")).count, 1)

        // No VM behind the window: it closes without asking.
        window.click()
        window.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(window.waitForNonExistence(timeout: 5), "La finestra senza VM deve chiudersi subito")
        XCTAssertEqual(app.sheets.count, 0)
    }

    @MainActor
    func testStartFailureShowsErrorInWindowAndCard() throws {
        // config.json only: disk.img and the other files are missing, so the session cannot be built.
        try makeBundle("rotta")
        let app = launch()
        defer { app.terminate() }

        let library = app.windows["Nido"]
        XCTAssertTrue(library.waitForExistence(timeout: 10))
        card("rotta", in: library).buttons["Avvia"].click()

        let window = app.windows["rotta"]
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        XCTAssertTrue(window.staticTexts["Avvio non riuscito"].waitForExistence(timeout: 10))
        // The lock is released at once: no `.lock` holder left behind.
        XCTAssertFalse(lockHeld("rotta"), "Il lock non è stato rilasciato dopo l'errore")

        // The library shows the session's error on the card.
        XCTAssertTrue(card("rotta", in: library).staticTexts["Errore"].waitForExistence(timeout: 10))
    }

    /// With `-NidoFakeSessions` (DEBUG) the VM "runs" without a guest: the window's running
    /// states, the close guard after full screen, double click and quit, all without booting.
    @MainActor
    func testDoubleClickFullScreenCloseAndQuitWithRunningVM() throws {
        try makeBundle("debian-13")
        let app = launch(extra: ["-NidoFakeSessions"])
        defer { if app.state != .notRunning { app.terminate() } }

        let library = app.windows["Nido"]
        XCTAssertTrue(library.waitForExistence(timeout: 10))
        let card = card("debian-13", in: library)
        XCTAssertTrue(card.staticTexts["Arrestata"].exists)

        // A double click on a card button is that button's, not the card's: no VM window.
        card.buttons["Impostazioni"].doubleClick()
        XCTAssertFalse(app.windows["debian-13"].waitForExistence(timeout: 3),
                       "Il doppio clic su un pulsante ha aperto la VM")

        // Double click on the card (not on a button): the window opens and the VM starts.
        card.staticTexts["2 CPU · 4 GiB di memoria · disco 32 GiB"].doubleClick()
        let window = app.windows["debian-13"]
        XCTAssertTrue(window.waitForExistence(timeout: 10), "Il doppio clic non ha aperto la finestra")
        XCTAssertTrue(window.staticTexts["In esecuzione"].waitForExistence(timeout: 10))
        // Again: the same window comes to the front.
        library.click()
        card.staticTexts["2 CPU · 4 GiB di memoria · disco 32 GiB"].doubleClick()
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        XCTAssertEqual(app.windows.matching(NSPredicate(format: "title == 'debian-13'")).count, 1)

        // Full screen, then ⌘W: the confirmation must still be there.
        window.buttons["Schermo intero"].click()
        XCTAssertTrue(window.buttons["Schermo intero"].waitForNonExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 2)  // the full-screen animation
        // Under XCUITest, Notification Center takes the activation during the full-screen
        // transition (measured: Nido resigns active, no key window, so ⌘W never reaches it).
        // A person's full-screen switch keeps Nido active; click the window, as they would.
        window.click()
        window.typeKey("w", modifierFlags: .command)
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5), "Dopo lo schermo intero ⌘W non chiede conferma")
        XCTAssertTrue(sheet.staticTexts["Arrestare debian-13?"].exists)
        sheet.buttons["Annulla"].click()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 5))
        XCTAssertTrue(window.exists)

        // Leave full screen from the toolbar at the top edge, then close for real.
        let edge = window.descendants(matching: .any)["vm-fullscreen-edge"]
        XCTAssertTrue(edge.waitForExistence(timeout: 5))
        edge.hover()
        let exit = window.buttons["Esci da schermo intero"]
        XCTAssertTrue(exit.waitForExistence(timeout: 5))
        exit.click()
        XCTAssertTrue(window.buttons["Schermo intero"].waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 2)
        window.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))
        sheet.buttons["Arresta e chiudi"].click()
        XCTAssertTrue(window.waitForNonExistence(timeout: 10), "La finestra non si è chiusa dopo l'arresto")
        XCTAssertTrue(card.staticTexts["Arrestata"].waitForExistence(timeout: 10))

        // Quit with the VM on: the alert, the stop, then the app exits by itself.
        card.buttons["Avvia"].click()
        XCTAssertTrue(window.staticTexts["In esecuzione"].waitForExistence(timeout: 10))
        app.typeKey("q", modifierFlags: .command)
        let quit = app.dialogs.buttons["Arresta ed esci"].firstMatch  // not the Touch Bar copy
        XCTAssertTrue(quit.waitForExistence(timeout: 10), "Manca l'avviso di uscita")
        XCTAssertTrue(app.staticTexts["Uscire con debian-13 accesa?"].exists)
        // "Sospendi ed esci" is the default; this test takes the orderly stop.
        XCTAssertTrue(app.dialogs.buttons["Sospendi ed esci"].firstMatch.exists)
        quit.click()
        // The fake session writes no console.log, so debian-13 is in its first boot (M3b):
        // stopping it within the first minute asks once more; "Esci comunque" goes on.
        let anyway = app.dialogs.buttons["Esci comunque"].firstMatch
        XCTAssertTrue(anyway.waitForExistence(timeout: 10), "Manca la domanda sul primo avvio")
        XCTAssertTrue(app.staticTexts["debian-13 sta completando il primo avvio: uscire ora può lasciarla senza accesso SSH"]
            .exists)
        anyway.click()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 30), "L'app non è uscita dopo l'arresto")
        XCTAssertFalse(lockHeld("debian-13"), "Lock rimasto dopo l'uscita")
    }

    /// The window's serial console with a fake guest (`-NidoFakeSessions`): the login banner is
    /// rendered, and keys typed in the window reach the guest (which echoes them).
    @MainActor
    func testSerialConsoleShowsLoginAndTakesTyping() throws {
        try makeBundle("debian-13")
        let app = launch(extra: ["-NidoFakeSessions"])
        defer { if app.state != .notRunning { app.terminate() } }

        let library = app.windows["Nido"]
        XCTAssertTrue(library.waitForExistence(timeout: 10))
        card("debian-13", in: library).buttons["Avvia"].click()
        let window = app.windows["debian-13"]
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        XCTAssertTrue(window.staticTexts["In esecuzione"].waitForExistence(timeout: 10))

        let terminal = window.descendants(matching: .any)["vm-terminal"]
        XCTAssertTrue(terminal.waitForExistence(timeout: 10), "Manca la console della VM")
        XCTAssertTrue(waitForValue(of: terminal, containing: "Debian GNU/Linux 13 debian-13 hvc0"))
        XCTAssertTrue(waitForValue(of: terminal, containing: "debian-13 login:"))

        // The console has the keyboard focus as soon as the window is key: no click needed.
        window.typeText("root")
        XCTAssertTrue(waitForValue(of: terminal, containing: "debian-13 login: root"),
                      "Il testo digitato non arriva alla VM: \(terminal.value ?? "")")
        // Backspace and Return go through as well.
        window.typeKey(.delete, modifierFlags: [])
        window.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(waitForValue(of: terminal, containing: "debian-13 login: roo\ndebian-13 login:"),
                      "Backspace/Invio non arrivano alla VM: \(terminal.value ?? "")")
        snapshot(window, app: app, name: "S07-Finestra-VM-console")

        // ⌘-shortcuts stay with the app: ⌘W asks before closing a running VM.
        window.typeKey("w", modifierFlags: .command)
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5), "⌘W è stato mandato alla VM invece che all'app")
        sheet.buttons["Arresta e chiudi"].click()
        XCTAssertTrue(window.waitForNonExistence(timeout: 10))
    }

    /// The default width: every button of a running VM, no "Altro".
    @MainActor
    func testDefaultWidthShowsEveryButton() throws {
        try makeBundle("debian-13")
        let app = launch(extra: ["-NidoFakeSessions"])
        defer { if app.state != .notRunning { app.terminate() } }
        let window = startedWindow("debian-13", in: app)
        for id in ["vm-pause", "vm-suspend", "vm-stop", "vm-snapshots", "vm-settings", "vm-fullScreen"] {
            XCTAssertTrue(window.buttons[id].waitForExistence(timeout: 5), "Manca \(id) a finestra larga")
        }
        XCTAssertFalse(window.descendants(matching: .any)["vm-more"].exists)
    }

    /// A narrow window: pause and stop stay as buttons, the rest moves into "Altro", whose items
    /// still work (Impostazioni opens the settings).
    @MainActor
    func testNarrowWindowMovesSecondaryButtonsIntoAltro() throws {
        try makeBundle("debian-13")
        // The narrowest window (`-NidoVMWindowWidth`, DEBUG; clamped by the minimum width). The
        // value-less flag goes last: before a key/value pair it would swallow the key, and AppKit
        // would take "500" as a file to open (no library window then).
        let app = launch(extra: ["-NidoVMWindowWidth", "500", "-NidoFakeSessions"])
        defer { if app.state != .notRunning { app.terminate() } }
        let window = startedWindow("debian-13", in: app)
        let more = window.descendants(matching: .any)["vm-more"]
        XCTAssertTrue(more.waitForExistence(timeout: 5), "Manca Altro a finestra stretta")
        XCTAssertLessThan(window.frame.width, 800, "La finestra non è stretta")
        for id in ["vm-pause", "vm-stop"] {
            XCTAssertTrue(window.buttons[id].isHittable, "\(id) deve restare visibile")
        }
        for id in ["vm-suspend", "vm-snapshots", "vm-settings", "vm-fullScreen"] {
            XCTAssertFalse(window.buttons[id].exists, "\(id) deve stare in Altro")
        }
        XCTAssertTrue(window.staticTexts["In esecuzione"].isHittable, "Lo stato deve restare visibile")
        snapshot(window, app: app, name: "S07-Finestra-VM-stretta")

        more.click()
        for label in ["Sospendi", "Snapshot", "Impostazioni", "Schermo intero"] {
            XCTAssertTrue(app.menuItems[label].waitForExistence(timeout: 5), "Manca \(label) in Altro")
        }
        app.menuItems["Impostazioni"].click()
        XCTAssertTrue(app.windows["Impostazioni di debian-13"].waitForExistence(timeout: 10),
                      "Impostazioni da Altro non apre le impostazioni")
    }

    /// A VM created before 0.7.4 (seed without the apt-listchanges file) on the controlled
    /// network: the Rete view counts the hidden local noise and suggests "Spegni"; "Non ora"
    /// hides the suggestion and keeps the answer in the config. "Spegni" itself needs a guest
    /// over SSH: covered by the model tests (VMSettingsModelTests).
    @MainActor
    func testNetworkViewCountsNoiseAndSuggestsQuieting() throws {
        try makeBundle("debian-13", extra: ["schemaVersion": 5, "controlledNetwork": true])
        try writeFile("egress.json", in: "debian-13", JSONSerialization.data(
            withJSONObject: ["v": 1, "allow": ["deb.debian.org"]], options: [.sortedKeys]))
        let now = ISO8601DateFormatter().string(from: Date())
        let lines: [[String: Any]] = [
            ["verdict": "ipv6", "ip": "ff02::16", "port": 0, "proto": "udp"],
            ["verdict": "broadcast", "ip": "255.255.255.255", "port": 67, "proto": "udp"],
            ["verdict": "denyUnknown", "ip": "203.0.113.9", "port": 443, "proto": "tcp"],
        ]
        let log = try lines.map { line -> Data in
            var entry = line
            entry.merge(["time": now, "bytesOut": 0, "bytesIn": 0]) { old, _ in old }
            return try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) + Data("\n".utf8)
        }.reduce(Data(), +)
        try writeFile("egress.log", in: "debian-13", log)
        try makeSeed("debian-13", userData: "#cloud-config\nusers: []\n")

        let app = launch(extra: ["-NidoFakeSessions"])
        defer { if app.state != .notRunning { app.terminate() } }
        let window = startedWindow("debian-13", in: app)
        window.buttons["vm-tab-Rete"].click()

        let noise = window.descendants(matching: .any)["network-hidden-noise"]
        XCTAssertTrue(noise.waitForExistence(timeout: 10), "Manca il conteggio del rumore nascosto")
        let text = noise.label.isEmpty ? (noise.value as? String ?? "") : noise.label
        XCTAssertTrue(text.hasPrefix("2 blocchi di rumore locale nascosti"), "Conteggio: \(text)")
        XCTAssertTrue(window.descendants(matching: .any)["network-quiet"].waitForExistence(timeout: 10),
                      "Manca il suggerimento Spegni")
        XCTAssertEqual(window.buttons["network-quiet-action"].label, "Spegni")
        snapshot(window, app: app, name: "S16-Rete-suggerimento-Spegni")

        window.buttons["network-quiet-secondary"].click()
        XCTAssertTrue(window.descendants(matching: .any)["network-quiet"].waitForNonExistence(timeout: 10),
                      "Non ora non nasconde il suggerimento")
        let config = try JSONSerialization.jsonObject(
            with: Data(contentsOf: bundleURL("debian-13").appendingPathComponent("config.json"))) as? [String: Any]
        XCTAssertEqual(config?["backgroundRequestsOff"] as? Bool, false, "Non ora non resta nel config")
    }

    /// Starts `name` from its card and returns its running window.
    @MainActor
    private func startedWindow(_ name: String, in app: XCUIApplication) -> XCUIElement {
        let library = app.windows["Nido"]
        XCTAssertTrue(library.waitForExistence(timeout: 10))
        card(name, in: library).buttons["Avvia"].click()
        let window = app.windows[name]
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        XCTAssertTrue(window.staticTexts["In esecuzione"].waitForExistence(timeout: 10))
        return window
    }

    @MainActor
    private func waitForValue(of element: XCUIElement, containing text: String, timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let value = element.value as? String, value.contains(text) { return true }
            Thread.sleep(forTimeInterval: 0.2)
        } while Date() < deadline
        return false
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

    private func bundleURL(_ name: String) -> URL {
        root.appendingPathComponent("\(name).nidovm", isDirectory: true)
    }

    private func makeBundle(_ name: String, extra: [String: Any] = [:]) throws {
        var config: [String: Any] = [
            "schemaVersion": 1, "id": UUID().uuidString, "name": name, "guest": "linux",
            "cpuCount": 2, "memoryBytes": UInt64(4) << 30, "diskBytes": UInt64(32) << 30,
            "macAddress": "52:54:00:12:34:56", "clipboardSharing": false,
        ]
        config.merge(extra) { _, new in new }
        let url = bundleURL(name)
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        XCTAssertTrue(FileManager.default.createFile(
            atPath: url.appendingPathComponent("config.json").path,
            contents: try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys]),
            attributes: [.posixPermissions: 0o600]))
    }

    /// A 0600 file in the bundle of `name`.
    private func writeFile(_ file: String, in name: String, _ data: Data) throws {
        XCTAssertTrue(FileManager.default.createFile(
            atPath: bundleURL(name).appendingPathComponent(file).path, contents: data,
            attributes: [.posixPermissions: 0o600]))
    }

    /// The bundle's `seed.iso` with `userData`, built like `CloudInitSeed.buildISO` does.
    private func makeSeed(_ name: String, userData: String) throws {
        let dir = root.appendingPathComponent("seed-\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        try Data(userData.utf8).write(to: dir.appendingPathComponent("user-data"))
        try Data("instance-id: x\nlocal-hostname: \(name)\n".utf8).write(to: dir.appendingPathComponent("meta-data"))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["makehybrid", "-quiet", "-iso", "-joliet", "-default-volume-name", "cidata",
                             "-o", bundleURL(name).appendingPathComponent("seed.iso").path, dir.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "hdiutil non ha creato il seed")
    }

    private func holdLock(_ name: String, owner: String) throws {
        let path = bundleURL(name).appendingPathComponent(".lock").path
        let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        XCTAssertGreaterThanOrEqual(fd, 0)
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        let line = Array("\(getpid()) \(owner)\n".utf8)
        XCTAssertEqual(line.withUnsafeBytes { pwrite(fd, $0.baseAddress, $0.count, 0) }, line.count)
        lockFDs.append(fd)
    }

    /// True when some process holds the bundle lock (a shared probe fails).
    private func lockHeld(_ name: String) -> Bool {
        let fd = open(bundleURL(name).appendingPathComponent(".lock").path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        if flock(fd, LOCK_SH | LOCK_NB) == 0 {
            flock(fd, LOCK_UN)
            return false
        }
        return true
    }
}
