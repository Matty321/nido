// SPDX-License-Identifier: Apache-2.0
import SwiftUI

/// "An agent is using this VM", drawn over the window's title strip (in full screen, at the top
/// of the display) while an agent drives the VM (`VMWindowModel.agentActive`). It is an overlay
/// in the notice's info style, small enough for the 28 pt strip, so the screen below never
/// changes size when it comes and goes. It takes no clicks; there is no lock.
///
/// While an agent's rollback runs (`VMWindowModel.rollbackBanner`) it says where the agent is
/// going back to instead: the VM stops and starts again under it.
struct AgentBanner: View {
    /// "The agent is going back to <checkpoint>…", or nil for the usual text.
    var rollback: String?

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Circle()
                .fill(Theme.Color.accent)
                .frame(width: Theme.Layout.noticeDot, height: Theme.Layout.noticeDot)
                .accessibilityHidden(true)
            Group {
                if let rollback {
                    Text(verbatim: rollback)
                        .truncationMode(.middle)
                } else {
                    Text("An agent is using this VM")
                }
            }
            .font(.nido(Theme.TypeSize.caption, .semibold))
            .foregroundStyle(Theme.Color.textPrimary)
            .lineLimit(1)
        }
        .padding(.horizontal, Theme.Space.m)
        .frame(height: Theme.Layout.titleBarHeight - Theme.Space.s)
        .background(Theme.Color.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.m))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.m)
                .strokeBorder(Theme.Color.border, lineWidth: Theme.Layout.hairline)
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(rollback == nil ? "agent-banner" : "agent-rollback-banner")
        .transition(.opacity)
    }
}

/// Nido Agent's first-run setup after a provisioned start (`VMWindowModel.firstRunSetup`): a thin
/// strip like `AgentBanner`, over the window's title strip. It takes no clicks.
struct FirstRunSetupStrip: View {
    let state: VMWindowModel.FirstRunSetup
    /// A non-fatal notice that replaces "set up" (the key works, the password was not kept).
    var notice: String?

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Circle()
                .fill(dot)
                .frame(width: Theme.Layout.noticeDot, height: Theme.Layout.noticeDot)
                .accessibilityHidden(true)
            Text(verbatim: text)
                .font(.nido(Theme.TypeSize.caption, .semibold))
                .foregroundStyle(Theme.Color.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, Theme.Space.m)
        .frame(height: Theme.Layout.titleBarHeight - Theme.Space.s)
        .background(Theme.Color.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.m))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.m)
                .strokeBorder(Theme.Color.border, lineWidth: Theme.Layout.hairline)
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
        .accessibilityIdentifier("first-run-setup")
        .transition(.opacity)
    }

    private var text: String {
        switch state {
        case .working(let line): line
        case .done: notice ?? String(localized: "Nido Agent is set up.")
        case .failed(let message): message
        }
    }

    private var dot: Color {
        if case .failed = state { return Theme.Color.statusError }
        return Theme.Color.accent
    }
}
