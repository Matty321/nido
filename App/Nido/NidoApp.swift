// SPDX-License-Identifier: Apache-2.0
@_spi(Testing) import NidoCore
import SwiftUI

@main
struct NidoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    private var setup: AppSetup { appDelegate.setup }

    var body: some Scene {
        Window(Text(verbatim: "Nido"), id: "library") {
            Group {
                switch setup.result {
                case .success(let environment):
                    LibraryView(environment: environment)
                case .failure(let error):
                    StartupErrorView(message: error.localizedDescription)
                case nil:
                    // Host of the unit tests: no environment, the VM root is never touched.
                    Color.clear
                }
            }
            .frame(minWidth: Theme.Layout.windowMinWidth, minHeight: Theme.Layout.windowMinHeight)
            .background(Theme.Color.background)
            .ignoresSafeArea(.container, edges: .top)
        }
        .defaultSize(width: Theme.Layout.windowWidth, height: Theme.Layout.windowHeight)
        // Hidden title bar like the VM window: a (transparent) window toolbar would sit over the
        // library's bar and swallow the clicks on the search field and "Nuova VM".
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandLinkCommands(updates: (try? setup.result?.get())?.updates)
            ReleaseNotesCommands()
        }

        // "What’s New in Nido": opened by the library at the first launch of a new version, and from
        // the Help menu.
        Window("What’s New in Nido", id: ReleaseNotesWindow.id) {
            ReleaseNotesView()
        }
        .windowResizability(.contentSize)
        .restorationBehavior(.disabled)

        // One window per VM: the value is the VM name, so opening it again brings it to the front.
        WindowGroup("Virtual Machine", id: VMWindow.id, for: String.self) { $name in
            VMWindowRoot(name: name, environment: try? setup.result?.get())
                .frame(minWidth: Theme.Layout.windowMinWidth, minHeight: Theme.Layout.windowMinHeight)
        }
        .defaultSize(width: Theme.Layout.windowWidth, height: Theme.Layout.windowHeight)
        .windowStyle(.hiddenTitleBar)
        // A restored VM window would show a stopped VM nobody asked for; File > New Window has no VM.
        .restorationBehavior(.disabled)
        .commandsRemoved()

        // S08: one settings window per VM, keyed by the VM name like the VM window.
        WindowGroup("VM Settings", id: VMSettingsWindow.id, for: String.self) { $name in
            VMSettingsRoot(name: name, environment: try? setup.result?.get())
                .frame(minWidth: Theme.Layout.windowMinWidth, minHeight: Theme.Layout.windowMinHeight)
                .ignoresSafeArea(.container, edges: .top)
                .toolbar {
                    ToolbarItem(placement: .navigation) { Color.clear.frame(width: 0, height: 0) }
                }
                .toolbar(removing: .title)
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        }
        .defaultSize(width: Theme.Layout.windowWidth, height: Theme.Layout.windowHeight)
        .windowToolbarStyle(.unified)
        .restorationBehavior(.disabled)
        .commandsRemoved()

        // S09: one snapshots window per VM, keyed by the VM name like the settings.
        WindowGroup("Snapshots", id: SnapshotsWindow.id, for: String.self) { $name in
            SnapshotsRoot(name: name, environment: try? setup.result?.get())
                .frame(minWidth: Theme.Layout.windowMinWidth, minHeight: Theme.Layout.windowMinHeight)
                .ignoresSafeArea(.container, edges: .top)
                .toolbar {
                    ToolbarItem(placement: .navigation) { Color.clear.frame(width: 0, height: 0) }
                }
                .toolbar(removing: .title)
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        }
        .defaultSize(width: Theme.Layout.windowWidth, height: Theme.Layout.windowHeight)
        .windowToolbarStyle(.unified)
        .restorationBehavior(.disabled)
        .commandsRemoved()

        // S10: "Settings…" (⌘,) in the app menu.
        // Same 52 pt bar as the VM settings (S08): the title is drawn by the view, in the bar.
        Settings {
            PreferencesView(
                root: (try? setup.result?.get())?.paths.root,
                tokenStore: (try? setup.result?.get())?.aiBridge.tokenStore,
                sessions: (try? setup.result?.get())?.sessions,
                updates: (try? setup.result?.get())?.updates,
                relaunch: { [appDelegate] in appDelegate.relaunch() })
                .frame(minWidth: Theme.Layout.windowMinWidth, minHeight: Theme.Layout.windowMinHeight)
                .ignoresSafeArea(.container, edges: .top)
                .toolbar {
                    ToolbarItem(placement: .navigation) { Color.clear.frame(width: 0, height: 0) }
                }
                .toolbar(removing: .title)
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
                .unifiedWindowToolbar()
        }
        .defaultSize(width: Theme.Layout.windowWidth, height: Theme.Layout.windowHeight)
        .windowToolbarStyle(.unified)
    }
}

/// Help › What’s New in Nido (Nido has no help book: the item replaces the empty one).
struct ReleaseNotesCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button("What’s New in Nido") { openWindow(id: ReleaseNotesWindow.id) }
        }
    }
}

/// Builds the environment once, from the process arguments.
@MainActor
@Observable
final class AppSetup {
    /// nil when the app only hosts the unit tests.
    let result: Result<AppEnvironment, any Error>?

    init(processInfo: ProcessInfo = .processInfo) {
        // Before any NidoCore text exists: core errors follow the app's own UI language. The test runs
        // pass `-AppleLanguages (it)`, so they resolve to Italian.
        L10n.pin(Bundle.main.preferredLocalizations.first)
        #if DEBUG
            let isDebug = true
        #else
            let isDebug = false
        #endif
        #if DEBUG
            // Only a Debug build hosts the unit tests: a Release app never looks at the variable.
            guard !Self.isHostingUnitTests(environment: processInfo.environment) else {
                result = nil
                return
            }
        #endif
        result = Result {
            try AppEnvironment(arguments: processInfo.arguments, isDebug: isDebug)
        }
    }

    /// XCTest sets `XCTestConfigurationFilePath` in the process it injects the unit-test bundle
    /// into. That process must not create the VM root or list (and sweep) the user's real VMs.
    /// An app launched by a UI test does not get the variable and uses `-NidoRoot` instead.
    #if DEBUG
        nonisolated static func isHostingUnitTests(environment: [String: String]) -> Bool {
            environment["XCTestConfigurationFilePath"] != nil
        }
    #endif
}

struct StartupErrorView: View {
    let message: String

    var body: some View {
        VStack(spacing: Theme.Space.s) {
            Text("Can’t start Nido")
                .font(.nido(Theme.TypeSize.headline, .semibold))
                .foregroundStyle(Theme.Color.textPrimary)
            Text(verbatim: message)
                .font(.nido(Theme.TypeSize.body))
                .foregroundStyle(Theme.Color.textSecondary)
        }
        .padding(Theme.Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
