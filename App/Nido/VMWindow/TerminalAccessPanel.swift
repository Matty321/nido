// SPDX-License-Identifier: Apache-2.0
import AppKit
import NidoCore
import Observation
import SwiftUI

/// "Accesso da terminale" of a macOS VM (S07 macOS, ScreensMac.swift `macVMWindow`): the steps
/// to reach the guest with `nido ssh` once Setup Assistant is done. Opens by itself while the VM
/// runs until `nido ssh` reached the guest once (`VMConfig.sshSucceeded`, recorded by the CLI);
/// always from the bar.
@MainActor
@Observable
final class TerminalAccessModel {
    struct Step: Equatable, Sendable {
        let number: Int
        let title: String
        let detail: String
    }

    let name: VMName
    private(set) var isShown = false
    /// The key in the bundle's authorized_key.pub; nil when it is missing or not typable.
    private(set) var publicKey: String?
    /// Why "Digita nella VM" is not offered (no key, or a key Nido does not type).
    private(set) var keyProblem: String?
    /// The account `nido ssh` logs in as (`VMConfig.sshUser`, `nido` when unset).
    private(set) var sshUser = "nido"
    private(set) var isTyping = false
    /// After a successful "Digita nella VM".
    private(set) var typingMessage: String?
    /// Why the last "Digita nella VM" did not type (localized).
    private(set) var typingError: String?

    /// Chiudi hides the panel until the window appears again.
    @ObservationIgnored private var dismissed = false
    /// `nido ssh` reached the guest once: the panel no longer opens by itself.
    @ObservationIgnored private var sshSucceeded = false
    @ObservationIgnored private let paths: NidoPaths

    init(name: VMName, paths: NidoPaths) {
        self.name = name
        self.paths = paths
    }

    // MARK: - Texts (S07 macOS)

    var title: String { String(localized: "Terminal Access") }
    var intro: String {
        String(localized: "To use \(name.rawValue) with nido ssh, once, after Setup Assistant. Nido never asks for or saves passwords.")
    }
    var steps: [Step] {
        [Step(number: 1, title: String(localized: "Complete Setup Assistant"),
              detail: String(localized: "Create the account \(sshUser): it’s the name nido ssh uses. You can change it in the VM’s settings.")),
         Step(number: 2, title: String(localized: "Turn on Remote Login"),
              detail: String(localized: "In the VM: System Settings › General › Sharing › Remote Login.")),
         Step(number: 3, title: String(localized: "Authorize your key"),
              detail: String(localized: "Open Terminal in the VM, then click Type in VM: Nido types the command with your public key. You can also type it yourself.")),
         Step(number: 4, title: String(localized: "Connect from the Mac"), detail: String(localized: "In Terminal on the Mac:"))]
    }
    /// Step 3's command, with the key (or `<key>` when there is none to show).
    var authorizeCommand: String {
        GuestKeystrokes.command(around: publicKey ?? String(localized: "<key>", comment: "Stands for the public key in a command."))
    }
    var sshCommand: String { "nido ssh \(name.rawValue)" }
    var footnote: String {
        String(localized: "The panel opens automatically until nido ssh has worked once; after that, open it with Terminal Access in the toolbar.")
    }
    /// The limits of typing physical keys, under the command (Caps Lock on in the guest would invert
    /// the key's letters).
    var layoutNote: String {
        String(localized: "Nido uses this Mac’s keyboard layout: if the VM’s is different, type the command yourself. Keep Caps Lock off in the VM.")
    }
    var canType: Bool { publicKey != nil && !isTyping }

    // MARK: - Showing

    /// Rereads the config (account, `sshSucceeded`) and the public key from the bundle.
    func reload() {
        let bundle = VMBundle(url: paths.bundleURL(for: name))
        let config = try? bundle.readConfig()
        sshUser = config?.sshUser ?? "nido"
        sshSucceeded = config?.sshSucceeded == true
        // `PrivateFile` (no symlink, this user's regular file), at most 16 KiB, opened
        // non-blocking: as bounded as the config read just above.
        let text: String?
        do {
            text = try bundle.readAuthorizedKey()
        } catch {
            publicKey = nil
            keyProblem = String(localized: "The VM’s public key (authorized_key.pub) can’t be read safely: type the command yourself with your key.")
            return
        }
        if let text, GuestKeystrokes.isTypablePublicKey(text) {
            publicKey = text
            keyProblem = nil
        } else {
            publicKey = nil
            keyProblem = text == nil
                ? String(localized: "The VM’s public key (authorized_key.pub) isn’t in its folder: type the command yourself with your key.")
                : KeystrokeError.invalidKey.localizedDescription
        }
    }

    /// The VM runs (it started, or its window appeared): opens unless `nido ssh` already worked
    /// or the user closed it in this window.
    func autoShow() {
        reload()
        if !sshSucceeded, !dismissed { isShown = true }
    }

    /// The window appeared again: a Chiudi of the previous window no longer counts.
    func windowAppeared(vmRuns: Bool) {
        dismissed = false
        if vmRuns { autoShow() }
    }

    /// "Accesso da terminale" in the bar.
    func show() {
        reload()
        isShown = true
    }

    /// Chiudi.
    func dismiss() {
        isShown = false
        dismissed = true
    }

    /// The VM stopped: the panel goes with its screen.
    func vmStopped() {
        isShown = false
        isTyping = false
    }

    // MARK: - Digita nella VM

    /// This Mac's keyboard layout could not be read: nothing is typed.
    func reportLayoutUnavailable() {
        typingMessage = nil
        typingError = String(localized: "This Mac’s keyboard layout can’t be read: type the command yourself in the VM.")
    }

    /// Types the authorize command into the guest through `sink`, with keys from `layout`.
    /// Nothing is sent when the key is not typable or a character has no key on the layout.
    func typeCommand(into sink: any KeystrokeSink, layout: some KeyboardLayout) async {
        guard !isTyping else { return }
        typingMessage = nil
        typingError = nil
        do throws(KeystrokeError) {
            let command = try GuestKeystrokes.authorizeCommand(publicKey: publicKey ?? "")
            let strokes = try GuestKeystrokes.keystrokes(for: command, layout: layout)
            isTyping = true
            defer { isTyping = false }
            do {
                try await sink.type(strokes)
                typingMessage = String(localized: "Command typed in the VM: press Return in the VM’s Terminal.")
            } catch {
                typingError = error.localizedDescription
            }
        } catch {
            typingError = error.localizedDescription
        }
    }
}

/// The panel beside the guest's screen (S07 macOS · Accesso da terminale).
struct TerminalAccessPanel: View {
    let model: TerminalAccessModel
    /// "Digita nella VM": the window types into its screen (nil while no screen is shown).
    let onType: (() -> Void)?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                HStack(spacing: Theme.Space.s) {
                    Text(verbatim: model.title)
                        .font(.nido(Theme.TypeSize.headline, .semibold))
                        .foregroundStyle(Theme.Color.textPrimary)
                    Spacer(minLength: 0)
                    NidoButton("Close") { model.dismiss() }
                        .accessibilityIdentifier("terminal-access-close")
                }
                caption(model.intro)
                ForEach(model.steps, id: \.number) { step in
                    stepRow(step)
                }
                caption(model.footnote)
            }
            .padding(Theme.Space.l)
        }
        .frame(width: Theme.Layout.terminalAccessPanelWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.Color.surface)
        .overlay(alignment: .leading) {
            Rectangle().fill(Theme.Color.border).frame(width: Theme.Layout.hairline)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("terminal-access")
    }

    private func caption(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.nido(Theme.TypeSize.caption))
            .foregroundStyle(Theme.Color.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func stepRow(_ step: TerminalAccessModel.Step) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.s) {
            Text(step.number, format: .number)
                .font(.nido(Theme.TypeSize.caption, .semibold))
                .foregroundStyle(Theme.Color.accentText)
                .frame(width: Theme.Layout.stepNumberSize, height: Theme.Layout.stepNumberSize)
                .background(Theme.Color.accent, in: Circle())
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text(verbatim: step.title)
                    .font(.nido(Theme.TypeSize.body, .semibold))
                    .foregroundStyle(Theme.Color.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                caption(step.detail)
                switch step.number {
                case 3: authorizeBlock
                case 4:
                    NidoCommandBlock(command: model.sshCommand, actionLabel: String(localized: "Copy"), identifier: "terminal-access-ssh") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(model.sshCommand, forType: .string)
                    }
                default: EmptyView()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("terminal-access-step-\(step.number)")
    }

    @ViewBuilder private var authorizeBlock: some View {
        NidoCommandBlock(
            command: model.authorizeCommand,
            actionLabel: model.isTyping ? String(localized: "Typing…") : String(localized: "Type in VM"),
            isActionEnabled: model.canType && onType != nil,
            identifier: "terminal-access-authorize"
        ) { onType?() }
        if let problem = model.keyProblem {
            status(problem, color: Theme.Color.statusError, identifier: "terminal-access-key-problem")
        } else if let error = model.typingError {
            status(error, color: Theme.Color.statusError, identifier: "terminal-access-typing-error")
        } else if let message = model.typingMessage {
            status(message, color: Theme.Color.textSecondary, identifier: "terminal-access-typed")
        } else {
            caption(model.layoutNote)
        }
    }

    private func status(_ text: String, color: Color, identifier: String) -> some View {
        Text(verbatim: text)
            .font(.nido(Theme.TypeSize.caption, .semibold))
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier(identifier)
    }
}

/// ScreensMac.swift `commandBlock`: a command in the console font on its own box, with an
/// optional action button (Copia, "Digita nella VM").
struct NidoCommandBlock: View {
    let command: String
    var actionLabel: String?
    var isActionEnabled = true
    var identifier = "command-block"
    var action: (() -> Void)?

    init(command: String, actionLabel: String? = nil, isActionEnabled: Bool = true,
         identifier: String = "command-block", action: (() -> Void)? = nil) {
        self.command = command
        self.actionLabel = actionLabel
        self.isActionEnabled = isActionEnabled
        self.identifier = identifier
        self.action = action
    }

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Text(verbatim: command)
                .font(.system(size: Theme.TypeSize.caption, design: .monospaced))
                .foregroundStyle(Theme.Color.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let actionLabel, let action {
                NidoButton(verbatim: actionLabel, action: action)
                    .disabled(!isActionEnabled)
                    .accessibilityIdentifier("\(identifier)-action")
            }
        }
        .padding(Theme.Space.s)
        .background(Theme.Color.background, in: RoundedRectangle(cornerRadius: Theme.Radius.s))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.s)
                .strokeBorder(Theme.Color.border, lineWidth: Theme.Layout.hairline)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }
}
