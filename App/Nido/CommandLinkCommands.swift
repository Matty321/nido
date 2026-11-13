// SPDX-License-Identifier: Apache-2.0
import AppKit
import NidoCore
import SwiftUI

/// Where the `nido` command link and the legacy gvproxy copy live: the user's home, or a fake
/// one in DEBUG builds (`-NidoHome`, UI tests: never the real `~/.local`).
@MainActor
@Observable
final class CommandLinkModel {
    nonisolated static let homeFlag = "-NidoHome"

    let link: URL
    let legacyGvproxy: URL
    let target: URL
    private(set) var status: CommandLink.Status

    init(arguments: [String] = ProcessInfo.processInfo.arguments, bundle: Bundle = .main) {
        var link = CommandLink.defaultLink
        var legacy = CommandLink.legacyGvproxy
        #if DEBUG
            if let index = arguments.firstIndex(of: Self.homeFlag), index + 1 < arguments.count,
               arguments[index + 1].hasPrefix("/") {
                let home = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
                link = home.appendingPathComponent(".local/bin/nido")
                legacy = home.appendingPathComponent(".local/libexec/nido/gvproxy")
            }
        #endif
        self.link = link
        self.legacyGvproxy = legacy
        self.target = bundle.bundleURL.appendingPathComponent("Contents/Helpers/nido")
        self.status = CommandLink.status(link: link, target: target)
        // The link can change outside the app: look again when the user comes back to it.
        // The model lives as long as the app: the observer is never removed.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func refresh() { status = CommandLink.status(link: link, target: target) }

    private var legacyExists: Bool { FileManager.default.fileExists(atPath: legacyGvproxy.path) }

    func install() {
        refresh()
        var replaceFile = false
        var removeLegacy = false
        if status == .regularFile {
            let alert = NSAlert()
            alert.messageText = String(localized: "Replace \(display(link))?")
            alert.informativeText = String(localized:
                "It’s a regular file (maybe an old copy of nido). Nido replaces it with a link to the command inside the app.")
            alert.addButton(withTitle: String(localized: "Replace"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            var legacyBox: NSButton?
            if legacyExists {
                let box = NSButton(checkboxWithTitle: String(localized: "Also remove the old copy of gvproxy"),
                                   target: nil, action: nil)
                box.state = .on
                alert.accessoryView = box
                legacyBox = box
            }
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            replaceFile = true
            removeLegacy = legacyBox?.state == .on
        }
        do {
            try CommandLink.install(link: link, target: target, replacingRegularFile: replaceFile)
        } catch {
            show(error: error)
            refresh()
            return
        }
        if removeLegacy { try? FileManager.default.removeItem(at: legacyGvproxy) }
        refresh()
        var text = String(localized: "The nido command is at \(display(link)).")
        if !CommandLink.directoryIsInPATH(
            link.deletingLastPathComponent(), path: ProcessInfo.processInfo.environment["PATH"] ?? "") {
            text += "\n\n" + String(localized: "That folder isn’t in your PATH. Add this line to ~/.zshrc:") + "\n"
            text += "export PATH=\"\(display(link.deletingLastPathComponent())):$PATH\""
        }
        let alert = NSAlert()
        alert.messageText = String(localized: "The nido command is installed")
        alert.informativeText = text
        alert.runModal()
    }

    func remove() {
        do { try CommandLink.remove(link: link, target: target) } catch { show(error: error) }
        refresh()
    }

    private func show(error: any Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Couldn’t complete the operation")
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }

    /// `~`-relative path for the real home, absolute otherwise.
    private func display(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return url.path.hasPrefix(home + "/") ? "~" + url.path.dropFirst(home.count) : url.path
    }
}

/// Nido menu, after "About Nido": "Check for Updates…" (only with an updater), a separator,
/// "Install the nido Command…" and "Remove the nido Command". One group, so the order never
/// depends on how SwiftUI merges groups placed after the same item.
struct CommandLinkCommands: Commands {
    /// nil without a feed in the build: no "Check for Updates…".
    let updates: UpdateController?
    @State private var model = CommandLinkModel()

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            if let updates {
                CheckForUpdatesButton(updates: updates)
            }
            Divider()
            Button("Install the nido Command…") { model.install() }
            Button("Remove the nido Command") { model.remove() }
                .disabled(model.status != .linkedToNido)
        }
    }
}

/// "Check for Updates…": enabled when Sparkle can check (not during a session).
private struct CheckForUpdatesButton: View {
    let updates: UpdateController

    var body: some View {
        Button("Check for Updates…") { updates.checkForUpdates() }
            .disabled(!updates.canCheckForUpdates)
    }
}
