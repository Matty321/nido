// SPDX-License-Identifier: Apache-2.0
import NidoCore
import SwiftUI

/// The Network view of a VM window: what the VM's network is, its connection log newest first, and
/// "Allow" on the blocks that name a domain. Read only while shown.
struct NetworkLogView: View {
    @Bindable var model: NetworkLogModel
    /// The system does not allow Nido's notifications: blocks are only here (and counted on the
    /// Network tab until it is opened).
    let notificationsOff: Bool
    let onSeen: () -> Void
    let onOpenSettings: () -> Void
    /// The VM's Guest Tools actions: the "Turn Off" suggestion for a VM created before 0.7.4.
    var guestTools: GuestToolsModel?

    /// "Turn Off" was pressed here: its outcome is shown here (not the outcomes of S08 or the Monitor).
    @State private var quietRequested = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            header
            if let message = model.message {
                NidoNotice(kind: model.messageIsError ? .error : .info, verbatim: message,
                           actionLabel: String(localized: "Close"), action: { model.dismissMessage() }, identifier: "network-message")
            }
            log
            if let hidden = model.hiddenNoiseText {
                Text(hidden)
                    .font(.nido(Theme.TypeSize.caption))
                    .foregroundStyle(Theme.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("network-hidden-noise")
            }
        }
        .padding(Theme.Space.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.Color.background)
        .task { await model.watch(onRefresh: onSeen) }
        .task { await guestTools?.load() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("network-view")
    }

    @ViewBuilder private var header: some View {
        if model.network == .malformed {
            NidoNotice(kind: .error, verbatim: String(localized: "Invalid domain list"), detail: model.networkSummary,
                       actionLabel: String(localized: "Open VM Settings"), action: onOpenSettings, identifier: "network-malformed")
        } else if case .interrupted = model.network {
            NidoNotice(kind: .error, verbatim: String(localized: "Controlled network interrupted"), detail: model.networkSummary,
                       identifier: "network-interrupted")
        } else {
            NidoNotice(kind: .info, verbatim: title, detail: model.networkSummary,
                       actionLabel: String(localized: "Allowed Domains…"), action: onOpenSettings, identifier: "network-summary")
        }
        if notificationsOff {
            NidoNotice(kind: .warning, title: "Nido’s notifications are turned off",
                       detail: "Blocks stay in this log and the Network tab shows how many there are until you open it. To get notices: System Settings › Notifications › Nido.",
                       identifier: "network-notifications-off")
        }
        if let tools = guestTools { quietSuggestion(tools) }
        NidoToggleRow(
            title: "Blocks only",
            explanation: model.blockedOnly
                ? "The log shows blocks, cut connections and summaries. Turn this off to also see the allowed connections."
                : "The log also shows the allowed connections, with the bytes sent and received.",
            isOn: $model.blockedOnly)
            .accessibilityIdentifier("network-blocked-only")
    }

    @ViewBuilder private func quietSuggestion(_ tools: GuestToolsModel) -> some View {
        if tools.suggestsQuieting {
            NidoNotice(
                kind: .info, verbatim: String(localized: "Background requests still on"), detail: tools.quietSuggestion,
                actionLabel: tools.busy == .quiet ? String(localized: "Turning Off…") : String(localized: "Turn Off"),
                action: {
                    quietRequested = true
                    Task { await tools.quietBackground() }
                },
                identifier: "network-quiet", secondaryLabel: String(localized: "Not Now"),
                secondaryAction: { Task { await tools.declineQuieting() } })
                .disabled(tools.isBusy)
        }
        if quietRequested, !tools.isBusy {
            if let failure = tools.failure {
                NidoNotice(kind: .error, verbatim: failure.title, detail: failure.detail,
                           actionLabel: String(localized: "Open VM Settings"), action: onOpenSettings, identifier: "network-quiet-failure")
            } else if let message = tools.message {
                NidoNotice(kind: .info, verbatim: message, actionLabel: String(localized: "Close"),
                           action: { quietRequested = false }, identifier: "network-quiet-done")
            }
        }
    }

    private var title: String {
        switch model.network {
        case .nat: String(localized: "Apple network")
        case .controlled: String(localized: "Controlled network")
        default: String(localized: "Network")
        }
    }

    @ViewBuilder private var log: some View {
        if model.rows.isEmpty {
            Text(model.emptyText)
                .font(.nido(Theme.TypeSize.body))
                .foregroundStyle(Theme.Color.textSecondary)
                .padding(.vertical, Theme.Space.m)
                .accessibilityIdentifier("network-empty")
            Spacer(minLength: 0)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.rows) { row in
                        rowView(row)
                        Rectangle().fill(Theme.Color.border).frame(height: Theme.Layout.hairline)
                    }
                }
            }
            .background(Theme.Color.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.m))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.m)
                .strokeBorder(Theme.Color.border, lineWidth: Theme.Layout.hairline))
            .accessibilityIdentifier("network-log")
        }
    }

    /// Every outcome the log can show, in the app's language.
    private static let outcomes = Set(EgressLogEntry.Verdict.allCases.map(EgressNoticeText.outcome)).sorted()

    private func rowView(_ row: NetworkLogModel.Row) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.m) {
            // As wide as the widest time of the language (en: "12/28, 10:58:58 PM"), so the next
            // columns do not move from row to row; the same width as before where every time has
            // the same length (it, de, es, fr).
            ZStack(alignment: .leading) {
                ForEach(NetworkLogModel.timeSamples, id: \.self) { Text(verbatim: $0).hidden() }
                Text(row.time)
                    .foregroundStyle(Theme.Color.textSecondary)
            }
            .font(.nido(Theme.TypeSize.caption))
            .monospacedDigit()
            .fixedSize()
            // As wide as the widest outcome of the language, at least the design's column: German
            // "unterbrochen" and Spanish "interrumpida" do not fit in it.
            ZStack(alignment: .leading) {
                ForEach(Self.outcomes, id: \.self) { Text(verbatim: $0).hidden() }
                Text(row.outcome)
                    .foregroundStyle(row.isBlock ? Theme.Color.statusError : Theme.Color.statusRunning)
            }
            .font(.nido(Theme.TypeSize.caption, .semibold))
            .fixedSize()
            .frame(minWidth: Theme.Layout.networkOutcomeColumn, alignment: .leading)
            Text(row.proto)
                .font(.nido(Theme.TypeSize.caption))
                .foregroundStyle(Theme.Color.textSecondary)
                .frame(width: Theme.Layout.networkProtoColumn, alignment: .leading)
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text(row.destination)
                    .font(.nido(Theme.TypeSize.body, .semibold))
                    .foregroundStyle(Theme.Color.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Text(row.detail)
                    .font(.nido(Theme.TypeSize.caption))
                    .foregroundStyle(Theme.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let domain = row.allowDomain {
                NidoButton("Allow…") { Task { await model.allow(domain) } }
                    .disabled(model.isAllowing)
                    .help("Adds exactly \(domain) to the allowed domains, after Touch ID or the Mac password.")
                    .accessibilityLabel("Allow \(domain)")
                    .accessibilityIdentifier("network-allow-\(row.id)")
            }
        }
        .padding(.vertical, Theme.Space.s)
        .padding(.horizontal, Theme.Space.m)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: "\(row.outcome), \(row.destination)"))
        .accessibilityIdentifier("network-row-\(row.id)")
    }
}
