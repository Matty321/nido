// SPDX-License-Identifier: Apache-2.0
import AppKit
import Darwin
import NidoAgentKit

/// Nido Agent: a menu-bar helper inside a macOS VM. It lets the host (Nido, with agent access
/// turned on for this VM) take screenshots and post mouse and keyboard input, using only the
/// Screen Recording and Accessibility permissions.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let permissions = SystemPermissions()
    private var statusItem: NSStatusItem?
    private let stateItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let permissionsStateItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let loginItemStateItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var listenerState: VsockListener.State = .starting
    private var listener: VsockListener?
    private lazy var permissionsWindow = PermissionsWindow(permissions: permissions,
                                                           showsLoginItem: inOwnBundle) { [weak self] in
        self?.updateMenu()
    }

    /// Login item and permission prompts only make sense inside Nido Agent.app: TCC and
    /// SMAppService identify the app by its bundle.
    private var inOwnBundle: Bool { Bundle.main.bundleIdentifier == Log.subsystem }

    /// Nil outside Nido Agent.app.
    private var loginItemState: LoginItemState? { inOwnBundle ? LoginItem.state : nil }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpStatusItem()

        if inOwnBundle {
            LoginItem.registerIfNeeded()
            SystemPermissions.promptOnFirstLaunch()
        } else {
            Log.app.notice("not running inside Nido Agent.app: no login item, no permission prompts")
        }

        let dispatcher = AgentDispatcher(
            screen: ScreenCapture(), input: InputPoster(), permissions: permissions,
            clipboard: ClipboardSetter(pasteboard: SystemPasteboard()), accessibility: AXSource(),
            transfer: TransferFolder(root: TransferFolder.userFolder),
            screenLocked: { ScreenCapture.screenLocked() })
        let listener = VsockListener(dispatcher: dispatcher) { [weak self] state in
            Task { @MainActor in self?.listenerStateChanged(state) }
        }
        self.listener = listener
        listener.start()

        if !permissions.screenRecording || !permissions.accessibility || loginItemState?.needsApproval == true {
            permissionsWindow.show()
        }
        updateMenu()
    }

    // MARK: - Menu

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "cursorarrow.rays", accessibilityDescription: "Nido Agent")
        let menu = NSMenu()
        menu.delegate = self
        stateItem.isEnabled = false
        permissionsStateItem.isEnabled = false
        loginItemStateItem.target = self
        menu.addItem(stateItem)
        menu.addItem(permissionsStateItem)
        menu.addItem(loginItemStateItem)
        menu.addItem(.separator())
        let permissionsItem = NSMenuItem(title: String(localized: "Permissions…"),
                                         action: #selector(showPermissions), keyEquivalent: "")
        permissionsItem.target = self
        menu.addItem(permissionsItem)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: String(localized: "Quit Nido Agent"),
                              action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        item.menu = menu
        statusItem = item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        updateMenu()
    }

    private func listenerStateChanged(_ state: VsockListener.State) {
        listenerState = state
        updateMenu()
    }

    private func updateMenu() {
        stateItem.title = switch listenerState {
        case .starting: String(localized: "Starting…")
        case .ready: String(localized: "Ready for Nido")
        case .agentAccessOff: String(localized: "Agent access is off for this VM in Nido")
        case .failed: String(localized: "Cannot listen for Nido: retrying")
        }
        let missing = !permissions.screenRecording || !permissions.accessibility
        permissionsStateItem.title = missing ? String(localized: "Permissions needed") : String(localized: "Permissions allowed")

        let loginItem = loginItemState
        loginItemStateItem.isHidden = loginItem == nil
        // Only the state that needs the user is a clickable item; the menu enables items with an action.
        loginItemStateItem.action = loginItem?.needsApproval == true ? #selector(openLoginItems) : nil
        loginItemStateItem.title = switch loginItem {
        case .enabled: String(localized: "Opens at login")
        case .requiresApproval: String(localized: "Allow Opening at Login…")
        case .notRegistered, .notFound, nil: String(localized: "Does not open at login")
        }
    }

    @objc private func openLoginItems() {
        LoginItem.openSystemSettings()
    }

    @objc private func showPermissions() {
        permissionsWindow.show()
    }
}

// A host that drops a connection must never kill the helper. Every accepted socket also has
// SO_NOSIGPIPE; this is the second guard.
signal(SIGPIPE, SIG_IGN)

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    // `delegate` is weak on NSApplication; keep ours alive for the life of the app.
    withExtendedLifetime(delegate) { app.run() }
}
