// SPDX-License-Identifier: Apache-2.0
import NidoCore
import SwiftUI

/// S14: the provisioning of a VM just created, a panel floating over its console (the VM stays
/// usable underneath). Phase 1 collapses to one row when done; phase 2 shows Ollama, the model
/// (with the download's progress) and the check; errors offer Riprova, the log, the Terminal.
struct ProvisioningProgressView: View {
    let provisioning: ProvisioningModel
    let aiRuntime: AIRuntimeModel
    /// "Installa Guest Tools" when phase 1 did not finish (the VM's one model).
    var guestTools: GuestToolsModel?
    let onOpenTerminal: () -> Void
    var onOpenSettings: () -> Void = {}
    let onOpenAI: () -> Void

    @State private var showsLog = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text(verbatim: provisioning.title)
                    .font(.nido(Theme.TypeSize.headline, .semibold))
                    .foregroundStyle(Theme.Color.textPrimary)
                Text(verbatim: provisioning.subtitle)
                    .font(.nido(Theme.TypeSize.caption))
                    .foregroundStyle(Theme.Color.textSecondary)
            }
            steps
            if let phase1 = provisioning.phase1FailureText {
                NidoNotice(kind: .error, verbatim: phase1.title, detail: phase1.detail, identifier: "provisioning-phase1-error")
                if let guestTools {
                    GuestToolsFeedback(tools: guestTools, onOpenTerminal: onOpenTerminal, onOpenSettings: onOpenSettings)
                }
            } else if let failure = provisioning.failure {
                NidoNotice(kind: .error, verbatim: failure.title, detail: failure.detail,
                           identifier: "provisioning-error")
            } else if let caption = provisioning.caption {
                Text(verbatim: caption)
                    .font(.nido(Theme.TypeSize.caption))
                    .foregroundStyle(Theme.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if showsLog { log }
            actions
        }
        .padding(Theme.Space.l)
        .frame(width: showsLog ? Theme.Layout.provisioningPanelWideWidth : Theme.Layout.provisioningPanelWidth,
               alignment: .leading)
        .background(Theme.Color.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.m))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.m)
            .strokeBorder(Theme.Color.border, lineWidth: Theme.Layout.hairline))
        .shadow(color: Theme.Layout.sheetShadowColor,
                radius: Theme.Layout.sheetShadowRadius, y: Theme.Layout.sheetShadowY)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("provisioning-panel")
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            if !provisioning.guestReady { groupLabel("Phase 1 · first boot", spaceAbove: false) }
            ForEach(provisioning.phase1Rows, id: \.self) { row in
                NidoProvisioningStep(verbatim: row.label, state: row.state, status: row.status)
            }
            if !provisioning.phase2Rows.isEmpty {
                groupLabel("Phase 2 · after the start", spaceAbove: true)
                ForEach(provisioning.phase2Rows, id: \.self) { row in
                    NidoProvisioningStep(verbatim: row.label, state: row.state, status: row.status)
                    if row.state == .running, row.label == provisioning.modelRowLabel, let progress = provisioning.pullProgress {
                        NidoMeter(fraction: progress.fraction)
                        Text(verbatim: progress.detail)
                            .font(.nido(Theme.TypeSize.caption))
                            .foregroundStyle(Theme.Color.textSecondary)
                            .monospacedDigit()
                    }
                }
            }
        }
    }

    private func groupLabel(_ text: LocalizedStringKey, spaceAbove: Bool) -> some View {
        Text(text)
            .font(.nido(Theme.TypeSize.caption, .semibold))
            .foregroundStyle(Theme.Color.textSecondary)
            .padding(.top, spaceAbove ? Theme.Space.s : 0)
    }

    private var log: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            // A short log takes its own height, from the top (as in the design); a long one
            // scrolls, showing its last lines first.
            ViewThatFits(in: .vertical) {
                logText
                ScrollView { logText }
                    .defaultScrollAnchor(.bottom)
            }
            .frame(maxHeight: Theme.Layout.logMaxHeight)
            .background(Theme.Console.background, in: RoundedRectangle(cornerRadius: Theme.Radius.s))
            Text("/var/log/nido-provision.log in \(provisioning.name) · last lines, read over SSH")
                .font(.nido(Theme.TypeSize.caption))
                .foregroundStyle(Theme.Color.textSecondary)
        }
        .accessibilityIdentifier("provisioning-log")
    }

    private var logText: some View {
        Text(verbatim: aiRuntime.log ?? (aiRuntime.isReadingLog ? String(localized: "Reading the log…") : ""))
            .font(.system(size: Theme.Layout.logFontSize, design: .monospaced))
            .foregroundStyle(Theme.Console.foreground)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Space.m)
    }

    /// The buttons on one line when the language lets them fit; otherwise one under the other at
    /// the trailing edge (German runs long), never truncated.
    private var actions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Theme.Space.s) {
                Spacer(minLength: 0)
                actionButtons
            }
            VStack(alignment: .trailing, spacing: Theme.Space.s) { actionButtons }
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    @ViewBuilder private var actionButtons: some View {
        if provisioning.phase1Failed {
            button("Hide", id: "hide") { provisioning.dismiss() }
            if let guestTools {
                button(guestTools.isBusy ? "Installing…" : "Install Guest Tools", kind: .primary, id: "install-guest-tools") {
                    Task { await guestTools.install() }
                }
                .disabled(guestTools.isBusy)
            }
        } else if let failure = provisioning.failure {
            declineButton
            if failure.offersTerminal {
                button("Try Again", id: "retry") { Task { await provisioning.retry() } }
                button("Open Terminal", kind: .primary, id: "terminal", action: onOpenTerminal)
            } else {
                logButton
                button("Try Again", kind: .primary, id: "retry") { Task { await provisioning.retry() } }
            }
        } else if provisioning.isComplete {
            button("Close", id: "close") { provisioning.dismiss() }
            if provisioning.plan != nil {
                button("Open AI View", kind: .primary, id: "open-ai") {
                    provisioning.dismiss()
                    onOpenAI()
                }
            }
        } else if provisioning.isRunning {
            logButton
            button("Stop Waiting", id: "stop-waiting") { provisioning.stopWaiting() }
        } else {
            if provisioning.guestReady { logButton }
            if provisioning.plan != nil { declineButton }
            button("Hide", id: "hide") { provisioning.dismiss() }
        }
    }

    /// "Non installare": phase 2 is given up, and its record in the VM's config goes.
    private var declineButton: some View {
        button("Don’t Install", id: "decline") { Task { await provisioning.decline() } }
    }

    private var logButton: some View {
        button(showsLog ? "Hide Log" : "Show Log", id: "log") {
            showsLog.toggle()
            if showsLog { Task { await aiRuntime.readLog() } }
        }
    }

    private func button(_ label: LocalizedStringKey, kind: NidoButton.Kind = .secondary, id: String,
                        action: @escaping () -> Void) -> some View {
        NidoButton(label, kind: kind, action: action)
            .accessibilityIdentifier("provisioning-\(id)")
    }
}
