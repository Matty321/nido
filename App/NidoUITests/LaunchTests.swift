// SPDX-License-Identifier: Apache-2.0
import XCTest

final class LaunchTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nido-ui-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    @MainActor
    func testLaunchShowsLibraryWindow() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(it)", "-AppleLocale", "it_IT", "-NidoRoot", root.path, "-ApplePersistenceIgnoreState", "YES"]
        app.launch()

        let window = app.windows["Nido"]
        XCTAssertTrue(window.waitForExistence(timeout: 10), "La finestra Nido non è comparsa")
        XCTAssertTrue(
            window.staticTexts["Nessuna macchina virtuale"].waitForExistence(timeout: 10),
            "Manca il sottotitolo della libreria vuota")
        XCTAssertTrue(window.staticTexts["Il nido è vuoto"].exists, "Manca lo stato vuoto della libreria")
        XCTAssertTrue(window.buttons["Crea VM"].exists)
        app.terminate()
    }
}

final class CommandLinkMenuTests: XCTestCase {
    /// The Nido menu offers "Installa il comando nido…"; with a fake home (`-NidoHome`) it creates
    /// the link there and the notice names the path.
    @MainActor
    func testInstallCommandFromMenu() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("nido-ui-\(UUID().uuidString)", isDirectory: true)
        let root = base.appendingPathComponent("root", isDirectory: true)
        let home = base.appendingPathComponent("home", isDirectory: true)
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }

        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(it)", "-AppleLocale", "it_IT", "-NidoRoot", root.path, "-NidoHome", home.path, "-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        XCTAssertTrue(app.windows["Nido"].waitForExistence(timeout: 10))

        app.menuBars.menuBarItems["Nido"].click()
        let install = app.menuBars.menuItems["Installa il comando nido…"]
        XCTAssertTrue(install.waitForExistence(timeout: 5), "Manca la voce nel menu Nido")
        XCTAssertFalse(app.menuBars.menuItems["Rimuovi il comando nido"].isEnabled)
        install.click()

        let done = app.dialogs.staticTexts["Comando nido installato"]
        XCTAssertTrue(done.waitForExistence(timeout: 5), "Manca l'avviso finale")
        app.dialogs.buttons["OK"].click()

        let link = home.appendingPathComponent(".local/bin/nido").path
        let destination = try fm.destinationOfSymbolicLink(atPath: link)
        XCTAssertTrue(destination.hasSuffix("/Contents/Helpers/nido"), destination)

        app.menuBars.menuBarItems["Nido"].click()
        XCTAssertTrue(app.menuBars.menuItems["Rimuovi il comando nido"].isEnabled)
        app.typeKey(.escape, modifierFlags: [])
        app.terminate()
    }
}

final class UpdatesMenuTests: XCTestCase {
    @MainActor
    private func launch(_ extra: [String]) throws -> (XCUIApplication, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nido-ui-\(UUID().uuidString)", isDirectory: true)
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(it)", "-AppleLocale", "it_IT", "-NidoRoot", root.path, "-ApplePersistenceIgnoreState", "YES"] + extra
        app.launch()
        XCTAssertTrue(app.windows["Nido"].waitForExistence(timeout: 10))
        return (app, root)
    }

    /// The titles of the Nido menu, separators as "-".
    @MainActor
    private func nidoMenuTitles(_ app: XCUIApplication) -> [String] {
        app.menuBars.menuBarItems["Nido"].click()
        let items = app.menuBars.menuBarItems["Nido"].menus.firstMatch.children(matching: .menuItem)
        XCTAssertTrue(items.firstMatch.waitForExistence(timeout: 5))
        let titles = items.allElementsBoundByIndex.map { $0.title.isEmpty ? "-" : $0.title }
        app.typeKey(.escape, modifierFlags: [])
        return titles
    }

    /// Ruling on the order: "Informazioni su Nido", "Cerca aggiornamenti…", separator,
    /// "Installa il comando nido…", "Rimuovi il comando nido". The updater is created but never
    /// started (`-NidoUpdatesPreview`): the item is there, disabled, and nothing goes on the network.
    @MainActor
    func testCheckForUpdatesFollowsAbout() throws {
        let (app, root) = try launch(["-NidoUpdatesPreview"])
        defer { try? FileManager.default.removeItem(at: root) }
        let titles = nidoMenuTitles(app)
        XCTAssertEqual(
            Array(titles.prefix(5)),
            ["Informazioni su Nido", "Cerca aggiornamenti…", "-", "Installa il comando nido…", "Rimuovi il comando nido"],
            "\(titles)")
        app.menuBars.menuBarItems["Nido"].click()
        XCTAssertFalse(app.menuBars.menuItems["Cerca aggiornamenti…"].isEnabled)
        app.typeKey(.escape, modifierFlags: [])
        app.terminate()
    }

    /// Step 6: without a feed (and with a test root) there is no updater and no item.
    @MainActor
    func testNoUpdatesItemWithoutAFeed() throws {
        let (app, root) = try launch([])
        defer { try? FileManager.default.removeItem(at: root) }
        let titles = nidoMenuTitles(app)
        XCTAssertFalse(titles.contains("Cerca aggiornamenti…"), "\(titles)")
        XCTAssertEqual(Array(titles.prefix(3)), ["Informazioni su Nido", "-", "Installa il comando nido…"], "\(titles)")
        app.terminate()
    }
}
