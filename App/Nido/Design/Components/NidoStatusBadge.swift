// SPDX-License-Identifier: Apache-2.0
import SwiftUI

/// Components.swift StatusBadge: a coloured dot and a label for each VM state.
struct NidoStatusBadge: View {
    enum Status: Hashable, Sendable {
        case stopped, starting, running, paused, error, unreadable
        /// Stopped with its state saved (`state.vzvmsave`): the next start resumes it.
        case suspended
        /// This app holds the VM's lock for a snapshot of the stopped VM or a clone ("Occupata").
        case busy
        /// A macOS VM being installed from an IPSW (no bundle yet): hollow, nothing runs.
        case installing

        /// The badge's words: adjectives that agree with "the VM" (feminine in it, es, fr).
        var label: LocalizedStringResource {
            switch self {
            case .stopped: LocalizedStringResource("Stopped", comment: "VM state badge.")
            case .starting: LocalizedStringResource("Starting", comment: "VM state badge.")
            case .running: LocalizedStringResource("Running", comment: "VM state badge.")
            case .paused: LocalizedStringResource("Paused", comment: "VM state badge.")
            case .error: LocalizedStringResource("Error", comment: "VM state badge.")
            case .unreadable: LocalizedStringResource("Unreadable", comment: "VM state badge: its configuration can’t be read.")
            case .suspended: LocalizedStringResource("Suspended", comment: "VM state badge: its state is saved on disk.")
            case .busy: LocalizedStringResource("Busy", comment: "VM state badge: a snapshot or clone holds the VM.")
            case .installing: LocalizedStringResource("Installing", comment: "VM state badge: macOS is being installed.")
            }
        }

        var color: Color {
            switch self {
            case .stopped: Theme.Color.statusStopped
            case .starting, .busy, .installing: Theme.Color.accent
            case .running: Theme.Color.statusRunning
            case .paused, .suspended: Theme.Color.statusPaused
            case .error, .unreadable: Theme.Color.statusError
            }
        }
    }

    let status: Status
    /// Replaces the status's own label ("Running (Terminal)").
    private let label: Text?

    init(status: Status) {
        self.status = status
        self.label = nil
    }

    init(status: Status, label: LocalizedStringKey) {
        self.status = status
        self.label = Text(label)
    }

    /// `label` shown as given; nil shows the status's own label.
    init(status: Status, verbatim label: String?) {
        self.status = status
        self.label = label.map { Text(verbatim: $0) }
    }

    var body: some View {
        HStack(spacing: Theme.Space.xs) {
            dot
            (label ?? Text(status.label))
                .font(.nido(Theme.TypeSize.caption, .semibold))
                .foregroundStyle(Theme.Color.textPrimary)
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, Theme.Space.s)
        .frame(height: Theme.Layout.badgeHeight)
        .background(Theme.Color.surfaceRaised, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.Color.border, lineWidth: Theme.Layout.hairline))
    }

    @ViewBuilder private var dot: some View {
        // Hollow: nothing runs (unreadable; suspended, its state on the disk).
        if status == .unreadable || status == .suspended || status == .installing {
            Circle()
                .strokeBorder(status.color, lineWidth: Theme.Layout.badgeHollowDotStroke)
                .frame(width: Theme.Layout.badgeDot, height: Theme.Layout.badgeDot)
        } else {
            Circle()
                .fill(status.color)
                .frame(width: Theme.Layout.badgeDot, height: Theme.Layout.badgeDot)
        }
    }
}
