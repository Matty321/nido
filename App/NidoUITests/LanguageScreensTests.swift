// SPDX-License-Identifier: Apache-2.0
import AppKit
import XCTest

/// The main screens in one language, to look for clipped, truncated or overlapping text (German and
/// French run long). The language comes from `NIDO_SCREEN_LANG` (`en`, `de`, `es`, `fr`, `it`):
/// xcodebuild passes `TEST_RUNNER_NIDO_SCREEN_LANG=de` to the runner as `NIDO_SCREEN_LANG`.
/// Without it every test is skipped, so the normal Italian runs are unchanged.
///
/// The fixtures are those of ScreenshotTests (`ScreenFixtures`), in light appearance only. The tests
/// find everything by accessibility identifier, never by visible text. Each screenshot is an
/// attachment named `<screen>-<lang>`; export them with `xcrun xcresulttool export attachments`.
final class LanguageScreensTests: XCTestCase, ScreenFixtures {
    private static let locales = ["en": "en_US", "it": "it_IT", "de": "de_DE", "es": "es_ES", "fr": "fr_FR"]

    private var language = ""
    private var scratch: URL!
    var root: URL!
    private var home: URL!
    var lockFDs: [Int32] = []

    override func setUpWithError() throws {
        guard let language = ProcessInfo.processInfo.environment["NIDO_SCREEN_LANG"], !language.isEmpty else {
            throw XCTSkip("NIDO_SCREEN_LANG is not set: no screens in other languages")
        }
        guard Self.locales[language] != nil else { throw XCTSkip("Unknown NIDO_SCREEN_LANG \(language)") }
        self.language = language
        continueAfterFailure = false
        (scratch, root, home) = try makeScreenScratch()
    }

    override func tearDownWithError() throws {
        releaseLocks()
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
    }

    // MARK: - Library

    @MainActor
    func testLibrary() throws {
        var app = launch()
        var window = libraryWindow(app)
        XCTAssertTrue(element("new-vm", in: window).waitForExistence(timeout: 10))
        capture(window, app: app, "library-empty")
        app.terminate()

        try makeBundle("debian-13", cpu: 4, memoryGiB: 8, diskGiB: 64)
        try makeBundle("dev-box", cpu: 4, memoryGiB: 8, diskGiB: 128)
        try makeBundle("web-staging", cpu: 2, memoryGiB: 4, diskGiB: 32)
        try makeBundle("ci-runner", cpu: 2, memoryGiB: 4, diskGiB: 32)
        try makeBundle("sandbox", cpu: 2, memoryGiB: 2, diskGiB: 32)
        try makeBundle("test-arm", cpu: 4, memoryGiB: 8, diskGiB: 64)
        try makeBundle("vecchia-vm", config: Data("{ non è json".utf8))
        try makeBundle("archivio", cpu: 2, memoryGiB: 4, diskGiB: 32, suspended: true)
        try holdLock("ci-runner", owner: "cli")
        app = launch(extra: ["-NidoFakeStates", "dev-box=starting,web-staging=running,sandbox=paused,test-arm=error"])
        window = libraryWindow(app)
        XCTAssertTrue(card("archivio", in: window).buttons["action-resumeSuspended"].waitForExistence(timeout: 10))
        XCTAssertTrue(card("web-staging", in: window).buttons["action-open"].waitForExistence(timeout: 10))
        XCTAssertTrue(card("sandbox", in: window).buttons["action-resume"].waitForExistence(timeout: 10))
        XCTAssertTrue(card("test-arm", in: window).buttons["action-retry"].waitForExistence(timeout: 10))
        capture(window, app: app, "library-states")

        openCardMenu("debian-13", item: "clone", in: window, app: app)
        XCTAssertTrue(element("clone-sheet", in: app).waitForExistence(timeout: 5))
        capture(window, app: app, "library-clone")
        element("clone-cancel", in: app).click()
        XCTAssertTrue(element("clone-sheet", in: app).waitForNonExistence(timeout: 5))

        openCardMenu("debian-13", item: "delete", in: window, app: app)
        XCTAssertTrue(element("confirm-sheet", in: app).waitForExistence(timeout: 5))
        capture(window, app: app, "library-delete")
        app.buttons["confirm-cancel"].firstMatch.click()

        // The quit alert with live VMs: the German "Suspend and Quit" is long.
        app.typeKey("q", modifierFlags: .command)
        let stop = quitStopButton(app)
        XCTAssertTrue(stop.waitForExistence(timeout: 5), "No quit alert")
        // The alert itself (a dialog, or a sheet on some systems); the window if neither is found.
        let dialog = app.dialogs.firstMatch, sheet = app.sheets.firstMatch
        attach(dialog.exists ? dialog : sheet.exists ? sheet : window, "quit-alert")
        stop.click()
        if !app.wait(for: .notRunning, timeout: 30) { app.terminate() }
        releaseLocks()
    }

    /// Templates, the AI bridge pill, Save as Template and Edit Template.
    @MainActor
    func testLibraryTemplates() throws {
        try makeBundle("archivio", cpu: 2, memoryGiB: 4, diskGiB: 32, suspended: true)
        try makeAIBundle()
        try makeBundle("ricerca-01", cpu: 4, memoryGiB: 8, diskGiB: 64)
        try makeTemplates()
        let app = launch(extra: ["-NidoFakeStates", "debian-ai=running", "-NidoFakeGuest", "debian-ai=values",
                                 "-NidoFakeAIRouter"])
        let window = libraryWindow(app)
        XCTAssertTrue(element("library-templates", in: window).waitForExistence(timeout: 10))
        XCTAssertTrue(element("bridge-pill", in: card("debian-ai", in: window)).waitForExistence(timeout: 15))
        capture(window, app: app, "library-templates")

        openCardMenu("ricerca-01", item: "saveAsTemplate", in: window, app: app)
        XCTAssertTrue(element("save-template-sheet", in: app).waitForExistence(timeout: 5))
        capture(window, app: app, "library-save-template")
        app.buttons["confirm-cancel"].firstMatch.click()

        card("debian-base", in: window).buttons["action-editTemplate"].click()
        XCTAssertTrue(element("confirm-sheet", in: app).waitForExistence(timeout: 5))
        capture(window, app: app, "library-edit-template")
        app.buttons["confirm-cancel"].firstMatch.click()
        quit(app)
    }

    /// A macOS clone (the warning, then the guest steps) and a macOS install on its card.
    @MainActor
    func testLibraryMac() throws {
        try makeMacBundle("macos-base", diskGiB: 64)
        var app = launch()
        let window = libraryWindow(app)
        openCardMenu("macos-base", item: "clone", in: window, app: app)
        XCTAssertTrue(element("clone-sheet", in: app).waitForExistence(timeout: 5))
        capture(window, app: app, "library-clone-mac")
        element("clone-confirm", in: app).click()
        XCTAssertTrue(element("clone-done", in: app).waitForExistence(timeout: 20), "No notes after the macOS clone")
        capture(window, app: app, "library-clone-mac-done")
        element("clone-done", in: app).click()
        app.terminate()

        app = launch(extra: ["-NidoWizardFixture", "library-mac-installing"])
        XCTAssertTrue(element("install-progress", in: libraryWindow(app)).waitForExistence(timeout: 10))
        capture(libraryWindow(app), app: app, "library-mac-installing")
        app.terminate()
    }

    // MARK: - Wizard

    @MainActor
    func testWizard() throws {
        let linux = ["system", "download-confirm", "download-progress", "download-verify", "download-checksum-error",
                     "resources", "resources-over-limit", "access", "summary", "creating", "create-error"]
        for fixture in linux { captureWizard(fixture) }
        // The AI Starter and template paths: two templates in the root.
        try makeTemplates()
        for fixture in ["system-template", "resources-memory", "access-ollama", "summary-ai", "summary-template"] {
            captureWizard(fixture)
        }
        for name in ["debian-ai-base", "debian-base"] { try FileManager.default.removeItem(at: bundleURL(name)) }
        let mac = ["system-mac", "image-mac-empty", "image-mac-checking", "image-mac-compatible", "image-mac-unsupported",
                   "resources-mac", "resources-mac-below-minimum", "access-mac", "summary-mac", "install-mac",
                   "install-mac-cancel", "install-mac-error"]
        for fixture in mac { captureWizard(fixture) }
    }

    @MainActor
    private func captureWizard(_ fixture: String) {
        let app = launch(extra: ["-NidoWizardFixture", fixture])
        let window = libraryWindow(app)
        let wizard = element("wizard", in: app)
        XCTAssertTrue(wizard.waitForExistence(timeout: 15), "No wizard (\(fixture))")
        // Every step has a title; give a slow launch more time rather than fail the whole run.
        _ = element("wizard-title", in: wizard).waitForExistence(timeout: 10)
        Thread.sleep(forTimeInterval: 1)
        capture(window, app: app, "wizard-\(fixture)")
        app.terminate()
    }

    // MARK: - VM window

    /// Running, paused, suspended (and suspending, when caught), stopped; an error; the narrow
    /// window with "More".
    @MainActor
    func testVMWindow() throws {
        try makeBundle("debian-13", cpu: 4, memoryGiB: 8, diskGiB: 64)
        var app = launch(extra: ["-NidoFakeStates", "debian-13=running"])
        var window = openVMWindow("debian-13", app: app)
        let terminal = element("vm-terminal", in: window)
        XCTAssertTrue(waitForValue(of: terminal, containing: "debian-13 login:"), "Console: \(terminal.value ?? "")")
        capture(window, app: app, "vm-running")

        window.buttons["vm-pause"].click()
        XCTAssertTrue(window.buttons["vm-resume"].waitForExistence(timeout: 10))
        capture(window, app: app, "vm-paused")
        window.buttons["vm-resume"].click()
        XCTAssertTrue(waitEnabled(window.buttons["vm-pause"]))

        toolbar("vm-suspend", in: window, app: app)
        // "Suspending" lasts 0.3 s with a fake VM: a screenshot at once, without the settle time.
        let suspending = XCTAttachment(screenshot: window.screenshot())
        suspending.name = "vm-suspending-\(language)"
        suspending.lifetime = .keepAlways
        add(suspending)
        XCTAssertTrue(window.buttons["vm-resumeSaved"].waitForExistence(timeout: 15))
        capture(window, app: app, "vm-suspended")

        window.buttons["vm-resumeSaved"].click()
        XCTAssertTrue(waitEnabled(window.buttons["vm-pause"]))
        // A click right after the resume is lost now and then: once more if the VM still runs.
        Thread.sleep(forTimeInterval: 1)
        window.buttons["vm-stop"].click()
        if !window.buttons["vm-start"].waitForExistence(timeout: 8), window.buttons["vm-stop"].isEnabled {
            window.buttons["vm-stop"].click()
        }
        XCTAssertTrue(window.buttons["vm-start"].waitForExistence(timeout: 15))
        capture(window, app: app, "vm-stopped")
        app.terminate()

        app = launch(extra: ["-NidoFakeStates", "debian-13=error"])
        let details = card("debian-13", in: libraryWindow(app)).buttons["action-details"]
        XCTAssertTrue(details.waitForExistence(timeout: 10))
        details.click()
        window = app.windows["debian-13"]
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 1)
        capture(window, app: app, "vm-error")
        quit(app)

        // The narrowest window (`-NidoVMWindowWidth`, DEBUG): the value-less flag goes last.
        app = launch(extra: ["-NidoVMWindowWidth", "500", "-NidoFakeSessions"])
        card("debian-13", in: libraryWindow(app)).buttons["action-start"].click()
        window = app.windows["debian-13"]
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        XCTAssertTrue(waitEnabled(window.buttons["vm-pause"]))
        capture(window, app: app, "vm-narrow")
        let more = element("vm-more", in: window)
        XCTAssertTrue(more.waitForExistence(timeout: 5), "No More in the narrow window")
        more.click()
        let suspend = app.menuItems["vm-suspend"]
        XCTAssertTrue(suspend.waitForExistence(timeout: 5), "No vm-suspend in More")
        // The window with the menu open over it, and the menu alone (XCUITest crops both itself).
        attach(window, "vm-narrow-more")
        // The open menu is the one holding vm-suspend (app.menus.firstMatch is the menu bar's).
        let moreMenu = app.menus.containing(.menuItem, identifier: "vm-suspend").firstMatch
        attach(moreMenu.exists && !moreMenu.frame.isEmpty ? moreMenu : window, "vm-narrow-more-menu")
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        quit(app)
    }

    /// A macOS VM: the Terminal Access panel, then the window without it.
    @MainActor
    func testMacWindow() throws {
        try makeMacBundle("macos-agenti", diskGiB: 96)
        let app = launch(extra: ["-NidoFakeSessions"])
        card("macos-agenti", in: libraryWindow(app)).buttons["action-start"].click()
        let window = app.windows["macos-agenti"]
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        let panel = element("terminal-access", in: window)
        XCTAssertTrue(panel.waitForExistence(timeout: 10), "No Terminal Access panel")
        capture(window, app: app, "vm-mac-terminal-access")
        panel.buttons["terminal-access-close"].click()
        XCTAssertTrue(panel.waitForNonExistence(timeout: 5))
        capture(window, app: app, "vm-mac-running")
        quit(app)
    }

    @MainActor
    func testMonitor() throws {
        try makeAIBundle()
        let screens: [(guest: String, wait: String?, delay: TimeInterval)] = [
            ("values", "monitor-system", 2), ("alerts", "monitor-warnings", 2), ("waiting", nil, 3),
            ("missing", nil, 3), ("error", nil, 5), ("version", nil, 5), ("stale", nil, 12), ("stops", "vm-start", 2),
        ]
        for screen in screens {
            let (app, window) = openAIWindow(guest: screen.guest, tab: "Monitor")
            XCTAssertTrue(element("monitor-view", in: window).waitForExistence(timeout: 15))
            if let wait = screen.wait {
                XCTAssertTrue(element(wait, in: window).waitForExistence(timeout: 30), "monitor-\(screen.guest): no \(wait)")
            }
            Thread.sleep(forTimeInterval: screen.delay)
            capture(window, app: app, "monitor-\(screen.guest)")
            quit(app)
        }
        let (app, window) = openAIWindow(guest: "values", tab: "Monitor")
        XCTAssertTrue(element("monitor-system", in: window).waitForExistence(timeout: 30))
        window.buttons["vm-stop"].click()
        XCTAssertTrue(window.buttons["vm-start"].waitForExistence(timeout: 20))
        Thread.sleep(forTimeInterval: 1)
        capture(window, app: app, "monitor-vm-stopped")
        app.terminate()
    }

    /// The Network tab: its count, the blocked-only log, the whole log with every outcome (allowed,
    /// open, blocked, cut, summary, interrupted).
    @MainActor
    func testNetworkTab() throws {
        try makeNetworkBundle()
        appendEgress([
            (-110, "cut", "registry.ollama.ai", "104.21.75.227", 443, "tcp", ["bytesOut": 1_200, "bytesIn": 88_000, "count": 2]),
            (-100, "open", "time.cloudflare.com", "162.159.200.1", 123, "udp", ["bytesOut": 96, "bytesIn": 96]),
            (-90, "suppressed", nil, nil, 0, "tcp", ["lostBlocks": 12, "lostFlows": 3, "lostNoise": 40]),
            (-80, "uplinkLost", nil, nil, 0, "tcp", ["reason": "gvproxy exited"]),
        ], at: Date())
        let app = launch(extra: ["-NidoFakeStates", "debian-13=running", "-NidoNotifications", "denied"])
        let window = openVMWindow("debian-13", app: app)
        appendEgress([
            (0, "name", "example.com", nil, 53, "udp", ["repeats": 2]),
            (0, "denyUnknown", nil, "198.51.100.23", 8443, "tcp", [:]),
            (0, "name", "telemetry.example.net", nil, 53, "udp", [:]),
        ], at: Date())
        let tab = window.buttons["vm-tab-Rete"]
        XCTAssertTrue(waitForNonEmptyValue(of: tab, timeout: 15), "No block count on the Network tab")
        capture(window, app: app, "network-tab-count")
        tab.click()
        XCTAssertTrue(element("network-log", in: window).waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 1)
        capture(window, app: app, "network-log")
        // The switch sits at the row's trailing edge.
        element("network-blocked-only", in: window).coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).click()
        Thread.sleep(forTimeInterval: 1)
        capture(window, app: app, "network-log-all")
        quit(app)
    }

    // MARK: - VM settings

    /// A stopped Linux VM: every section, with two shared folders, Rosetta and three snapshots.
    @MainActor
    func testVMSettingsStopped() throws {
        try makeBundle("debian-13", cpu: 4, memoryGiB: 8, diskGiB: 64, extra: [
            "schemaVersion": 2, "macAddress": "52:54:00:3a:9c:12", "rosetta": true,
            "guestMountsSharedFolders": true, "guestRegistersRosetta": true,
            "sharedFolders": [
                ["name": "progetti", "hostPath": "/Users/Shared", "readOnly": true],
                ["name": "dataset", "hostPath": "/Applications", "readOnly": false],
            ],
        ])
        try makeSnapshot("debian-13", "installazione-pulita", "2026-10-22T09:15:00+02:00", savedState: false)
        try makeSnapshot("debian-13", "dopo-docker", "2026-10-24T16:05:00+02:00", savedState: true)
        let app = launch()
        let settings = openSettings("debian-13", app: app)
        for section in ["Hardware", "Generale", "Condivisione", "Guest Tools"] {
            settings.buttons["settings-section-\(section)"].click()
            Thread.sleep(forTimeInterval: 0.5)
            capture(settings, app: app, "settings-\(section.replacingOccurrences(of: " ", with: "-"))")
        }
        app.terminate()
    }

    /// A running Linux VM: the locked hardware, live sharing, Guest Tools and the manual installer
    /// after an install that cannot reach the guest.
    @MainActor
    func testVMSettingsRunning() throws {
        let key = home.appendingPathComponent(".ssh/id_ed25519.pub").path
        XCTAssertTrue(FileManager.default.createFile(
            atPath: home.appendingPathComponent(".ssh/id_ed25519").path, contents: Data("segnaposto\n".utf8),
            attributes: [.posixPermissions: 0o600]))
        try makeBundle("debian-13", cpu: 4, memoryGiB: 4, diskGiB: 64,
                       extra: ["schemaVersion": 3, "guestMountsSharedFolders": true, "sshPublicKeyPath": key])
        let app = launch(extra: ["-NidoFakeSessions"])
        card("debian-13", in: libraryWindow(app)).buttons["action-start"].click()
        let window = app.windows["debian-13"]
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        XCTAssertTrue(waitEnabled(window.buttons["vm-pause"]))
        toolbar("vm-settings", in: window, app: app)
        let settings = settingsWindow(app)
        settings.buttons["settings-section-Hardware"].click()
        XCTAssertTrue(element("settings-locked-notice", in: settings).waitForExistence(timeout: 10))
        capture(settings, app: app, "settings-Hardware-running")
        settings.buttons["settings-section-Condivisione"].click()
        XCTAssertTrue(settings.buttons["share-add"].waitForExistence(timeout: 5))
        capture(settings, app: app, "settings-Condivisione-running")
        settings.buttons["settings-section-Guest Tools"].click()
        let install = settings.buttons["guest-tools-install"]
        XCTAssertTrue(install.waitForExistence(timeout: 5))
        capture(settings, app: app, "settings-Guest-Tools-running")
        install.click()
        XCTAssertTrue(element("guest-tools-manual", in: settings).waitForExistence(timeout: 60), "No manual installer")
        capture(settings, app: app, "settings-Guest-Tools-manual")
        quit(app)
    }

    /// Rete of a controlled VM (and the broad wildcard warning), of a VM on Apple's NAT (and the
    /// switch's confirmation), of a macOS VM.
    @MainActor
    func testVMSettingsNetwork() throws {
        try makeNetworkBundle()
        var app = launch(extra: ["-NidoNotifications", "allowed", "-NidoFakeSessions"])
        var settings = openSettings("debian-13", app: app)
        settings.buttons["settings-section-Rete"].click()
        XCTAssertTrue(element("network-domain-registry.ollama.ai", in: settings).waitForExistence(timeout: 10))
        capture(settings, app: app, "settings-Rete")
        let field = element("network-new-domain", in: settings)
        field.click()
        field.typeText("*.co.uk")
        settings.buttons["network-add"].click()
        XCTAssertTrue(element("confirm-sheet", in: app).waitForExistence(timeout: 5))
        capture(settings, app: app, "settings-Rete-wildcard")
        app.buttons["confirm-cancel"].firstMatch.click()
        quit(app)

        try FileManager.default.removeItem(at: bundleURL("debian-13"))
        try makeNetworkBundle(controlled: false)
        try FileManager.default.removeItem(at: bundleURL("debian-13").appendingPathComponent("egress.json"))
        try makeMacBundle("macos-agenti", diskGiB: 96)
        for vm in ["debian-13", "macos-agenti"] {
            app = launch(extra: ["-NidoNotifications", "allowed", "-NidoFakeSessions"])
            settings = openSettings(vm, app: app)
            settings.buttons["settings-section-Rete"].click()
            let toggle = element("network-toggle", in: settings)
            XCTAssertTrue(toggle.waitForExistence(timeout: 10))
            Thread.sleep(forTimeInterval: 0.5)
            capture(settings, app: app, "settings-Rete-NAT-\(vm)")
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).click()
            XCTAssertTrue(element("confirm-sheet", in: app).waitForExistence(timeout: 5))
            capture(settings, app: app, "settings-Rete-turn-on-\(vm)")
            app.buttons["confirm-cancel"].firstMatch.click()
            if vm == "macos-agenti" {
                settings.buttons["settings-section-Generale"].click()
                Thread.sleep(forTimeInterval: 0.5)
                capture(settings, app: app, "settings-Generale-mac")
            }
            quit(app)
        }
    }

    // MARK: - Preferences

    @MainActor
    func testPreferences() throws {
        let app = launch(extra: ["-NidoFakeAIRouter"])
        XCTAssertTrue(libraryWindow(app).exists)
        app.typeKey(",", modifierFlags: .command)
        let window = app.windows.containing(.button, identifier: "settings-section-Hugging Face").firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10), "⌘, opens no settings")
        window.buttons["settings-section-Generale"].click()
        Thread.sleep(forTimeInterval: 0.5)
        capture(window, app: app, "prefs-Generale")
        window.buttons["settings-section-Hugging Face"].click()
        XCTAssertTrue(window.buttons["hf-token-replace"].waitForExistence(timeout: 5))
        capture(window, app: app, "prefs-hf-saved")
        window.buttons["hf-token-remove"].click()
        let field = window.secureTextFields["hf-token-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        capture(window, app: app, "prefs-hf-absent")
        field.click()
        field.typeText("not a token")
        window.buttons["hf-token-save"].click()
        XCTAssertTrue(element("hf-token-error", in: window).waitForExistence(timeout: 5))
        capture(window, app: app, "prefs-hf-invalid")
        app.terminate()
    }

    // MARK: - Snapshots

    @MainActor
    func testSnapshots() throws {
        try makeBundle("debian-13", cpu: 4, memoryGiB: 8, diskGiB: 64, machineFiles: true)
        var app = launch()
        var window = openSnapshotsFromSettings(app)
        XCTAssertTrue(element("snapshots-empty", in: window).waitForExistence(timeout: 10))
        capture(window, app: app, "snapshots-empty")
        app.terminate()

        try makeSnapshot("debian-13", "installazione-pulita", "2026-10-22T09:15:00+02:00", savedState: false)
        try makeSnapshot("debian-13", "prima-dell-aggiornamento", "2026-10-24T10:42:00+02:00", savedState: true)
        try makeSnapshot("debian-13", "dopo-docker", "2026-10-24T16:05:00+02:00", savedState: true)
        app = launch()
        window = openSnapshotsFromSettings(app)
        XCTAssertTrue(element("snapshot-row-dopo-docker", in: window).waitForExistence(timeout: 10))
        capture(window, app: app, "snapshots-list")
        window.buttons["snapshot-restore-prima-dell-aggiornamento"].click()
        XCTAssertTrue(element("confirm-sheet", in: app).waitForExistence(timeout: 5))
        capture(window, app: app, "snapshots-restore")
        app.buttons["confirm-cancel"].firstMatch.click()
        XCTAssertTrue(element("confirm-sheet", in: app).waitForNonExistence(timeout: 5))
        window.buttons["snapshot-delete-dopo-docker"].click()
        XCTAssertTrue(element("confirm-sheet", in: app).waitForExistence(timeout: 5))
        capture(window, app: app, "snapshots-delete")
        app.buttons["confirm-cancel"].firstMatch.click()
        XCTAssertTrue(element("confirm-sheet", in: app).waitForNonExistence(timeout: 5))
        window.buttons["snapshot-create"].click()
        let name = window.sheets.firstMatch.textFields["snapshot-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.doubleClick()
        name.typeKey("a", modifierFlags: .command)
        name.typeText("dopo-docker\r")
        XCTAssertTrue(element("snapshots-error", in: window).waitForExistence(timeout: 10))
        capture(window, app: app, "snapshots-error")
        app.terminate()

        // A running VM: the name sheet, then a live snapshot in progress (window and badge).
        app = launch(extra: ["-NidoFakeStates", "debian-13=running"])
        let vmWindow = openVMWindow("debian-13", app: app)
        toolbar("vm-snapshots", in: vmWindow, app: app)
        window = snapshotsWindow(app)
        window.buttons["snapshot-create"].click()
        XCTAssertTrue(window.sheets.firstMatch.textFields["snapshot-name"].waitForExistence(timeout: 5))
        capture(window, app: app, "snapshots-name")
        element("snapshot-name-confirm", in: window).click()
        Thread.sleep(forTimeInterval: 1)
        capture(window, app: app, "snapshots-creating")
        capture(vmWindow, app: app, "vm-snapshotting")
        XCTAssertTrue(element("snapshot-row-snapshot-1", in: window).waitForExistence(timeout: 30))
        quit(app)
    }

    // MARK: - Provisioning and AI

    @MainActor
    func testProvisioning() throws {
        let pending: [String: Any] = ["ollama": true, "model": "llama3.2:1b"]
        let screens: [(guest: String, name: String, wait: String?, log: Bool)] = [
            ("waiting", "phase-1", nil, false),
            ("values+phase2", "phase-2", "provisioning-stop-waiting", false),
            ("values+phase2-fails", "log", "provisioning-retry", true),
            ("values+phase2-done", "done", "provisioning-open-ai", false),
            ("values+phase2-fails", "error", "provisioning-retry", false),
            ("values+ssh-key", "ssh-key", "provisioning-terminal", false),
        ]
        for screen in screens {
            try? FileManager.default.removeItem(at: bundleURL("debian-ai"))
            try makeAIBundle(bridge: false, pending: pending)
            let (app, window) = openAIWindow(guest: screen.guest, tab: nil)
            XCTAssertTrue(element("provisioning-panel", in: window).waitForExistence(timeout: 15))
            if let wait = screen.wait {
                XCTAssertTrue(element(wait, in: window).waitForExistence(timeout: 30), "provisioning-\(screen.name): no \(wait)")
            }
            if screen.log { window.buttons["provisioning-log"].click() }
            Thread.sleep(forTimeInterval: 2)
            capture(window, app: app, "provisioning-\(screen.name)")
            quit(app)
        }
    }

    @MainActor
    func testAI() throws {
        // No Ollama, the bridge off, then the privacy notice.
        try makeAIBundle(bridge: false)
        var (app, window) = openAIWindow(guest: "values", tab: "AI")
        XCTAssertTrue(window.buttons["ai-install-ollama"].waitForExistence(timeout: 15))
        XCTAssertTrue(window.buttons["ai-bridge-enable"].waitForExistence(timeout: 5))
        capture(window, app: app, "ai-no-ollama-bridge-off")
        window.buttons["ai-bridge-enable"].click()
        XCTAssertTrue(element("ai-bridge-privacy", in: app).waitForExistence(timeout: 5))
        capture(window, app: app, "ai-privacy")
        app.buttons["confirm-cancel"].click()
        quit(app)

        // Models and limits, the two confirmations, the catalog, the chat and the usage log.
        try FileManager.default.removeItem(at: bundleURL("debian-ai"))
        try makeAIBundle(logs: true)
        (app, window) = openAIWindow(guest: "values+ollama", tab: "AI")
        XCTAssertTrue(window.buttons["ai-remove-llama3.2:1b"].waitForExistence(timeout: 15))
        XCTAssertTrue(element("ai-bridge-allowed", in: window).waitForExistence(timeout: 10))
        capture(window, app: app, "ai-models-and-limits")
        window.buttons["ai-remove-llama3.2:1b"].click()
        XCTAssertTrue(app.buttons["confirm-action"].waitForExistence(timeout: 5))
        capture(window, app: app, "ai-remove-model")
        app.buttons["confirm-cancel"].click()
        XCTAssertTrue(app.buttons["confirm-action"].waitForNonExistence(timeout: 5))
        window.buttons["ai-action-Disinstalla…"].click()
        XCTAssertTrue(app.buttons["confirm-action"].waitForExistence(timeout: 5))
        capture(window, app: app, "ai-uninstall-ollama")
        app.buttons["confirm-cancel"].click()
        XCTAssertTrue(app.buttons["confirm-action"].waitForNonExistence(timeout: 5))
        window.buttons["ai-bridge-catalog"].click()
        XCTAssertTrue(element("ai-catalog-list", in: app).waitForExistence(timeout: 10))
        capture(window, app: app, "ai-catalog")
        app.buttons["confirm-cancel"].firstMatch.click()

        segment(1, of: element("ai-locale-mode", in: window)).click()
        let input = window.textFields["ai-chat-input"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.click()
        input.typeText("Summarize what cloud-init does at first boot.\r")
        XCTAssertTrue(element("ai-chat-answer", in: window).waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 2)
        segment(1, of: element("ai-remoto-mode", in: window)).click()
        XCTAssertTrue(element("ai-bridge-log", in: window).waitForExistence(timeout: 5))
        capture(window, app: app, "ai-chat-and-log")
        quit(app)

        (app, window) = openAIWindow(guest: "values+ollama+no-bridge", tab: "AI")
        XCTAssertTrue(element("vm-ai", in: window).waitForExistence(timeout: 15))
        Thread.sleep(forTimeInterval: 3)
        capture(window, app: app, "ai-bridge-unavailable")
        quit(app)
    }

    // MARK: - Helpers

    @MainActor
    private func launch(extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        // The design's 1100×720 window, whatever frame an earlier run saved in the defaults.
        app.launchArguments = ["-AppleLanguages", "(\(language))", "-AppleLocale", Self.locales[language] ?? "en_US",
                               "-NidoRoot", root.path, "-ApplePersistenceIgnoreState", "YES",
                               "-NSWindow Frame library", "100 100 1100 720 0 0 1440 870",
                               "-AppleInterfaceStyle", "Light"] + extra
        app.launchEnvironment["HOME"] = home.path
        app.launch()
        return app
    }

    /// "Stop and Quit" in the quit alert: its second button (AppKit names an alert's buttons
    /// `action-button-<n>` in every language).
    @MainActor
    private func quitStopButton(_ app: XCUIApplication) -> XCUIElement {
        app.dialogs.buttons["action-button-2"].firstMatch
    }

    /// Quits with live (fake) VMs: the quit alert, then the orderly stop.
    @MainActor
    private func quit(_ app: XCUIApplication) {
        app.typeKey("q", modifierFlags: .command)
        let stop = quitStopButton(app)
        if stop.waitForExistence(timeout: 5) { stop.click() }
        if !app.wait(for: .notRunning, timeout: 30) { app.terminate() }
    }

    /// The element's screenshot as `<screen>-<lang>`, the pointer parked outside the window and
    /// the animations ended.
    @MainActor
    private func capture(_ element: XCUIElement, app: XCUIApplication, _ screen: String) {
        app.activate()
        element.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
            .withOffset(CGVector(dx: -40, dy: -40)).hover()
        Thread.sleep(forTimeInterval: 1)
        let attachment = XCTAttachment(screenshot: element.screenshot())
        attachment.name = "\(screen)-\(language)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// The element's screenshot as `<screen>-<lang>`, at once: no activation and no pointer move,
    /// which would close an open menu or alert.
    @MainActor
    private func attach(_ element: XCUIElement, _ screen: String) {
        Thread.sleep(forTimeInterval: 1)
        let attachment = XCTAttachment(screenshot: element.screenshot())
        attachment.name = "\(screen)-\(language)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Opens a card's context menu and picks `item` (`menu-<action>`).
    @MainActor
    private func openCardMenu(_ name: String, item: String, in window: XCUIElement, app: XCUIApplication) {
        card(name, in: window).staticTexts.firstMatch.rightClick()
        let target = app.menuItems["menu-\(item)"]
        XCTAssertTrue(target.waitForExistence(timeout: 5), "No menu-\(item) in the menu of \(name)")
        // Hover + Return instead of click(): after a click XCUITest looks for the item again in
        // the menu that just closed, which fails now and then.
        target.hover()
        app.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
    }

    /// The VM started at launch (`-NidoFakeStates`): its window from the card's Open.
    @MainActor
    private func openVMWindow(_ name: String, app: XCUIApplication) -> XCUIElement {
        let open = card(name, in: libraryWindow(app)).buttons["action-open"]
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        open.click()
        let window = app.windows[name]
        XCTAssertTrue(window.waitForExistence(timeout: 10), "No window for \(name)")
        XCTAssertTrue(waitEnabled(window.buttons["vm-pause"]), "\(name) is not running")
        return window
    }

    /// Clicks a toolbar button, or its item in "More" when the toolbar is too narrow for it.
    @MainActor
    private func toolbar(_ id: String, in window: XCUIElement, app: XCUIApplication) {
        let button = window.buttons[id]
        if button.exists { return button.click() }
        element("vm-more", in: window).click()
        let item = app.menuItems[id]
        XCTAssertTrue(item.waitForExistence(timeout: 5), "No \(id) in More")
        item.click()
    }

    /// debian-ai running at once under a fake guest, its window on `tab` (`vm-tab-<id>`).
    @MainActor
    private func openAIWindow(guest: String, tab: String?) -> (XCUIApplication, XCUIElement) {
        let app = launch(extra: ["-NidoFakeStates", "debian-ai=running", "-NidoFakeGuest", "debian-ai=\(guest)",
                                 "-NidoFakeAIRouter"])
        let window = openVMWindow("debian-ai", app: app)
        if let tab { window.buttons["vm-tab-\(tab)"].click() }
        return (app, window)
    }

    @MainActor
    private func settingsWindow(_ app: XCUIApplication) -> XCUIElement {
        let window = app.windows.containing(.button, identifier: "settings-section-Hardware").firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10), "No VM settings")
        return window
    }

    @MainActor
    private func openSettings(_ name: String, app: XCUIApplication) -> XCUIElement {
        card(name, in: libraryWindow(app)).buttons["action-settings"].click()
        return settingsWindow(app)
    }

    @MainActor
    private func snapshotsWindow(_ app: XCUIApplication) -> XCUIElement {
        let window = app.windows.containing(.any, identifier: "snapshots-subtitle").firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10), "No snapshots window")
        return window
    }

    /// Settings › General › Manage Snapshots…: the snapshots window of debian-13.
    @MainActor
    private func openSnapshotsFromSettings(_ app: XCUIApplication) -> XCUIElement {
        let settings = openSettings("debian-13", app: app)
        settings.buttons["settings-section-Generale"].click()
        let manage = element("settings-snapshots", in: settings).buttons["picker-choose"]
        XCTAssertTrue(manage.waitForExistence(timeout: 5))
        manage.click()
        return snapshotsWindow(app)
    }

    /// Two templates in the root (`debian-ai-base`, `debian-base`).
    private func makeTemplates() throws {
        let template = Self.templateConfig
        try makeBundle("debian-ai-base", cpu: 4, memoryGiB: 8, diskGiB: 64, extra: template)
        try makeBundle("debian-base", cpu: 2, memoryGiB: 2, diskGiB: 32, extra: template)
    }

    /// The segment at `index` of a segmented picker (a radio button, or a button on some systems).
    @MainActor
    private func segment(_ index: Int, of picker: XCUIElement) -> XCUIElement {
        picker.radioButtons.count > index ? picker.radioButtons.element(boundBy: index) : picker.buttons.element(boundBy: index)
    }

    @MainActor
    private func waitEnabled(_ element: XCUIElement, timeout: TimeInterval = 15) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if element.exists, element.isEnabled { return true }
            Thread.sleep(forTimeInterval: 0.2)
        } while Date() < deadline
        return false
    }

    @MainActor
    private func waitForNonEmptyValue(of element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let value = element.value as? String, !value.isEmpty { return true }
            Thread.sleep(forTimeInterval: 0.2)
        } while Date() < deadline
        return false
    }
}
