// SPDX-License-Identifier: Apache-2.0
import AppKit
import NidoAgentKit

/// Shows the state of the two permissions Nido Agent needs, each with a button that opens
/// its pane in System Settings, and whether it opens at login. Re-checks every 2 seconds while open.
@MainActor
final class PermissionsWindow: NSObject, NSWindowDelegate {
    private let permissions: SystemPermissions
    private let showsLoginItem: Bool
    private var window: NSWindow?
    private var timer: Timer?
    private let screenRecordingState = NSTextField(labelWithString: "")
    private let accessibilityState = NSTextField(labelWithString: "")
    private let loginItemState = NSTextField(labelWithString: "")
    private let onChange: @MainActor () -> Void

    /// `showsLoginItem` is false outside Nido Agent.app, where SMAppService has no app to report on.
    init(permissions: SystemPermissions, showsLoginItem: Bool, onChange: @escaping @MainActor () -> Void) {
        self.permissions = permissions
        self.showsLoginItem = showsLoginItem
        self.onChange = onChange
    }

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        refresh()
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
    }

    private func refresh() {
        Self.setState(screenRecordingState, granted: permissions.screenRecording)
        Self.setState(accessibilityState, granted: permissions.accessibility)
        if showsLoginItem {
            Self.setLoginItemState(loginItemState, state: LoginItem.state)
        }
        onChange()
    }

    private static func setState(_ label: NSTextField, granted: Bool) {
        label.stringValue = granted ? String(localized: "Allowed") : String(localized: "Not allowed")
        label.textColor = granted ? .systemGreen : .systemOrange
    }

    private static func setLoginItemState(_ label: NSTextField, state: LoginItemState) {
        label.stringValue = switch state {
        case .enabled: String(localized: "On")
        case .requiresApproval: String(localized: "Needs your approval in System Settings")
        case .notRegistered, .notFound: String(localized: "Off")
        }
        label.textColor = state == .enabled ? .systemGreen : .systemOrange
    }

    // MARK: - Layout

    private func makeWindow() -> NSWindow {
        let intro = NSTextField(wrappingLabelWithString: String(localized:
            "Nido Agent lets an AI agent you allow in Nido see this Mac’s screen and use its mouse and keyboard. It needs two permissions in System Settings > Privacy & Security."))
        intro.preferredMaxLayoutWidth = 440

        let screenRow = row(title: String(localized: "Screen Recording"),
                            detail: String(localized: "To take screenshots of this Mac’s screen."),
                            state: screenRecordingState,
                            action: #selector(openScreenRecording))
        let accessibilityRow = row(title: String(localized: "Accessibility"),
                                   detail: String(localized: "To click, scroll and type on this Mac."),
                                   state: accessibilityState,
                                   action: #selector(openAccessibility))

        let note = NSTextField(wrappingLabelWithString: String(localized:
            "After allowing Screen Recording, macOS may ask you to quit and reopen Nido Agent."))
        note.textColor = .secondaryLabelColor
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        note.preferredMaxLayoutWidth = 440

        var rows = [screenRow, accessibilityRow]
        if showsLoginItem {
            rows.append(row(title: String(localized: "Open at Login"),
                            detail: String(localized: "So Nido can reach this Mac after every restart."),
                            state: loginItemState,
                            action: #selector(openLoginItems)))
        }

        let stack = NSStackView(views: [intro] + rows + [note])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        for view in rows {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        }

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 260),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = String(localized: "Nido Agent Permissions")
        window.isReleasedWhenClosed = false
        window.delegate = self
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stack.widthAnchor.constraint(equalToConstant: 480),
        ])
        window.contentView = content
        window.center()
        return window
    }

    private func row(title: String, detail: String, state: NSTextField, action: Selector) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        // Wraps instead of being cut off next to a long button title (Italian, German).
        let detailLabel = NSTextField(wrappingLabelWithString: detail)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.preferredMaxLayoutWidth = 220
        let text = NSStackView(views: [titleLabel, detailLabel, state])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2

        let button = NSButton(title: String(localized: "Open System Settings"), target: self, action: action)
        button.bezelStyle = .rounded

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [text, spacer, button])
        row.orientation = .horizontal
        row.alignment = .centerY
        return row
    }

    @objc private func openScreenRecording() {
        NSWorkspace.shared.open(SystemPermissions.screenRecordingSettings)
    }

    @objc private func openAccessibility() {
        NSWorkspace.shared.open(SystemPermissions.accessibilitySettings)
    }

    @objc private func openLoginItems() {
        LoginItem.openSystemSettings()
    }
}
