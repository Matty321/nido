// SPDX-License-Identifier: Apache-2.0
import AppKit
import NidoCore
import SwiftUI

/// The Agent Activity panel (a sheet, from the VM window's toolbar and from Settings › Agent):
/// what agents did in the VM, one session after another, the newest first; each action with its
/// icon, time, one line, outcome and duration, and the thumbnail of a screenshot or a zoom (click
/// to enlarge). New actions appear while it is shown. "Clear…" deletes the log after asking.
struct AgentActivityView: View {
    @Bindable var model: AgentActivityModel
    @Environment(\.dismiss) private var dismiss

    /// The panel's size: wide enough for a row with its thumbnail, tall enough for a session.
    private static let minWidth: CGFloat = 600
    private static let idealWidth: CGFloat = 680
    private static let minHeight: CGFloat = 440
    private static let idealHeight: CGFloat = 600
    /// The icon column.
    private static let symbolWidth: CGFloat = 20

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            header
            if let error = model.errorMessage {
                NidoNotice(kind: .error, verbatim: error, actionLabel: String(localized: "Close"),
                           action: { model.dismissError() }, identifier: "agent-activity-error")
            }
            if model.isEmpty {
                Spacer(minLength: 0)
                NidoEmptyState(
                    title: "No agent activity",
                    message: "When an agent uses this VM, each of its actions appears here.",
                    identifier: "agent-activity-empty", onCreate: nil)
                    .frame(maxWidth: .infinity)
                Spacer(minLength: 0)
            } else {
                list
            }
        }
        .padding(Theme.Space.xl)
        .frame(minWidth: Self.minWidth, idealWidth: Self.idealWidth, minHeight: Self.minHeight,
               idealHeight: Self.idealHeight, alignment: .topLeading)
        .background(Theme.Color.background)
        .task { await model.watch() }
        .sheet(isPresented: confirmingClear) {
            NidoConfirmSheet(
                verbatim: model.clearQuestion,
                message: String(localized: "Every recorded action and its thumbnails are deleted. This can’t be undone."),
                actionLabel: String(localized: "Clear"), actionKind: .destructive,
                onCancel: { model.cancelClear() },
                onConfirm: { Task { await model.clear() } })
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agent-activity")
    }

    private var header: some View {
        HStack(alignment: .top, spacing: Theme.Space.m) {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text("Agent Activity")
                    .font(.nido(Theme.TypeSize.headline, .semibold))
                    .foregroundStyle(Theme.Color.textPrimary)
                Text("What agents did in \(model.name), newest first. Typed text is never recorded, only how many characters.",
                     comment: "%@ is the VM’s name.")
                    .font(.nido(Theme.TypeSize.caption))
                    .foregroundStyle(Theme.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            NidoButton("Clear…", kind: .secondary) { model.requestClear() }
                .disabled(model.isEmpty || model.isClearing)
                .accessibilityIdentifier("agent-activity-clear")
            NidoButton("Done", kind: .primary) { dismiss() }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("agent-activity-done")
        }
    }

    /// One flat lazy list: each session's heading and each of its rows is a child of its own, so
    /// a long session builds (and reads thumbnails for) only the rows on screen.
    private enum Item: Identifiable {
        case heading(AgentActivityModel.Session, isFirst: Bool)
        case row(AgentActivityModel.Row, isFirst: Bool, isLast: Bool)

        var id: String {
            switch self {
            case .heading(let session, _): "session|\(session.id)"
            case .row(let row, _, _): "row|\(row.id)"
            }
        }
    }

    private var items: [Item] {
        var items: [Item] = []
        for (index, session) in model.sessions.enumerated() {
            items.append(.heading(session, isFirst: index == 0))
            for (position, row) in session.rows.enumerated() {
                items.append(.row(row, isFirst: position == 0, isLast: position == session.rows.count - 1))
            }
        }
        return items
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(items) { item in
                    switch item {
                    case .heading(let session, let isFirst):
                        heading(session)
                            .padding(.top, isFirst ? 0 : Theme.Space.l)
                            .padding(.bottom, Theme.Space.s)
                    case .row(let row, let isFirst, let isLast):
                        card(rowView(row), isFirst: isFirst, isLast: isLast)
                    }
                }
                if let limit = model.limitText {
                    Text(verbatim: limit)
                        .font(.nido(Theme.TypeSize.caption))
                        .foregroundStyle(Theme.Color.textSecondary)
                        .padding(.top, Theme.Space.l)
                        .accessibilityIdentifier("agent-activity-limit")
                }
            }
        }
        .accessibilityIdentifier("agent-activity-list")
    }

    private func heading(_ session: AgentActivityModel.Session) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
            Text(verbatim: session.client)
                .font(.nido(Theme.TypeSize.body, .semibold))
                .foregroundStyle(Theme.Color.textPrimary)
            Text(verbatim: session.started)
                .font(.nido(Theme.TypeSize.caption))
                .monospacedDigit()
                .foregroundStyle(Theme.Color.textSecondary)
            Text(verbatim: session.shortID)
                .font(.system(size: Theme.TypeSize.caption, design: .monospaced))
                .foregroundStyle(Theme.Color.textSecondary)
                .textSelection(.enabled)
            Spacer(minLength: 0)
            Text(verbatim: session.countText)
                .font(.nido(Theme.TypeSize.caption))
                .foregroundStyle(Theme.Color.textSecondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("agent-activity-session-\(session.shortID)")
    }

    /// A row as a slice of its session's card: rounded at the card's top and bottom, the borders
    /// of two rows drawn over each other (one hairline between them).
    private func card(_ content: some View, isFirst: Bool, isLast: Bool) -> some View {
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: isFirst ? Theme.Radius.m : 0, bottomLeadingRadius: isLast ? Theme.Radius.m : 0,
            bottomTrailingRadius: isLast ? Theme.Radius.m : 0, topTrailingRadius: isFirst ? Theme.Radius.m : 0)
        return content
            .background(Theme.Color.surface, in: shape)
            .overlay(shape.strokeBorder(Theme.Color.border, lineWidth: Theme.Layout.hairline))
            .padding(.top, isFirst ? 0 : -Theme.Layout.hairline)
    }

    private func rowView(_ row: AgentActivityModel.Row) -> some View {
        HStack(alignment: .center, spacing: Theme.Space.m) {
            Image(systemName: row.symbol)
                .font(.nido(Theme.TypeSize.body))
                .foregroundStyle(row.ok ? Theme.Color.textSecondary : Theme.Color.statusError)
                .frame(width: Self.symbolWidth)
                .accessibilityHidden(true)
            HStack(alignment: .center, spacing: Theme.Space.m) {
                Text(verbatim: row.time)
                    .font(.nido(Theme.TypeSize.caption))
                    .monospacedDigit()
                    .foregroundStyle(Theme.Color.textSecondary)
                    .fixedSize()
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Text(verbatim: row.text)
                        .font(.nido(Theme.TypeSize.body))
                        .foregroundStyle(Theme.Color.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let failure = row.failure {
                        Text(verbatim: failure)
                            .font(.nido(Theme.TypeSize.caption))
                            .foregroundStyle(Theme.Color.statusError)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // One VoiceOver element for time, text and failure; the thumbnail stays its own button.
            .accessibilityElement(children: .combine)
            if row.showsThumbnail { AgentActivityThumbnail(name: row.thumbnail, load: model.thumbnailData) }
            VStack(alignment: .trailing, spacing: Theme.Space.xs) {
                Text(verbatim: row.outcome)
                    .font(.nido(Theme.TypeSize.caption, .semibold))
                    .foregroundStyle(row.ok ? Theme.Color.statusRunning : Theme.Color.statusError)
                Text(verbatim: row.duration)
                    .font(.nido(Theme.TypeSize.caption))
                    .monospacedDigit()
                    .foregroundStyle(Theme.Color.textSecondary)
            }
            .fixedSize()
            .accessibilityElement(children: .combine)
        }
        .padding(.vertical, Theme.Space.s)
        .padding(.horizontal, Theme.Space.m)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agent-activity-row-\(row.id)")
    }

    private var confirmingClear: Binding<Bool> {
        Binding(get: { model.isConfirmingClear }, set: { if !$0 { model.cancelClear() } })
    }
}

/// A screenshot's or a zoom's thumbnail in a row (click to see it at its size, 320 px on the long
/// edge), or a placeholder when it is no longer kept (the log keeps at most 1000).
private struct AgentActivityThumbnail: View {
    let name: String?
    /// `AgentActivityModel.thumbnailData`: off the main actor, never through a symlink.
    let load: (String) async -> Data?
    @State private var image: NSImage?
    @State private var loadFailed = false
    @State private var enlarged = false

    private static let width: CGFloat = 64
    private static let height: CGFloat = 40

    var body: some View {
        Group {
            if let image {
                Button { enlarged = true } label: {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: Self.width, height: Self.height)
                }
                .buttonStyle(.plain)
                .help(Text("Enlarge the thumbnail"))
                .accessibilityLabel(Text("Enlarge the thumbnail"))
                .accessibilityIdentifier("agent-activity-thumbnail")
                .popover(isPresented: $enlarged) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: image.size.width, height: image.size.height)
                        .padding(Theme.Space.s)
                }
            } else if name == nil || loadFailed {
                Image(systemName: "photo")
                    .font(.nido(Theme.TypeSize.body))
                    .foregroundStyle(Theme.Color.textSecondary)
                    .frame(width: Self.width, height: Self.height)
                    .background(Theme.Color.background)
                    .help(Text("The thumbnail is no longer kept."))
                    .accessibilityLabel(Text("The thumbnail is no longer kept."))
                    .accessibilityIdentifier("agent-activity-thumbnail-missing")
            } else {
                Theme.Color.background.frame(width: Self.width, height: Self.height)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.s))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.s)
            .strokeBorder(Theme.Color.border, lineWidth: Theme.Layout.hairline))
        .task(id: name) {
            guard let name else {
                image = nil
                return
            }
            image = await load(name).flatMap(NSImage.init(data:))
            loadFailed = image == nil
        }
    }
}
