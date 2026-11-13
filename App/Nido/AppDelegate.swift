// SPDX-License-Identifier: Apache-2.0
import AppKit
import NidoCore
import OSLog

/// Owns the app's setup and keeps quitting safe: VMs run in this process, so quitting with VMs on
/// first asks, then suspends them all ("Sospendi ed esci", the default; a VM that cannot be
/// suspended is stopped) or stops them in an orderly way (30 s each, in parallel, then forced).
/// A macOS installation in progress asks first and is cancelled cleanly (its `.creating-*` folder
/// is removed; after `MacInstallStore.quitCancelLimit` the quit goes on and a later listing of the
/// root sweeps the folder), a clone in progress is waited for or cancelled cleanly, and a Linux VM in the first minute of
/// its first boot asks first (cloud-init may be replacing its SSH host keys). With a downloaded
/// update pending and a VM running outside the app (`nido start`), Nido stays open
/// (`UpdateController.quitBlockers`): Sparkle would install the update when the process ends.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let setup = AppSetup()
    /// True between "Sospendi/Arresta ed esci" and the end of the stops: a second ⌘Q is ignored.
    private var isStoppingForQuit = false
    /// Settings › Language: the quit under way ends with Nido opened again.
    private var relaunchesAfterQuit = false

    /// Quits through the usual questions (VMs running, a creation, a clone…) and opens Nido again,
    /// in the language just chosen. Cancelled at one of the questions, Nido stays open: the
    /// language is saved anyway and applies from the next launch.
    func relaunch() {
        relaunchesAfterQuit = true
        NSApp.terminate(nil)
        // Still running here: the quit was cancelled, or goes on while the VMs stop (terminateLater).
        if !isStoppingForQuit { relaunchesAfterQuit = false }
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard relaunchesAfterQuit else { return }
        do {
            try Relauncher.start()
        } catch {
            Logger(subsystem: "io.gitlab.pichierri.Nido", category: "quit").error(
                "Relaunch helper not started: \(error.localizedDescription, privacy: .public)")
        }
    }

    private var environment: AppEnvironment? {
        guard case .success(let environment) = setup.result else { return nil }
        return environment
    }

    #if DEBUG
        /// DEBUG: `-AppleInterfaceStyle Dark` (any other value: light) forces the appearance. AppKit
        /// reads that key from the global domain only, so the UI tests' launch argument alone does
        /// not switch the app; the screenshot tests need both appearances on any Mac.
        func applicationWillFinishLaunching(_ notification: Notification) {
            let arguments = ProcessInfo.processInfo.arguments
            guard let index = arguments.firstIndex(of: "-AppleInterfaceStyle"), index + 1 < arguments.count else { return }
            NSApp.appearance = NSAppearance(named: arguments[index + 1] == "Dark" ? .darkAqua : .aqua)
        }
    #endif

    /// Sparkle relaunches the updated app in the background, and SwiftUI may then open no window:
    /// the library would appear only after a Dock click. At the first launch of a new version
    /// (the one that shows "Novità di Nido") with no window on screen, Nido asks LaunchServices to
    /// open it again: the reopen event is what makes SwiftUI show the library (as a Dock click).
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let environment, environment.showsReleaseNotes,
              ReleaseNotesSeen(defaults: .standard).shouldShow()
        else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            guard !NSApp.windows.contains(where: \.isVisible) else { return }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            _ = try? await NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration)
        }
    }

    /// What quitting does about a wizard that is downloading or creating a VM.
    private enum WizardAtQuit {
        case none
        /// Stop the download (its partial file is removed), then quit.
        case cancel(WizardModel)
        /// Wait for the bundle to be written (never a half-created VM), then quit.
        case wait(WizardModel)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isStoppingForQuit else { return .terminateCancel }
        guard let environment else { return .terminateNow }
        let sessions = environment.sessions

        // A downloaded update is installed by Sparkle as soon as this process ends, and nothing
        // public cancels it: with a VM running outside the app (`nido start`), Nido stays open.
        // The app's own VMs do not block: the quit stops them before the process ends.
        // A logout, restart or shutdown is never held: only a user's quit (Cmd-Q, menu, Dock).
        let quitReason = NSAppleEventManager.shared().currentAppleEvent?
            .attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason))?.enumCodeValue
        if let updates = environment.updates, !UpdateGate.isSystemQuit(reason: quitReason) {
            let blockers = updates.quitBlockers(liveNames: sessions.liveModels.map(\.name))
            if case .postpone(let message) = UpdateGate.decision(running: blockers) {
                let alert = NSAlert()
                alert.messageText = String(localized: "Update pending")
                alert.informativeText = message + " " + String(localized:
                    "Quitting now would install the update while a VM is running, so Nido stays open: stop the VMs with nido stop, then quit.")
                // No button added: AppKit's own OK.
                alert.runModal()
                return .terminateCancel
            }
        }

        var wizardAtQuit = WizardAtQuit.none
        if let wizard = environment.activeWizard, wizard.isBusy {
            guard let choice = askAboutCreation(wizard) else { return .terminateCancel }
            wizardAtQuit = choice
        }

        // A macOS installation in progress: quitting cancels it (it cannot be resumed), so it asks.
        let installs = environment.macInstalls
        var cancelInstalls = false
        if let prompt = installs.quitPrompt {
            guard askAboutInstallation(prompt) else { return .terminateCancel }
            cancelInstalls = true
        }

        // A clone in progress: wait for it, or cancel it (its `.cloning-*` folder is removed).
        var cloneAtQuit: LibraryModel.CloneAtQuit?
        let library = environment.library
        if let library, let prompt = library.cloneQuitPrompt {
            guard let choice = askAboutClone(prompt) else { return .terminateCancel }
            cloneAtQuit = choice
        }

        // A snapshot, restore or delete in progress (also of a stopped VM) is never cut short.
        let snapshotBusy = sessions.snapshotBusyNames
        if !snapshotBusy.isEmpty {
            guard askAboutSnapshots(snapshotBusy) else { return .terminateCancel }
        }

        let live = sessions.liveModels
        var choice = VMSessionStore.QuitChoice.stop
        if !live.isEmpty {
            let prompt = VMSessionStore.quitPrompt(
                names: live.map(\.name.rawValue), unsuspendable: sessions.unsuspendableNames())
            let alert = NSAlert()
            alert.messageText = prompt.question
            alert.informativeText = prompt.message
            // The first button is the default (Return): "Sospendi ed esci".
            for title in prompt.buttons { alert.addButton(withTitle: title) }
            let index = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
            guard let chosen = VMSessionStore.QuitChoice(buttonIndex: index) else { return .terminateCancel }
            choice = chosen
            // Only a stop cuts a first boot short ("Sospendi ed esci" saves the guest's state):
            // "Arresta ed esci", or a VM that cannot be suspended. The guest may then be left
            // without SSH host keys (VMs made before this release have no `ssh-keygen -A` bootcmd).
            let firstBoot = sessions.firstBootNames(stoppedBy: chosen, now: Date())
            if !firstBoot.isEmpty {
                guard askAboutFirstBoot(firstBoot) else { return .terminateCancel }
            }
        } else if case .none = wizardAtQuit, snapshotBusy.isEmpty, cloneAtQuit == nil, !cancelInstalls {
            return .terminateNow
        }

        isStoppingForQuit = true
        // From now on nothing starts: a VM started during the stops would be killed by the exit.
        sessions.beginQuit()
        Task {
            switch wizardAtQuit {
            case .none:
                break
            case .cancel(let wizard):
                wizard.cancel()
                await wizard.waitForCleanup()
            case .wait(let wizard):
                await wizard.waitForCleanup()
            }
            if cancelInstalls {
                let late = await installs.cancelAllForQuit()
                if !late.isEmpty {
                    // The quit goes on: the staging lock goes with the process, and a later listing
                    // of the root removes the `.creating-*` folder (`sweepOrphanTombstones`).
                    Logger(subsystem: "io.gitlab.pichierri.Nido", category: "quit").warning(
                        "Installation not ended \(MacInstallStore.quitCancelLimit, privacy: .public) after cancel: \(late.map(\.rawValue).joined(separator: ", "), privacy: .public); quitting anyway")
                }
            }
            switch cloneAtQuit {
            case .wait: await library?.waitForClone()
            case .cancel: await library?.cancelCloneForQuit()
            case nil: break
            }
            await sessions.waitForSnapshots()
            switch choice {
            case .stop:
                await sessions.stopAll()
            case .suspend:
                let warnings = await sessions.suspendAll()
                if !warnings.isEmpty {
                    let alert = NSAlert()
                    alert.messageText = String(localized: "\(warnings.count) virtual machines were stopped")
                    alert.informativeText = warnings.joined(separator: "\n")
                    alert.addButton(withTitle: String(localized: "Quit"))
                    alert.runModal()
                }
            }
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// "<nome> sta completando il primo avvio…": false keeps the app open (Annulla, the default).
    private func askAboutFirstBoot(_ names: [String]) -> Bool {
        let prompt = VMSessionStore.firstBootQuitPrompt(names: names)
        let alert = NSAlert()
        alert.messageText = prompt.question
        alert.informativeText = prompt.message
        for title in prompt.buttons { alert.addButton(withTitle: title) }
        return alert.runModal() == .alertSecondButtonReturn
    }

    /// "Clonazione in corso": nil keeps the app open.
    private func askAboutClone(_ prompt: VMSessionStore.QuitPrompt) -> LibraryModel.CloneAtQuit? {
        let alert = NSAlert()
        alert.messageText = prompt.question
        alert.informativeText = prompt.message
        // The first button is the default (Return): "Esci al termine".
        for title in prompt.buttons { alert.addButton(withTitle: title) }
        let index = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        return LibraryModel.CloneAtQuit(buttonIndex: index)
    }

    /// "Annulla l'installazione ed esci?": true for "Annulla l'installazione ed esci"; the default
    /// ("Continua l'installazione") keeps the app open.
    private func askAboutInstallation(_ prompt: VMSessionStore.QuitPrompt) -> Bool {
        let alert = NSAlert()
        alert.messageText = prompt.question
        alert.informativeText = prompt.message
        for title in prompt.buttons { alert.addButton(withTitle: title) }
        let index = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        return MacInstallStore.cancelsAtQuit(buttonIndex: index)
    }

    /// "Snapshot operation in progress": false keeps the app open.
    private func askAboutSnapshots(_ names: [String]) -> Bool {
        let alert = NSAlert()
        alert.messageText = String(localized: "Snapshot operation in progress")
        // One VM or a list: the sentence never shows a number, so two keys instead of a plural.
        let list = MacInstallStore.nameList(names)
        alert.informativeText = names.count == 1
            ? String(localized: "Nido will quit as soon as the snapshot operation on \(list) is done, so the VM’s files stay intact.")
            : String(localized: "Nido will quit as soon as the snapshot operations on \(list) are done, so the VMs’ files stay intact.")
        alert.addButton(withTitle: String(localized: "Quit When Done"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// "VM creation in progress": nil keeps the app open.
    private func askAboutCreation(_ wizard: WizardModel) -> WizardAtQuit? {
        let alert = NSAlert()
        alert.messageText = String(localized: "VM creation in progress")
        if wizard.canCancel {
            alert.informativeText = String(localized:
                "Nido is downloading the Linux image. Quitting stops the download and deletes the partial file.")
            alert.addButton(withTitle: String(localized: "Stop Download and Quit"))
        } else {
            alert.informativeText = String(localized:
                "Nido is creating the virtual machine. Nido will quit as soon as the VM is ready, so no half-made VM is left behind.")
            alert.addButton(withTitle: String(localized: "Quit When Done"))
        }
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return wizard.canCancel ? .cancel(wizard) : .wait(wizard)
    }
}
