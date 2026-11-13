// SPDX-License-Identifier: Apache-2.0
import AppKit
import NidoCore
import SwiftUI

/// The window of one VM (S07, S11), keyed by its name: `WindowGroup(for: String.self)` brings an
/// already open window to the front instead of opening a second one.
enum VMWindow {
    static let id = "vm"
}

/// Resolves the window's value (the VM name) to the model in the app's session store. The lookup
/// (a store entry, the bundle's console.log path) runs once in `.task`, never in `body`.
struct VMWindowRoot: View {
    let name: String?
    let environment: AppEnvironment?

    private struct Resolved {
        let name: VMName
        let model: VMWindowModel
        let consoleLog: URL?
        let guestTools: GuestToolsModel?
        let network: NetworkLogModel
    }

    @State private var resolved: Resolved?
    @State private var invalid = false

    var body: some View {
        Group {
            if let resolved {
                VMWindowView(model: resolved.model, consoleLog: resolved.consoleLog,
                             guestTools: resolved.guestTools, network: resolved.network, egress: environment?.egress,
                             onClosed: { environment?.sessions.windowClosed(resolved.name) })
            } else if invalid {
                StartupErrorView(message: String(localized: "Invalid virtual machine name."))
            } else {
                Theme.Color.background
            }
        }
        .task(id: name) { resolve() }
    }

    private func resolve() {
        guard let environment, let name, let vmName = try? VMName(name) else {
            invalid = true
            return
        }
        let model = environment.sessions.model(for: vmName)
        let bundle = try? VMBundle.open(vmName, paths: environment.paths)
        // "Installa Guest Tools" from the Monitor view: the VM's one model, shared with S08.
        let guestTools = environment.sessions.guestTools(for: vmName)
        let network = NetworkLogModel(name: vmName, paths: environment.paths, authenticator: environment.egress.authenticator)
        resolved = Resolved(
            name: vmName, model: model, consoleLog: bundle?.consoleLogURL, guestTools: guestTools, network: network)
    }
}

struct VMWindowView: View {
    let model: VMWindowModel
    /// Shown by "Dettagli" next to the error.
    let consoleLog: URL?
    /// "Installa Guest Tools" of the Monitor view; nil when the bundle could not be opened.
    var guestTools: GuestToolsModel?
    /// The Rete view (M3d): the VM's connection log.
    var network: NetworkLogModel?
    /// The block notices: "Apri il registro" and the counter while notifications are off.
    var egress: EgressMonitor?
    let onClosed: () -> Void

    /// The views under the toolbar (ScreensAI.swift `vmTabs`; Rete from M3d). The raw value names
    /// the tab for the UI tests (`vm-tab-<raw value>`, the Italian names they always had).
    enum Tab: String, CaseIterable {
        case screen = "Schermo"
        case monitor = "Monitor"
        case ai = "AI"
        case network = "Rete"

        var title: LocalizedStringKey {
            switch self {
            case .screen: "Screen"
            case .monitor: "Monitor"
            case .ai: "AI"
            case .network: "Network"
            }
        }
    }

    @Environment(\.openWindow) private var openWindow
    @State private var window = WindowBridge()
    @State private var showsDetails = false
    /// Full screen: the toolbar slides in while the pointer is at the top edge.
    @State private var revealsBar = false
    @State private var tab = Tab.screen
    /// The last "Apri il registro" this window followed.
    @State private var handledLogRequest: Int?
    /// The VM runs in another process (`nido start`): read off the main actor while the Monitor
    /// view is shown and this window has no machine.
    /// nil until the first read: nothing is said meanwhile (no "non in esecuzione" flash).
    @State private var runsElsewhere: Bool?
    /// The guest's screen of a macOS VM, for "Digita nella VM".
    @State private var display = MacDisplayController()

    var body: some View {
        VStack(spacing: 0) {
            if !window.isFullScreen {
                // The window's own close, minimise and zoom buttons sit in this strip.
                Color.clear.frame(height: Theme.Layout.titleBarHeight)
                toolbar
                if model.showsViewTabs { tabs }
            }
            switch window.isFullScreen || !model.showsViewTabs ? .screen : tab {
            case .screen: content
            case .monitor: monitorView
            case .ai: aiView
            case .network: networkView
            }
        }
        .overlay(alignment: .top) {
            // Placed against the whole window, as in the render (S07 "in pausa").
            if model.state == .paused, !model.isSuspending, !model.isSnapshotting {
                GeometryReader { proxy in
                    pauseNote
                        .frame(maxWidth: .infinity)
                        .padding(.top, proxy.size.height * Theme.Layout.pauseNoteTopFraction)
                }
                .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .top) {
            if window.isFullScreen { fullScreenBar }
        }
        .background(Theme.Color.surface)
        .ignoresSafeArea(.container, edges: .top)
        .background(WindowAccessor(bridge: window))
        .navigationTitle(model.name.rawValue)
        .onAppear {
            window.shouldClose = { [model] in model.confirmClose() }
            model.windowAppeared()
        }
        .onDisappear(perform: onClosed)
        .sheet(isPresented: confirmingClose) {
            NidoConfirmSheet(
                verbatim: model.closeQuestion,
                message: String(localized: "Nido asks \(model.name.rawValue) to shut down cleanly, then closes the window. If it’s still running after 30 seconds, Nido forces it to stop."),
                actionLabel: String(localized: "Stop and Close"),
                onCancel: { model.cancelClose() },
                onConfirm: {
                    Task {
                        if await model.closeConfirmed() { window.close() }
                    }
                })
        }
        .alert(Text(verbatim: model.errorTitle), isPresented: $showsDetails) {
            Button("OK") {}
        } message: {
            Text(details)
        }
        .onChange(of: window.isFullScreen) { revealsBar = false }
        .sheet(isPresented: confirmingHeadroom) {
            NidoConfirmSheet(
                verbatim: model.headroomTitle ?? "",
                message: model.headroomDetail ?? "",
                actionLabel: String(localized: "Start Anyway"),
                onCancel: { model.cancelHeadroomStart() },
                onConfirm: { Task { await model.startAnyway() } })
        }
        .task(id: tab) { await watchOtherProcess() }
        .onAppear { showRequestedLog() }
        .onChange(of: egress?.logRequest) { showRequestedLog() }
    }

    /// "Apri il registro" of a notification for this VM: the Rete view.
    private func showRequestedLog() {
        guard let request = egress?.logRequest, request.vm == model.name.rawValue, model.showsViewTabs,
            handledLogRequest != request.serial
        else { return }
        handledLogRequest = request.serial
        tab = .network
    }

    /// Blocks not looked at, shown on the Rete tab while the system does not allow notifications.
    private var unseenBlocks: Int? {
        guard let egress, egress.notificationsAllowed == false else { return nil }
        let count = egress.unseenBlocks[model.name.rawValue] ?? 0
        return count > 0 ? count : nil
    }

    @ViewBuilder private var networkView: some View {
        if let network {
            NetworkLogView(
                model: network, notificationsOff: egress?.notificationsAllowed == false,
                onSeen: { [egress, name = model.name.rawValue] in egress?.markSeen(name) },
                onOpenSettings: { openWindow(id: VMSettingsWindow.id, value: model.name.rawValue) },
                guestTools: guestTools)
        }
    }

    // MARK: - Views strip (Schermo · Monitor · AI)

    private var tabs: some View {
        HStack(spacing: Theme.Space.xl) {
            ForEach(Tab.allCases, id: \.self) { item in
                let selected = item == tab
                Button { tab = item } label: {
                    VStack(spacing: Theme.Space.s) {
                        Spacer(minLength: 0)
                        HStack(spacing: Theme.Space.xs) {
                            Text(item.title)
                                .font(.nido(Theme.TypeSize.body, selected ? .semibold : .regular))
                                .foregroundStyle(selected ? Theme.Color.textPrimary : Theme.Color.textSecondary)
                            if item == .network, let count = unseenBlocks { tabCount(count) }
                        }
                        Rectangle()
                            .fill(selected ? Theme.Color.accent : Color.clear)
                            .frame(height: Theme.Layout.viewTabUnderline)
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityValue(item == .network ? unseenBlocks.map { String(localized: "\($0) blocks without a notice") } ?? "" : "")
                .accessibilityIdentifier("vm-tab-\(item.rawValue)")
            }
            Spacer(minLength: 0)
            if model.aiBridge.isActive { NidoBridgePill() }
        }
        .padding(.horizontal, Theme.Space.l)
        .frame(height: Theme.Layout.viewTabsHeight)
        .background(Theme.Color.surface)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.Color.border).frame(height: Theme.Layout.hairline)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("vm-tabs")
    }

    /// The number of blocks without a notice, on the Rete tab.
    private func tabCount(_ count: Int) -> some View {
        Text(verbatim: count > 999 ? "999+" : count.formatted())
            .font(.nido(Theme.TypeSize.caption, .semibold))
            .monospacedDigit()
            .foregroundStyle(Theme.Color.accentText)
            .padding(.horizontal, Theme.Space.xs)
            .frame(minWidth: Theme.Layout.tabCountMinWidth)
            .background(Theme.Color.statusError, in: Capsule())
            .accessibilityHidden(true)
    }

    private var monitorView: some View {
        MonitorView(
            monitor: model.monitor, name: model.name.rawValue, guestToolsVersion: model.aiRuntime.guestToolsVersion,
            runsElsewhere: runsElsewhere, guestTools: guestTools,
            onOpenTerminal: { TerminalLauncher.openSSH(to: model.name) },
            onOpenSettings: { openWindow(id: VMSettingsWindow.id, value: model.name.rawValue) })
    }

    /// S15: Locale (Ollama in the VM) and Remoto (the AI bridge) side by side.
    private var aiView: some View {
        AISectionView(
            model: model, runsElsewhere: runsElsewhere,
            onOpenTerminal: { TerminalLauncher.openSSH(to: model.name) })
    }

    /// While the Monitor or the AI view is shown and no machine is behind this window: whether
    /// `nido start` runs the VM (the monitor and the bridge are then not available here), every
    /// 3 seconds, off the main actor.
    private func watchOtherProcess() async {
        guard tab == .monitor || tab == .ai else {
            runsElsewhere = nil
            return
        }
        let name = model.name
        let paths = model.paths
        while !Task.isCancelled {
            let elsewhere: Bool
            if model.isGone {
                elsewhere = await Task.detached {
                    guard let bundle = try? VMBundle.open(name, paths: paths) else { return false }
                    let owner = BundleLock.holder(bundle)?.owner
                    return owner == .cli
                }.value
            } else {
                elsewhere = false
            }
            if elsewhere != runsElsewhere { runsElsewhere = elsewhere }
            try? await Task.sleep(for: .seconds(3))
        }
    }

    private var confirmingHeadroom: Binding<Bool> {
        Binding(get: { model.pendingHeadroom != nil }, set: { if !$0 { model.cancelHeadroomStart() } })
    }

    // MARK: - Toolbar (Components.swift VMToolbar)

    private var toolbar: some View {
        HStack(spacing: Theme.Space.s) {
            Text(model.name.rawValue)
                .font(.nido(Theme.TypeSize.headline, .semibold))
                .foregroundStyle(Theme.Color.textPrimary)
                .lineLimit(1)
                // Name and state keep their width: the buttons collapse into "Altro" first.
                .layoutPriority(1)
            badge.layoutPriority(1)
            if !model.warnings.isEmpty { warningLabel }
            Spacer(minLength: 0)
            // Every button when they fit; otherwise the run controls and "Altro".
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Theme.Space.s) { toolbarButtons(model.toolbarButtons) }
                compactToolbar
            }
        }
        .padding(.vertical, Theme.Space.s)
        .padding(.horizontal, Theme.Space.l)
        .background(Theme.Color.surface)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.Color.border).frame(height: Theme.Layout.hairline)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("vm-toolbar")
    }

    private func toolbarButtons(_ buttons: [VMWindowModel.ToolbarButton]) -> some View {
        ForEach(buttons, id: \.action) { button in
            NidoButton(verbatim: VMWindowModel.label(for: button.action, isFullScreen: window.isFullScreen),
                       kind: button.kind) { perform(button.action) }
                .disabled(!button.isEnabled)
                .accessibilityIdentifier("vm-\(button.action)")
        }
    }

    private var compactToolbar: some View {
        let split = VMWindowModel.compactSplit(model.toolbarButtons)
        return HStack(spacing: Theme.Space.s) {
            toolbarButtons(split.visible)
            if !split.more.isEmpty {
                Menu {
                    ForEach(split.more, id: \.action) { button in
                        Button(VMWindowModel.label(for: button.action, isFullScreen: window.isFullScreen)) {
                            perform(button.action)
                        }
                        .disabled(!button.isEnabled)
                        .accessibilityIdentifier("vm-\(button.action)")
                    }
                } label: {
                    Text("More")
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .buttonStyle(NidoButtonStyle(kind: .secondary))
                .fixedSize()
                .disabled(split.more.allSatisfy { !$0.isEnabled })
                .accessibilityIdentifier("vm-more")
            }
        }
    }

    private var badge: some View {
        let (status, label): (NidoStatusBadge.Status, String?) = if model.isSuspending {
            (.suspended, String(localized: "Suspending"))
        } else if model.isSnapshotting, model.state == .paused {
            // A live snapshot pauses the VM for a few seconds while its state is saved.
            (.paused, String(localized: "Snapshot in progress"))
        } else if model.state == .stopped, model.isSuspended {
            (.suspended, nil)
        } else {
            switch model.state {
        case .starting: (.starting, nil)
        case .running: (.running, nil)
        case .pausing: (.paused, String(localized: "Pausing"))
        case .paused: (.paused, nil)
        case .resuming: (.starting, String(localized: "Resuming"))
        case .stopping: (.starting, String(localized: "Stopping"))
        case .stopped: (.stopped, nil)
        case .error: (.error, nil)
            }
        }
        return NidoStatusBadge(status: status, verbatim: label)
            .accessibilityIdentifier("vm-state")
    }

    /// What the start left out (a shared folder missing on the Mac…); the full text on hover.
    private var warningLabel: some View {
        let text = model.warnings.joined(separator: "\n")
        return Text(verbatim: model.warnings.count == 1
                    ? model.warnings[0] : String(localized: "\(model.warnings.count) warnings at startup"))
            .font(.nido(Theme.TypeSize.caption, .semibold))
            .foregroundStyle(Theme.Color.statusPaused)
            .lineLimit(1)
            .truncationMode(.tail)
            .help(text)
            .accessibilityLabel(text)
            .accessibilityIdentifier("vm-warnings")
    }

    /// S11: the same toolbar over the console, shown while the pointer is at the top edge.
    @ViewBuilder private var fullScreenBar: some View {
        if revealsBar {
            toolbar
                .shadow(color: Theme.Layout.sheetShadowColor,
                        radius: Theme.Layout.sheetShadowRadius, y: Theme.Layout.sheetShadowY)
                .onHover { inside in if !inside { revealsBar = false } }
                .transition(.move(edge: .top))
        } else {
            Color.clear
                .frame(height: Theme.Space.s)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .onHover { inside in if inside { withAnimation { revealsBar = true } } }
                .accessibilityIdentifier("vm-fullscreen-edge")
        }
    }

    private func perform(_ action: VMWindowModel.ToolbarAction) {
        switch action {
        case .pause: Task { await model.pause() }
        case .suspend: Task { await model.suspend() }
        case .resume: Task { await model.resume() }
        case .stop: Task { await model.stop() }
        case .start, .retry, .resumeSaved: Task { await model.requestStart() }
        case .fullScreen: window.toggleFullScreen()
        case .details: showsDetails = true
        case .settings: openWindow(id: VMSettingsWindow.id, value: model.name.rawValue)
        case .snapshots: openWindow(id: SnapshotsWindow.id, value: model.name.rawValue)
        case .terminalAccess: model.terminalAccess?.show()
        }
    }

    // MARK: - Content

    @ViewBuilder private var content: some View {
        switch model.state {
        case .stopped:
            message(NidoEmptyState(
                verbatim: model.stoppedTitle, message: model.stoppedMessage(now: Date()),
                identifier: "vm-stopped", onCreate: nil))
        case .error(let text):
            message(NidoEmptyState(
                verbatim: model.errorTitle, message: text, eggColor: Theme.Color.statusError,
                identifier: "vm-error", onCreate: nil))
        default:
            if model.showsDisplay { macScreen } else { screen }
        }
    }

    /// S07 macOS: the guest's screen (its resolution follows the window), dimmed while paused,
    /// with "Accesso da terminale" beside it.
    private var macScreen: some View {
        let paused = model.state == .paused || model.state == .pausing
        return HStack(spacing: 0) {
            ZStack {
                Theme.MacScreen.background
                if let machine = model.displayMachine {
                    MacDisplayView(machine: machine, isFullScreen: window.isFullScreen, controller: display)
                        .opacity(paused ? Theme.Layout.pausedDisplayOpacity : 1)
                        .allowsHitTesting(!paused)
                        .accessibilityIdentifier("vm-display")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let access = model.terminalAccess, access.isShown {
                TerminalAccessPanel(model: access, onType: model.state == .running ? { typeAuthorizeCommand(access) } : nil)
            }
        }
    }

    /// "Digita nella VM": the command, with keys from this Mac's current layout.
    private func typeAuthorizeCommand(_ access: TerminalAccessModel) {
        guard let layout = SystemKeyboardLayout() else {
            access.reportLayoutUnavailable()
            return
        }
        Task { await access.typeCommand(into: display, layout: layout) }
    }

    private func message(_ panel: NidoEmptyState) -> some View {
        panel
            .padding(Theme.Space.xl)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.Color.background)
    }

    /// The guest's serial console; dimmed under the pause note while paused. Keys reach the guest
    /// only while it runs.
    private var screen: some View {
        let paused = model.state == .paused || model.state == .pausing
        return ZStack(alignment: .topTrailing) {
            Theme.Console.background
            if let terminal = model.terminal {
                TerminalView(buffer: terminal.buffer, acceptsInput: model.state == .running,
                             onInput: { model.sendInput($0) },
                             onResize: { terminal.resize(columns: $0, rows: $1) })
                    .opacity(paused ? Theme.Layout.pausedDisplayOpacity : 1)
                    .allowsHitTesting(!paused)
            }
            if model.provisioning.isShown, !window.isFullScreen {
                // S14: over the console, which stays usable underneath.
                ProvisioningProgressView(
                    provisioning: model.provisioning, aiRuntime: model.aiRuntime, guestTools: guestTools,
                    onOpenTerminal: { TerminalLauncher.openSSH(to: model.name) },
                    onOpenSettings: { openWindow(id: VMSettingsWindow.id, value: model.name.rawValue) },
                    onOpenAI: { tab = .ai })
                    .padding(Theme.Space.xl)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var pauseNote: some View {
        VStack(spacing: Theme.Space.s) {
            NidoStatusBadge(status: .paused)
            Text("\(model.name.rawValue) stays in memory where you left it. Resume to continue.")
                .font(.nido(Theme.TypeSize.body))
                .foregroundStyle(Theme.Color.textPrimary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Theme.Space.l)
        .frame(width: Theme.Layout.pauseNoteWidth)
        .background(Theme.Color.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.m))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.m)
            .strokeBorder(Theme.Color.border, lineWidth: Theme.Layout.hairline))
        .shadow(color: Theme.Layout.sheetShadowColor,
                radius: Theme.Layout.sheetShadowRadius, y: Theme.Layout.sheetShadowY)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("vm-pause-note")
    }

    private var details: String {
        var lines = [model.errorDetail ?? ""]
        if let consoleLog { lines.append(String(localized: "VM console: \(consoleLog.path)")) }
        return lines.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    private var confirmingClose: Binding<Bool> {
        Binding(get: { model.isConfirmingClose }, set: { if !$0 { model.cancelClose() } })
    }
}

// MARK: - The NSWindow behind the view

/// The window of a VM view: asks before closing while the VM runs, toggles and tracks full screen.
@MainActor
@Observable
final class WindowBridge {
    private(set) var isFullScreen = false
    /// Asked when the user closes the window (close button, ⌘W): false keeps it open.
    @ObservationIgnored var shouldClose: () -> Bool = { true }
    @ObservationIgnored private weak var window: NSWindow?
    @ObservationIgnored private var closeGuard: CloseGuard?
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []
    /// Watches `window.delegate`: SwiftUI may install a new delegate later (full screen, toolbar
    /// changes), which would drop the close confirmation; the guard is put back in front of it.
    @ObservationIgnored private var delegateObservation: NSKeyValueObservation?

    isolated deinit {
        detach()
    }

    /// Test seams: whether a window is attached, and how many notification observers are live.
    var isAttached: Bool { window != nil }
    var observerCount: Int { observers.count }

    func attach(_ window: NSWindow) {
        if self.window !== window {
            detach()
            self.window = window
            isFullScreen = window.styleMask.contains(.fullScreen)
            #if DEBUG
                // UI tests: `-NidoVMWindowWidth 640` opens the VM window that wide (XCUITest cannot
                // drag the edge of this window), after SwiftUI has applied its default size.
                let width = UserDefaults.standard.double(forKey: "NidoVMWindowWidth")
                if width > 0 {
                    DispatchQueue.main.async { [weak window] in
                        guard let window else { return }
                        var frame = window.frame
                        frame.size.width = width
                        window.setFrame(frame, display: true)
                    }
                }
            #endif
            let center = NotificationCenter.default
            for (name, value) in [(NSWindow.didEnterFullScreenNotification, true),
                                  (NSWindow.didExitFullScreenNotification, false)] {
                observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.isFullScreen = value }
                })
            }
            // The window is going away: let go of it at once (delegate, KVO, observers) rather
            // than when SwiftUI releases the view.
            observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: window,
                                                queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.detach() }
            })
            delegateObservation = window.observe(\.delegate, options: [.new]) { [weak self] window, _ in
                MainActor.assumeIsolated { self?.armCloseGuard(on: window) }
            }
        }
        armCloseGuard(on: window)
    }

    func toggleFullScreen() {
        window?.toggleFullScreen(nil)
    }

    /// Closes without asking (the VM is already stopped).
    func close() {
        window?.close()
    }

    /// Puts the guard in front of the window's current delegate, unless it is already there.
    private func armCloseGuard(on window: NSWindow) {
        guard window === self.window else { return }
        if let current = window.delegate, current === closeGuard { return }
        let guardDelegate = CloseGuard(forwardingTo: window.delegate) { [weak self] in self?.shouldClose() ?? true }
        closeGuard = guardDelegate
        window.delegate = guardDelegate  // the KVO callback sees the guard and stops there
    }

    private func detach() {
        delegateObservation?.invalidate()
        delegateObservation = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        if let window, let closeGuard, window.delegate === closeGuard { window.delegate = closeGuard.forward }
        closeGuard = nil
        window = nil
    }
}

/// A window delegate that answers `windowShouldClose` and hands every other message to the
/// delegate it replaced (SwiftUI's own).
final class CloseGuard: NSObject, NSWindowDelegate {
    /// `nonisolated(unsafe)`: AppKit sends window-delegate messages on the main thread only, and
    /// the bridge (main actor) is the only writer; the class itself is not `@MainActor` because
    /// it forwards arbitrary selectors through the Objective-C runtime.
    nonisolated(unsafe) weak var forward: (any NSWindowDelegate)?
    private let shouldClose: @MainActor () -> Bool

    init(forwardingTo forward: (any NSWindowDelegate)?, shouldClose: @escaping @MainActor () -> Bool) {
        self.forward = forward
        self.shouldClose = shouldClose
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard shouldClose() else { return false }
        return forward?.windowShouldClose?(sender) ?? true
    }

    override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || (forward?.responds(to: aSelector) ?? false)
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if let forward, forward.responds(to: aSelector) { return forward }
        return super.forwardingTarget(for: aSelector)
    }
}

/// Finds the hosting window and hands it to the bridge.
private struct WindowAccessor: NSViewRepresentable {
    let bridge: WindowBridge

    func makeNSView(context: Context) -> WindowView {
        let view = WindowView()
        view.onWindow = { [bridge] window in bridge.attach(window) }
        return view
    }

    func updateNSView(_ view: WindowView, context: Context) {
        if let window = view.window { bridge.attach(window) }
    }

    final class WindowView: NSView {
        var onWindow: ((NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onWindow?(window) }
        }
    }
}
