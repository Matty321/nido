// SPDX-License-Identifier: Apache-2.0
import XCTest

/// Opt-in: boots a real Debian VM in the app. Skipped unless the runner gets `NIDO_REAL_VM=1`
/// (`TEST_RUNNER_NIDO_REAL_VM=1 xcodebuild test …`) with:
/// - `NIDO_REAL_VM_ROOT`: absolute VM root holding a VM created by `nido create`;
/// - `NIDO_REAL_VM_NAME`: its name;
/// - `NIDO_REAL_VM_CONTROL` (optional): a directory for a hand-shake with a shell that checks the
///   CLI while the VM runs: the test waits for a `go` file there (the runner may not write it).
final class RealVMTests: XCTestCase {
    private struct MissingConfiguration: Error, CustomStringConvertible {
        var description: String { "NIDO_REAL_VM=1 richiede NIDO_REAL_VM_ROOT e NIDO_REAL_VM_NAME" }
    }

    private var root: URL!
    private var vmName: String!
    private var control: URL?

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["NIDO_REAL_VM"] == "1", "Prova su VM reale disattivata (NIDO_REAL_VM=1 per attivarla)")
        guard let rootPath = env["NIDO_REAL_VM_ROOT"], let vm = env["NIDO_REAL_VM_NAME"] else {
            // Thrown, so the test stops here instead of running on with nil values.
            throw MissingConfiguration()
        }
        continueAfterFailure = false
        root = URL(fileURLWithPath: rootPath, isDirectory: true)
        vmName = vm
        control = env["NIDO_REAL_VM_CONTROL"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    @MainActor
    func testBootPauseFullScreenAndSafeQuit() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(it)", "-AppleLocale", "it_IT", "-NidoRoot", root.path, "-ApplePersistenceIgnoreState", "YES",
                               "-NSWindow Frame library", "100 100 1100 720 0 0 1440 870"]
        app.launch()

        let library = app.windows["Nido"]
        XCTAssertTrue(library.waitForExistence(timeout: 10))
        let card = library.descendants(matching: .any).matching(identifier: vmName).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        // console.log is appended to across boots: only what this boot writes counts.
        let bootMark = consoleLength()
        card.buttons["Avvia"].click()

        let window = app.windows[vmName]
        XCTAssertTrue(window.waitForExistence(timeout: 10), "La finestra della VM non si è aperta")
        // Metric (printed as `NIDO_METRIC …`): from the window on screen to the login prompt in its console.
        let opened = Date()
        XCTAssertTrue(window.staticTexts["In esecuzione"].waitForExistence(timeout: 60), "La VM non è partita")

        // The window's serial console shows the getty's prompt and takes the keyboard.
        let terminal = window.descendants(matching: .any)["vm-terminal"]
        XCTAssertTrue(terminal.waitForExistence(timeout: 10), "Manca la console della VM")
        XCTAssertTrue(waitForValue(of: terminal, timeout: 240) { $0.contains("\(self.vmName!) login:") },
                      "Il prompt di login non è nella finestra: \(terminal.value ?? "")")
        let toLogin = String(format: "NIDO_METRIC finestra→login %.1f s", Date().timeIntervalSince(opened))
        print(toLogin)
        let metric = XCTAttachment(string: toLogin)
        metric.name = "metric-window-to-login"
        metric.lifetime = .keepAlways
        add(metric)
        waitForConsole("login:", timeout: 30, after: bootMark)
        // The guest's size probe (DSR 6n) is answered (R-M2-35), so the getty starts at the top
        // of the console instead of the bottom row.
        let lines = ((terminal.value as? String) ?? "").components(separatedBy: "\n")
        let promptLine = lines.firstIndex { $0.contains("login:") } ?? Int.max
        XCTAssertLessThan(promptLine, 8, "Il prompt non parte dall'alto: \(terminal.value ?? "")")
        let prompts = occurrences(of: "login:", in: terminal)
        // Return on an empty login: the getty prints the prompt again.
        terminal.click()
        terminal.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(waitForValue(of: terminal, timeout: 30) { _ in self.occurrences(of: "login:", in: terminal) > prompts },
                      "Invio non ha ridisegnato il prompt: \(terminal.value ?? "")")
        // Typed text reaches the guest, which echoes it; Return asks for the password.
        terminal.typeText("nido")
        XCTAssertTrue(waitForValue(of: terminal, timeout: 15) { $0.contains("login: nido") },
                      "Il testo digitato non arriva alla VM: \(terminal.value ?? "")")
        terminal.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(waitForValue(of: terminal, timeout: 60) { $0.contains("Password:") },
                      "Manca la richiesta della password: \(terminal.value ?? "")")
        snapshot(window, app: app, name: "real-vm-console")

        // The shell sees "in esecuzione (app)" in `nido list`, checks `nido stop`, then writes `go`.
        handshake()

        // Pausa → the dimmed screen with the note; Riprendi → running again.
        window.buttons["Pausa"].click()
        XCTAssertTrue(window.staticTexts["In pausa"].waitForExistence(timeout: 20))
        XCTAssertTrue(window.descendants(matching: .any)["vm-pause-note"].exists)
        snapshot(window, app: app, name: "real-vm-paused")
        window.buttons["Riprendi"].click()
        XCTAssertTrue(window.buttons["Pausa"].waitForExistence(timeout: 20))
        XCTAssertTrue(window.staticTexts["In esecuzione"].exists)

        // Schermo intero: native full screen, toolbar hidden until the pointer reaches the top edge.
        window.buttons["Schermo intero"].click()
        XCTAssertTrue(window.buttons["Schermo intero"].waitForNonExistence(timeout: 10),
                      "In schermo intero la barra deve nascondersi")
        Thread.sleep(forTimeInterval: 2)  // the full-screen animation
        let edge = window.descendants(matching: .any)["vm-fullscreen-edge"]
        XCTAssertTrue(edge.waitForExistence(timeout: 5))
        edge.hover()
        let exit = window.buttons["Esci da schermo intero"]
        XCTAssertTrue(exit.waitForExistence(timeout: 5), "La barra non compare dal bordo superiore")
        snapshot(window, app: app, name: "real-vm-fullscreen")
        exit.click()
        XCTAssertTrue(window.buttons["Schermo intero"].waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 2)

        // Closing the window while the VM runs asks first; Annulla keeps it running.
        window.click()
        window.typeKey("w", modifierFlags: .command)
        let sheet = window.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5), "Manca la conferma di chiusura")
        XCTAssertTrue(sheet.staticTexts["Arrestare \(vmName!)?"].exists)
        sheet.buttons["Annulla"].click()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 5))
        XCTAssertTrue(window.staticTexts["In esecuzione"].exists)

        // Stop from paused: forced at once, then the stopped screen; Avvia boots it again.
        window.buttons["Pausa"].click()
        XCTAssertTrue(window.buttons["Riprendi"].waitForExistence(timeout: 20))
        window.buttons["Arresta"].click()
        XCTAssertTrue(window.staticTexts["Arrestata"].waitForExistence(timeout: 20), "Arresto da pausa non riuscito")
        XCTAssertTrue(window.staticTexts["\(vmName!) è arrestata"].exists)
        snapshot(window, app: app, name: "real-vm-stopped")
        let restartMark = consoleLength()
        window.buttons["Avvia"].click()
        XCTAssertTrue(window.staticTexts["In esecuzione"].waitForExistence(timeout: 60))
        waitForConsole("login:", timeout: 240, after: restartMark)

        // Quit with the VM on: the alert, then the orderly stop, then the app exits by itself.
        app.typeKey("q", modifierFlags: .command)
        let alert = app.dialogs.firstMatch.exists ? app.dialogs.firstMatch : app.sheets.firstMatch
        // Scoped to the alert: a Touch Bar (real or simulated) mirrors its buttons.
        let quit = app.dialogs.buttons["Arresta ed esci"].firstMatch
        XCTAssertTrue(quit.waitForExistence(timeout: 10), "Manca l'avviso di uscita")
        XCTAssertTrue(app.staticTexts["Uscire con \(vmName!) accesa?"].exists, "Testo dell'avviso: \(alert.debugDescription)")
        quit.click()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 90), "L'app non è uscita dopo l'arresto")
    }

    // MARK: - Helpers

    private var consoleLog: URL {
        root.appendingPathComponent("\(vmName!).nidovm/console.log")
    }

    private func consoleLength() -> Int {
        (try? Data(contentsOf: consoleLog).count) ?? 0
    }

    /// Waits until the serial console (console.log) shows `marker` after byte `after`.
    private func waitForConsole(_ marker: String, timeout: TimeInterval, after: Int = 0) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let data = try? Data(contentsOf: consoleLog), data.count > after,
               String(decoding: data.dropFirst(after), as: UTF8.self).contains(marker) {
                return
            }
            Thread.sleep(forTimeInterval: 2)
        }
        XCTFail("\(marker) non è comparso in console.log entro \(Int(timeout)) s")
    }

    private func waitForValue(of element: XCUIElement, timeout: TimeInterval,
                              _ condition: (String) -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let value = element.value as? String, condition(value) { return true }
            Thread.sleep(forTimeInterval: 0.5)
        } while Date() < deadline
        return false
    }

    private func occurrences(of text: String, in element: XCUIElement) -> Int {
        ((element.value as? String) ?? "").components(separatedBy: text).count - 1
    }

    private func handshake() {
        guard let control else { return }
        let go = control.appendingPathComponent("go").path
        let deadline = Date().addingTimeInterval(180)
        while !FileManager.default.fileExists(atPath: go), Date() < deadline {
            Thread.sleep(forTimeInterval: 1)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: go), "La shell non ha risposto")
    }

    private func snapshot(_ window: XCUIElement, app: XCUIApplication, name: String) {
        app.activate()
        let attachment = XCTAttachment(screenshot: window.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
