// SPDX-License-Identifier: Apache-2.0
import Foundation
import NidoCore
import Observation

/// Ollama in one guest, as the AI section drives it: `AIRuntime` over the background SSH in the
/// app, a fake in the tests.
protocol AIRuntimeControlling: Sendable {
    func status() async throws -> AIRuntimeStatus
    func log() async throws -> String
    /// `progress`: the Mac's download of the Ollama archive, when one is needed.
    func install(progress: @escaping @Sendable (DownloadProgress) -> Void) async throws
    func verify() async throws
    func start() async throws
    func stop() async throws
    func restart() async throws
    func update(progress: @escaping @Sendable (DownloadProgress) -> Void) async throws
    func uninstall(removeModels: Bool) async throws
    func pull(model: String, force: Bool, progress: @escaping @Sendable (PullProgress) -> Void) async throws
    func remove(model: String) async throws
    /// One chat turn: the answer's pieces as Ollama streams them, then its metrics; ending the
    /// iteration stops it.
    func chat(model: String, messages: [ChatMessage]) -> AsyncThrowingStream<ChatEvent, Error>
}

extension AIRuntime: AIRuntimeControlling {}

/// The provisioning phases and the Ollama actions of one VM (spec C and D), owned by its
/// `VMWindowModel`. No view: the AI section and the provisioning progress present it.
///
/// - Phase 1 (cloud-init: packages, Guest Tools) comes from the VM's config
///   (`guestToolsVersion`) and from the monitor answering (`guestResponds`).
/// - Phase 2 (Ollama, model) comes from `AIRuntime.status()` over SSH and from the monitor's
///   `provisioning` field (`monitorSteps`, every 3 s over vsock while the panel is visible); the
///   newer entry of each step wins. The Guest Tools report a `running` entry of another boot or of
///   a dead process as `failed`, so a failed step is what "Try Again" runs again, alone.
///
/// Uninstalling Ollama, removing a model and pulling over a model already there need a
/// confirmation (`pendingConfirmation`, which the view presents). One action at a time; every
/// call into the guest runs off the main actor. Cancelling stops Nido waiting, not the guest's
/// step (`AIRuntime`): the status is read again instead of assuming it stopped.
@MainActor
@Observable
final class AIRuntimeModel {
    enum Action: Equatable, Sendable {
        case install, verify, start, stop, restart, update
        case uninstall(removeModels: Bool)
        /// `force` overwrites a model already there (only after `.overwriteModel` was confirmed).
        case pull(model: String, force: Bool = false)
        case remove(model: String)
    }

    /// What the view must ask before the action runs.
    enum Confirmation: Equatable, Sendable {
        /// "Uninstall Ollama from <VM>?" with the choice to remove the models too.
        case uninstall
        case removeModel(String)
        /// The model is already in the VM: download it again?
        case overwriteModel(String)
    }

    enum Phase1: Equatable, Sendable {
        /// The VM was created without Guest Tools (or before M3c): "Install Guest Tools".
        case notInstalled
        /// Guest Tools expected, the guest has not answered yet (first boot in progress).
        case waitingForGuest
        /// The guest answers (or the VM is off with Guest Tools installed).
        case ready
    }

    struct ErrorState: Equatable, Sendable {
        /// Localized, a sentence.
        let message: String
        /// The key cannot be used from the background (passphrase without agent, host key
        /// changed): the view offers "Open Terminal".
        let offersTerminal: Bool
    }

    struct Activity: Equatable, Sendable {
        let action: Action
        /// The guest's download progress while a model is pulled.
        var progress: PullProgress?
    }

    /// Set by the window: actions need a running VM. A VM that stops ends the chat's answer.
    var isVMRunning = false {
        didSet {
            chat.isVMRunning = isVMRunning
            if !isVMRunning { chat.cancel() }
        }
    }
    /// The local chat with the VM's models (in memory only).
    let chat: LocalChatModel
    /// "Also delete the models" of the uninstall sheet: off whenever the sheet opens or is
    /// dismissed (the destructive choice is never remembered).
    var removeModelsOnUninstall = false
    /// Set by the window from the monitor: the guest's Guest Tools answer.
    var guestResponds = false
    /// The steps of the monitor's `provisioning` field (vsock), set by the window.
    var monitorSteps: [String: ProvisionStep] = [:]

    private(set) var guestToolsVersion: String?
    private(set) var runtimeStatus: AIRuntimeStatus?
    private(set) var activity: Activity?
    private(set) var pendingConfirmation: Confirmation?
    private(set) var error: ErrorState?
    /// Information that is not an error (e.g. after "Cancel"), localized.
    private(set) var note: String?
    /// The provisioning log, read only on request ("Show Log").
    private(set) var log: String?
    private(set) var isReadingLog = false
    private(set) var isRefreshing = false
    /// Why the last status read failed (localized): a background read, never the user's action
    /// error (`error`); nil after a good one.
    private(set) var refreshError: String?

    @ObservationIgnored private let readGuestToolsVersion: @Sendable () throws -> String?
    @ObservationIgnored private let makeRuntime: @Sendable () throws -> any AIRuntimeControlling
    @ObservationIgnored private var actionTask: Task<Result<Void, any Error>, Never>?

    init(
        readGuestToolsVersion: @escaping @Sendable () throws -> String?,
        makeRuntime: @escaping @Sendable () throws -> any AIRuntimeControlling
    ) {
        self.readGuestToolsVersion = readGuestToolsVersion
        self.makeRuntime = makeRuntime
        chat = LocalChatModel(makeRuntime: makeRuntime)
    }

    /// For the VM `name`: its config and `AIRuntime(bundle:)` (the SSH key of its config).
    convenience init(name: VMName, paths: NidoPaths) {
        self.init(
            readGuestToolsVersion: { try VMBundle.open(name, paths: paths).readConfig().guestToolsVersion },
            makeRuntime: { try AIRuntime(bundle: VMBundle.open(name, paths: paths)) })
    }

    // MARK: - Phases

    var phase1: Phase1 {
        if guestResponds { return .ready }
        if guestToolsVersion == nil { return .notInstalled }
        return isVMRunning ? .waitingForGuest : .ready
    }

    /// Order of the steps in the progress list (others follow by name).
    nonisolated static let stepOrder = [
        "ollama-install", "ollama-update", "ollama-verify", "ollama-start", "ollama-stop", "ollama-restart",
        "model-pull", "model-remove", "ollama-uninstall",
    ]

    /// Phase 2 as known now: SSH status and monitor merged, the newer entry of each step winning.
    var phase2Steps: [ProvisionStep] {
        var merged = runtimeStatus?.steps ?? [:]
        for (name, step) in monitorSteps {
            guard let current = merged[name] else {
                merged[name] = step
                continue
            }
            // ISO 8601 of one guest clock: comparable as text. An entry without a time loses.
            if (step.updated ?? "") >= (current.updated ?? "") { merged[name] = step }
        }
        return merged.values.sorted { a, b in
            let ia = Self.stepOrder.firstIndex(of: a.name) ?? Int.max
            let ib = Self.stepOrder.firstIndex(of: b.name) ?? Int.max
            return ia != ib ? ia < ib : a.name < b.name
        }
    }

    /// The step "Try Again" runs again: the most recent failed one.
    var failedStep: ProvisionStep? {
        phase2Steps.filter { $0.state == .failed }.max { ($0.updated ?? "") < ($1.updated ?? "") }
    }

    /// A step running in the guest (also one started from the Terminal or an earlier session).
    var runningStep: ProvisionStep? {
        phase2Steps.first { $0.state == .running }
    }

    // MARK: - Reading

    /// Reads the VM's `guestToolsVersion` (off the main actor).
    func loadConfiguration() async {
        let read = readGuestToolsVersion
        guestToolsVersion = await Task.detached { try? read() }.value ?? nil
    }

    /// Asks the guest for Ollama's status and the provisioning steps (SSH).
    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let make = makeRuntime
        let result = await Task.detached { () -> Result<AIRuntimeStatus, any Error> in
            do { return .success(try await make().status()) } catch { return .failure(error) }
        }.value
        switch result {
        case .success(let status):
            runtimeStatus = status
            refreshError = nil
            chat.setModels(status.models.map(\.name))
        case .failure(let failure):
            refreshError = Self.errorState(for: failure)?.message
        }
    }

    /// "Show Log": the tail of the guest's `/var/log/nido-provision.log` (SSH, on request only).
    func readLog() async {
        guard !isReadingLog else { return }
        isReadingLog = true
        defer { isReadingLog = false }
        let make = makeRuntime
        let result = await Task.detached { () -> Result<String, any Error> in
            do { return .success(try await make().log()) } catch { return .failure(error) }
        }.value
        switch result {
        case .success(let text): log = text
        case .failure(let failure): error = Self.errorState(for: failure)
        }
    }

    // MARK: - Actions

    /// The user chose `action`: runs it, or first asks (`pendingConfirmation`) when it removes
    /// something or overwrites a model.
    func request(_ action: Action) async {
        // While the chat streams an answer nothing changes Ollama under it (Stop, Remove…).
        guard activity == nil, pendingConfirmation == nil, !chat.isAnswering else { return }
        switch action {
        case .uninstall:
            removeModelsOnUninstall = false
            pendingConfirmation = .uninstall
        case .remove(let model):
            pendingConfirmation = .removeModel(model)
        case .pull(let model, false) where hasModel(model):
            pendingConfirmation = .overwriteModel(model)
        default:
            await run(action)
        }
    }

    /// The confirmation was accepted (`removeModels`: for `.uninstall`, also delete the models).
    func confirm(removeModels: Bool = false) async {
        guard let confirmation = pendingConfirmation else { return }
        pendingConfirmation = nil
        removeModelsOnUninstall = false
        switch confirmation {
        case .uninstall: await run(.uninstall(removeModels: removeModels))
        case .removeModel(let model): await run(.remove(model: model))
        case .overwriteModel(let model): await run(.pull(model: model, force: true))
        }
    }

    func cancelConfirmation() {
        pendingConfirmation = nil
        removeModelsOnUninstall = false
    }

    /// "Download" with the name typed by the user: an official identifier only (the guest checks it
    /// again), then as `request(.pull)` (which asks before overwriting a model already there).
    func requestPull(_ text: String) async {
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        guard (try? GuestCommand.validateModelName(name)) != nil else {
            error = ErrorState(
                message: String(localized: "Invalid model name: use name:variant, for example llama3.2:1b."), offersTerminal: false)
            return
        }
        await request(.pull(model: name))
    }

    /// Another action can start now (one at a time; a question on screen comes first).
    var canStartAction: Bool { isVMRunning && activity == nil && pendingConfirmation == nil && !chat.isAnswering }

    /// The texts of the confirmation sheet for `pendingConfirmation`.
    struct ConfirmationCopy: Equatable, Sendable {
        let title: String
        let message: String
        let action: String
        let isDestructive: Bool
        /// Uninstall: the switch "Also delete the models" and what it would delete.
        var removeModelsDetail: String?
    }

    func confirmationCopy(vmName: String) -> ConfirmationCopy? {
        switch pendingConfirmation {
        case nil:
            return nil
        case .uninstall:
            let models = runtimeStatus?.models ?? []
            // Guest-reported sizes: add with saturation, an overflow would trap the app.
            let total = models.reduce(Int64(0)) { sum, model in
                let (next, overflow) = sum.addingReportingOverflow(max(0, model.sizeBytes))
                return overflow ? .max : next
            }
            let names = models.map(\.name).formatted(.list(type: .and))
            let detail = models.isEmpty ? String(localized: "No models in the VM.")
                : String(localized: "\(names): \(ByteSize.text(total)) in the VM.",
                         comment: "The models an uninstall would delete: a list of model names, then their total size.")
            return ConfirmationCopy(
                title: String(localized: "Uninstall Ollama from \(vmName)?", comment: "%@ is the VM’s name."),
                message: String(localized: "Nido stops the service and removes Ollama from the VM. The models stay, unless you choose to delete them."),
                action: String(localized: "Uninstall"), isDestructive: true, removeModelsDetail: detail)
        case .removeModel(let name):
            let message = if let model = runtimeStatus?.models.first(where: { $0.name == name }) {
                String(localized: "The model (\(ByteSize.text(model.sizeBytes))) is deleted from the VM. You can download it again whenever you want.",
                       comment: "%@ is the model’s size.")
            } else {
                String(localized: "The model is deleted from the VM. You can download it again whenever you want.")
            }
            return ConfirmationCopy(
                title: String(localized: "Remove \(name) from \(vmName)?", comment: "A model’s name, then the VM’s name."),
                message: message,
                action: String(localized: "Remove (model)", defaultValue: "Remove",
                               comment: "Deletes a model from the VM (not an item from a list)."),
                isDestructive: true)
        case .overwriteModel(let name):
            return ConfirmationCopy(
                title: String(localized: "The model \(name) is already in the VM: download it again and overwrite it?",
                              comment: "%@ is a model’s name."),
                message: String(localized: "Nido downloads it again from the Ollama library and replaces the one in the VM."),
                action: String(localized: "Overwrite"), isDestructive: false)
        }
    }

    /// The progress message of the Mac's download of the Ollama archive (install and update): a
    /// marker the view and `run` recognize, never shown.
    nonisolated static let macDownloadMessage = "nido.mac-download.ollama"

    /// The warning under a model's download (`PullProgress.warning`): the guest's
    /// `model_memory_low: …`, shown by its code in the app's language (`GuestMessage`), as a
    /// sentence; text from older Guest Tools (Italian) as it arrives.
    nonisolated static func warningText(_ warning: String) -> String {
        let text = GuestMessage.text(warning)
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    /// "Download · 1.1 GiB of 2.5 GiB · 44%" ("Download · 1,1 GiB di 2,5 GiB · 44 %" in Italian).
    nonisolated static func progressText(_ progress: PullProgress) -> String {
        guard progress.totalBytes > 0 else { return String(localized: "Downloading") }
        // Guest-reported counts: clamp the ratio before it becomes an Int, or it can trap the app.
        let ratio = min(1, max(0, Double(progress.completedBytes) / Double(progress.totalBytes)))
        let percent = Int((ratio * 100).rounded(.down))
        return [
            String(localized: "Download (step)", defaultValue: "Download",
                   comment: "A download, a noun: the wizard step that downloads the system image (a title), and the label of a download’s progress (the Ollama archive, a model)."),
            String(localized: "\(ByteSize.text(progress.completedBytes)) of \(ByteSize.text(progress.totalBytes))",
                   comment: "Downloaded so far of the total: 0.4 GiB of 1.2 GiB."),
            String(localized: "\(percent)%", comment: "A meter's value in percent. [not a count]"),
        ].joined(separator: " · ")
    }

    /// "Try Again": runs again only the failed step (it resumes where it stopped in the guest).
    func retry() async {
        // A question on screen (or an action running) comes first.
        guard activity == nil, pendingConfirmation == nil, let step = failedStep else { return }
        switch step.name {
        case "ollama-install": await request(.install)
        case "ollama-update": await request(.update)
        case "ollama-verify": await request(.verify)
        case "ollama-start": await request(.start)
        case "ollama-stop": await request(.stop)
        case "ollama-restart": await request(.restart)
        // The model was confirmed or chosen already: resume it (never `--force` here).
        case "model-pull": if let model = step.model { await run(.pull(model: model, force: false)) }
        case "model-remove": if let model = step.model { await run(.remove(model: model)) }
        // Whether to keep the models is not recorded: ask again.
        case "ollama-uninstall": await request(.uninstall(removeModels: false))
        default: break
        }
    }

    /// "Stop Waiting" or "Cancel Download": Nido stops waiting; the guest's step goes on and the status says how it ends.
    func cancel() {
        actionTask?.cancel()
    }

    func dismissError() {
        error = nil
    }

    private func hasModel(_ name: String) -> Bool {
        runtimeStatus?.models.contains { $0.name == name || $0.name == name + ":latest" } ?? false
    }

    private func run(_ action: Action) async {
        guard activity == nil else { return }
        guard isVMRunning else {
            error = ErrorState(message: String(localized: "The VM isn’t running: start it to manage Ollama."), offersTerminal: false)
            return
        }
        error = nil
        note = nil
        activity = Activity(action: action)
        let make = makeRuntime
        // Held only while the action runs.
        let model = self
        let report: @Sendable (PullProgress) -> Void = { progress in
            Task { @MainActor in
                if model.activity?.action == action { model.activity?.progress = progress }
            }
        }
        let task = Task.detached { () -> Result<Void, any Error> in
            do {
                let runtime = try make()
                try await Self.perform(action, on: runtime, progress: report)
                return .success(())
            } catch {
                return .failure(error)
            }
        }
        actionTask = task
        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        let cancelled = task.isCancelled
        // Cancelled while the Mac was still downloading: nothing reached the VM yet.
        let downloading = activity?.progress.map { $0.message == Self.macDownloadMessage && $0.completedBytes < $0.totalBytes } ?? false
        actionTask = nil
        activity = nil
        if case .failure(let failure) = result {
            if downloading, cancelled || failure is CancellationError {
                note = String(localized: "Ollama download canceled: nothing in the VM was changed. Try again whenever you want.")
            } else if cancelled || failure is CancellationError || (failure as? GuestSSHError) == .cancelled {
                note = String(localized: "Nido stopped waiting: the operation continues in the VM and the status updates automatically.")
            } else {
                error = Self.errorState(for: failure)
            }
        }
        await refresh()
    }

    private nonisolated static func perform(
        _ action: Action, on runtime: any AIRuntimeControlling,
        progress: @escaping @Sendable (PullProgress) -> Void
    ) async throws {
        // The Mac's download of the archive, shown like a model's download.
        let download: @Sendable (DownloadProgress) -> Void = { value in
            progress(PullProgress(
                completedBytes: Int64(clamping: value.receivedBytes),
                totalBytes: Int64(clamping: value.expectedBytes ?? OllamaRelease.pinned.size),
                message: Self.macDownloadMessage, warning: nil))
        }
        switch action {
        case .install: try await runtime.install(progress: download)
        case .verify: try await runtime.verify()
        case .start: try await runtime.start()
        case .stop: try await runtime.stop()
        case .restart: try await runtime.restart()
        case .update: try await runtime.update(progress: download)
        case .uninstall(let removeModels): try await runtime.uninstall(removeModels: removeModels)
        case .pull(let model, let force): try await runtime.pull(model: model, force: force, progress: progress)
        case .remove(let model): try await runtime.remove(model: model)
        }
    }

    /// The localized sentence for a failure of SSH, of `nido-provision` or of Ollama; nil for a
    /// cancellation.
    nonisolated static func errorState(for error: any Error) -> ErrorState? {
        if error is CancellationError || (error as? GuestSSHError) == .cancelled { return nil }
        let text = (error as? any LocalizedError)?.errorDescription ?? error.localizedDescription
        let offersTerminal: Bool = switch error as? GuestSSHError {
        case .keyUnavailable, .hostKeyChanged: true
        default: false
        }
        return ErrorState(message: text.prefix(1).uppercased() + text.dropFirst(), offersTerminal: offersTerminal)
    }
}
