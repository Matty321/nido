// SPDX-License-Identifier: Apache-2.0
import AppKit
import NidoCore
import SwiftUI

/// S10: the app's preferences (the `Settings` scene, ⌘,). Generale: the VM folder (shared with
/// the `nido` command, read-only); Hugging Face: the token of the AI bridge (Keychain).
struct PreferencesView: View {
    /// nil when the app only hosts the unit tests.
    let root: URL?
    /// The VMs' session store, for "VM con il ponte AI attivo"; nil without an environment.
    var sessions: VMSessionStore?
    /// Sparkle's updater; nil without a feed in the build: no "Cerca aggiornamenti automaticamente".
    var updates: UpdateController?

    @State private var section = "Generale"
    @State private var token: HuggingFaceTokenModel

    init(
        root: URL?, tokenStore: (any TokenStore)? = nil, sessions: VMSessionStore? = nil,
        updates: UpdateController? = nil
    ) {
        self.root = root
        self.sessions = sessions
        self.updates = updates
        _token = State(initialValue: HuggingFaceTokenModel(tokenStore: tokenStore))
    }

    var body: some View {
        // The sections' ids are the Italian names they always had (`settings-section-<id>`).
        NidoSettingsShell(
            verbatim: String(localized: "Nido Settings"),
            sections: [.init(verbatim: Self.sectionTitle("Generale"), id: "Generale"),
                       .init(verbatim: "Hugging Face"),
                       .init(verbatim: Self.sectionTitle("Informazioni"), id: "Informazioni", isEnabled: false)],
            selection: $section,
            heading: Self.sectionTitle(section),
            intro: section == "Hugging Face" ? Self.huggingFaceIntro
                : String(localized: "Nido keeps the VMs in a folder it shares with the nido command.")
        ) {
            if section == "Hugging Face" {
                HuggingFaceTokenView(
                    model: token, activeBridgeVMs: sessions?.activeBridgeNames ?? [])
            } else {
                NidoPickerRow(label: "VM folder", path: [Self.display(root), String(localized: "read only")].joined(separator: " · "),
                              buttonLabel: "Show in Finder", onChoose: showInFinder)
                NidoInfoRow("Version", Self.versionText())
                if let updates {
                    @Bindable var updates = updates
                    NidoToggleRow(
                        verbatim: String(localized: "Check for updates automatically"),
                        explanation: Self.automaticChecksExplanation,
                        isOn: $updates.automaticallyChecksForUpdates)
                }
                NidoInfoRow("License", "Apache License 2.0", note: "Nido is free software: its code is public.")
            }
        }
        .navigationTitle(Text("Nido Settings"))
    }

    nonisolated static func sectionTitle(_ id: String) -> String {
        switch id {
        case "Generale": String(localized: "General")
        case "Informazioni": String(localized: "About")
        default: id  // Hugging Face: a name, never translated.
        }
    }

    nonisolated static var automaticChecksExplanation: String {
        String(localized: "Once a day Nido checks for a new version and asks before installing it. With a VM running, the installation waits.")
    }

    nonisolated static var huggingFaceIntro: String {
        String(localized: "One token for all VMs, used only by the AI bridge to reach router.huggingface.co. Nido keeps it in the Mac’s Keychain: it never reaches the VMs, the logs or error messages.")
    }

    private func showInFinder() {
        guard let root else { return }
        NSWorkspace.shared.activateFileViewerSelecting([root])
    }

    /// The path with the home directory as "~", as the design shows it.
    nonisolated static func display(_ url: URL?) -> String {
        guard let url else { return "" }
        return (url.path as NSString).abbreviatingWithTildeInPath
    }

    nonisolated static func versionText(bundle: Bundle = .main) -> String {
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        return "Nido \(version)"
    }
}
