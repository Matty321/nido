// SPDX-License-Identifier: Apache-2.0
import SwiftUI

/// Components.swift VMCard: one card per VM in the library, with the actions of its state.
struct NidoVMCard<Actions: View>: View {
    typealias State = NidoVMCardState

    let name: String
    /// "Debian 13 · arm64", "Ubuntu 26.04 LTS · arm64", or "Sistema sconosciuto".
    let system: String
    /// The system of the mark ("D", "U", "M", or "?": `NidoSystemMark.System(glyph:)`).
    let glyph: String
    /// The VM's own tint (Settings › General › Color).
    var tint: VMTint = .graphite
    /// "4 CPU · 8 GiB di memoria · disco 64 GiB".
    let resources: String
    let state: State
    /// "AI bridge active" under the name (a running VM whose AI bridge is on).
    var bridgeActive = false
    /// Double click on the card's text (never on its buttons, whose clicks are their own).
    var onDoubleClick: (() -> Void)?
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                header
                Text(resources)
                    .font(.nido(Theme.TypeSize.caption))
                    .foregroundStyle(Theme.Color.textSecondary)
                if case .busy(let reason) = state {
                    Text(reason)
                        .font(.nido(Theme.TypeSize.caption, .semibold))
                        .foregroundStyle(Theme.Color.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if case .installing(let progress, let fraction) = state {
                    // The installation's progress, as in the wizard (percentage and time left).
                    VStack(alignment: .leading, spacing: Theme.Space.xs) {
                        Text(progress)
                            .font(.nido(Theme.TypeSize.caption, .semibold))
                            .foregroundStyle(Theme.Color.textSecondary)
                            .monospacedDigit()
                            .lineLimit(1)
                            .accessibilityIdentifier("install-progress")
                        NidoMeter(fraction: fraction)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let message = state.message {
                    Text(message)
                        .font(.nido(Theme.TypeSize.caption, .semibold))
                        .foregroundStyle(Theme.Color.statusError)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { onDoubleClick?() }
            HStack(spacing: Theme.Space.s) {
                actions()
            }
        }
        .padding(Theme.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Color.surface, in: shape)
        .overlay(shape.strokeBorder(Theme.Color.border, lineWidth: Theme.Layout.hairline))
        .contentShape(shape)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(name)
        .accessibilityLabel(name)
    }

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: Theme.Radius.m) }

    private var header: some View {
        HStack(alignment: .center, spacing: Theme.Space.m) {
            NidoSystemMark(system: .init(glyph: glyph), tint: tint, size: Theme.Layout.cardGlyph)
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text(name)
                    .font(.nido(Theme.TypeSize.headline, .semibold))
                    .foregroundStyle(Theme.Color.textPrimary)
                    .lineLimit(1)
                Text(system)
                    .font(.nido(Theme.TypeSize.caption))
                    .foregroundStyle(Theme.Color.textSecondary)
                    .lineLimit(1)
                if bridgeActive { NidoBridgePill() }
                if state == .runningTerminal {
                    // The longer label goes under the name, where it has the width of the card.
                    NidoStatusBadge(status: .running, label: "Running (Terminal)")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if state != .runningTerminal {
                NidoStatusBadge(status: state.badge)
            }
        }
    }
}

/// Every state of the design. The library derives stopped, running, runningTerminal and
/// unreadable from the registry; starting, paused and error come from a live session; busy from
/// a snapshot or clone of this app.
enum NidoVMCardState: Hashable, Sendable {
    case stopped
    case starting
    case running
    /// Started with `nido start`: it runs in the Terminal's process.
    case runningTerminal
    case paused
    /// Stopped with a saved state: Riprendi resumes it.
    case suspended
    case error(String)
    case unreadable(String)
    /// "Occupata": this app holds the lock of the stopped VM for a snapshot or a clone; the
    /// reason ("Snapshot in corso", "Clonazione in corso") is shown on the card.
    case busy(String)
    /// "Installazione": a macOS VM being installed (M3b), with its progress line and fraction.
    case installing(String, Double)

    var badge: NidoStatusBadge.Status {
        switch self {
        case .stopped: .stopped
        case .starting: .starting
        case .running, .runningTerminal: .running
        case .paused: .paused
        case .suspended: .suspended
        case .error: .error
        case .unreadable: .unreadable
        case .busy: .busy
        case .installing: .installing
        }
    }

    /// The red line above the actions.
    var message: String? {
        switch self {
        case .error(let message), .unreadable(let message): message
        default: nil
        }
    }
}
