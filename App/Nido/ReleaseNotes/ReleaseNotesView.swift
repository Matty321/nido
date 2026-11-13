// SPDX-License-Identifier: Apache-2.0
import NidoCore
import SwiftUI

enum ReleaseNotesWindow {
    static let id = "release-notes"
}

/// "Novità di Nido": the installed version's notes first, then the earlier ones. Opens by itself
/// at the first launch of a new version (`LibraryView`) and from Aiuto › Novità di Nido.
struct ReleaseNotesView: View {
    private let notes = ReleaseNotes.bundled()
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.xl) {
                    Text("What’s New in Nido")
                        .font(.nido(Theme.TypeSize.title, .semibold))
                        .foregroundStyle(Theme.Color.textPrimary)
                    if notes.releases.isEmpty {
                        Text("Release notes for this version aren’t available.")
                            .font(.nido(Theme.TypeSize.body))
                            .foregroundStyle(Theme.Color.textSecondary)
                    }
                    ForEach(notes.releases) { release in
                        section(release)
                    }
                }
                .padding(Theme.Space.xl)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                Text("Installed version: \(NidoVersion.current)")
                    .font(.nido(Theme.TypeSize.caption))
                    .foregroundStyle(Theme.Color.textSecondary)
                Spacer()
                NidoButton("Continue", kind: .primary) { dismissWindow(id: ReleaseNotesWindow.id) }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("release-notes-continue")
            }
            .padding(Theme.Space.l)
        }
        .frame(width: Theme.Layout.releaseNotesWidth, height: Theme.Layout.releaseNotesHeight)
        .background(Theme.Color.surface)
        .onAppear { ReleaseNotesSeen(defaults: .standard).markSeen() }
        .accessibilityIdentifier("release-notes")
    }

    private func section(_ release: ReleaseNotes.Release) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                Text(verbatim: "Nido \(release.version)")
                    .font(.nido(Theme.TypeSize.headline, .semibold))
                    .foregroundStyle(Theme.Color.textPrimary)
                if release.version == NidoVersion.current {
                    Text("This version")
                        .font(.nido(Theme.TypeSize.caption, .semibold))
                        .foregroundStyle(Theme.Color.accent)
                }
                Spacer(minLength: 0)
                if let date = release.date {
                    Text(verbatim: date)
                        .font(.nido(Theme.TypeSize.caption))
                        .foregroundStyle(Theme.Color.textSecondary)
                }
            }
            NidoMarkdown(release.body)
        }
    }
}
