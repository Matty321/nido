// SPDX-License-Identifier: Apache-2.0
import SwiftUI

/// "Agent" under the name of a running card while an agent uses the VM (like `NidoBridgePill`).
struct NidoAgentPill: View {
    var body: some View {
        HStack(spacing: Theme.Space.xs) {
            Circle().fill(Theme.Color.accent).frame(width: Theme.Layout.pillDot, height: Theme.Layout.pillDot)
            Text("Agent")
                .font(.nido(Theme.TypeSize.caption, .semibold))
                .foregroundStyle(Theme.Color.textPrimary)
        }
        .padding(.horizontal, Theme.Space.s)
        .frame(height: Theme.Layout.pillHeight)
        .background(Theme.Color.background, in: RoundedRectangle(cornerRadius: Theme.Radius.m))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.m)
            .strokeBorder(Theme.Color.accent, lineWidth: Theme.Layout.hairline))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("An agent is using this VM"))
        .accessibilityIdentifier("agent-pill")
    }
}
