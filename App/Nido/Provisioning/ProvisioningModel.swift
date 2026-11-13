// SPDX-License-Identifier: Apache-2.0
import Foundation
import NidoCore
import Observation

/// What the creation wizard asked for after the first boot (spec C, phase 2): Ollama, and at
/// most one model.
struct ProvisioningPlan: Equatable, Sendable {
    /// The model to download after Ollama (validated by the wizard), nil for none.
    var model: String?
}

/// The provisioning progress of a VM just created by the wizard (S14), owned by its
/// `VMWindowModel`: phase 1 (cloud-init: packages, Guest Tools) ends when the guest's monitor
/// first answers; then, if the user chose it, phase 2 runs through `AIRuntimeModel` (SSH):
/// Ollama, the model, the check. Success is declared only after all of them.
///
/// A failure stops the sequence and shows the error; "Riprova" runs again from the step that
/// did not finish (the steps already done in the guest are skipped). "Smetti di attendere" stops
/// Nido waiting; the guest's step goes on (`AIRuntimeModel.cancel`).
@MainActor
@Observable
final class ProvisioningModel {
    struct Row: Hashable, Sendable {
        enum State: Hashable, Sendable { case done, running, waiting, failed }
        let label: String
        let state: State
        /// The text on the right: "Fatto", "In corso", "46 %", "Fatto alle 10:38"…
        let status: String
    }

    struct Failure: Equatable, Sendable {
        let title: String
        let detail: String
        let offersTerminal: Bool
    }

    let name: String
    /// What the wizard chose; nil when it asked for phase 1 only (or nothing was begun).
    private(set) var plan: ProvisioningPlan?
    /// A provisioning was begun for this VM (the wizard just created it).
    private(set) var isBegun = false
    /// The user hid the panel ("Nascondi", "Chiudi"); the work goes on.
    private(set) var isDismissed = false
    /// When the guest first answered (phase 1 done).
    private(set) var guestReadyAt: Date?
    /// When everything chosen was verified.
    private(set) var completedAt: Date?
    /// Phase 2 is running its sequence now.
    private(set) var isRunning = false
    private(set) var failure: Failure?
    /// "Smetti di attendere" was pressed: Nido no longer follows the guest's step.
    private(set) var stoppedWaiting = false
    /// The guest never answered within the monitor's grace: phase 1 did not finish (or the Guest
    /// Tools do not start). A later answer (the Monitor tab) clears it.
    private(set) var phase1Failed = false

    @ObservationIgnored private let aiRuntime: AIRuntimeModel
    @ObservationIgnored private weak var monitor: MonitorModel?
    @ObservationIgnored private let now: @MainActor () -> Date
    /// Phase 2 was started in the current session (a restarted VM resumes it once more).
    @ObservationIgnored private var startedThisSession = false
    /// Removes the plan's record from the VM's config (`VMConfig.pendingProvisioning`): after the
    /// verified success or "Non installare".
    @ObservationIgnored private let clearPending: @MainActor () async -> Void

    init(name: String = "", aiRuntime: AIRuntimeModel, monitor: MonitorModel? = nil,
         now: @escaping @MainActor () -> Date = { Date() },
         clearPending: @escaping @MainActor () async -> Void = {}) {
        self.name = name
        self.aiRuntime = aiRuntime
        self.monitor = monitor
        self.now = now
        self.clearPending = clearPending
    }

    // MARK: - Lifecycle

    /// The wizard created the VM: show its progress; `plan` nil means phase 1 only.
    func begin(_ plan: ProvisioningPlan?) {
        self.plan = plan
        isBegun = true
        isDismissed = false
        guestReadyAt = nil
        completedAt = nil
        failure = nil
        stoppedWaiting = false
        phase1Failed = false
        startedThisSession = false
        syncPolling()
    }

    /// The VM's config still records a phase 2 (the app restarted, the window was reopened):
    /// follow it again, unless this model already does.
    func resume(_ plan: ProvisioningPlan) {
        guard !isBegun || (isComplete && self.plan == nil) else { return }
        begin(plan)
    }

    /// "Non installare": phase 2 is given up (and its record removed); phase 1 goes on.
    func decline() async {
        guard plan != nil, !isRunning else { return }
        plan = nil
        failure = nil
        aiRuntime.dismissError()
        await clearPending()
        if guestReady {
            completedAt = now()
        }
        syncPolling()
    }

    /// The monitor gave up waiting (its grace is over and the guest never answered).
    func guestNeverAnswered() {
        guard isBegun, !guestReady else { return }
        phase1Failed = true
        syncPolling()
    }

    var isShown: Bool { isBegun && !isDismissed }
    var isComplete: Bool { completedAt != nil }
    var guestReady: Bool { guestReadyAt != nil }

    /// The panel goes; the work (and the guest's polling) goes on until it is complete.
    func dismiss() {
        isDismissed = true
    }

    /// A new session of the VM: an unfinished phase 2 resumes when the guest answers again.
    func sessionStarted() {
        startedThisSession = false
        stoppedWaiting = false
        syncPolling()
    }

    /// The guest's monitor answered (every sample): ends phase 1, then starts phase 2 once.
    func guestAnswered() async {
        guard isBegun, !isComplete else { return }
        if guestReadyAt == nil { guestReadyAt = now() }
        phase1Failed = false
        guard !startedThisSession, !isRunning, failure == nil, !stoppedWaiting else { return }
        startedThisSession = true
        guard plan != nil else {
            completedAt = now()
            syncPolling()
            return
        }
        await run()
    }

    /// "Riprova": from the step that did not finish.
    func retry() async {
        guard isBegun, plan != nil, !isRunning, !isComplete else { return }
        failure = nil
        stoppedWaiting = false
        aiRuntime.dismissError()
        await run()
    }

    /// "Smetti di attendere".
    func stopWaiting() {
        stoppedWaiting = true
        aiRuntime.cancel()
        syncPolling()
    }

    /// The guest is polled (with the Monitor tab hidden too) only while the provisioning waits
    /// for its answers: not once complete, failed, given up or no longer followed.
    private func syncPolling() {
        monitor?.keepsPolling = isBegun && !isComplete && failure == nil && !stoppedWaiting && !phase1Failed
    }

    // MARK: - Phase 2

    private enum Step: CaseIterable {
        case install, model, verify

        var stepName: String {
            switch self {
            case .install: "ollama-install"
            case .model: "model-pull"
            case .verify: "ollama-verify"
            }
        }
    }

    private func isDone(_ step: Step) -> Bool {
        let entry = aiRuntime.phase2Steps.first { $0.name == step.stepName }
        switch step {
        case .install:
            return entry?.state == .done || aiRuntime.runtimeStatus?.installed == true
        case .model:
            guard let model = plan?.model else { return true }
            let present = aiRuntime.runtimeStatus?.models.contains { $0.name == model || $0.name == model + ":latest" }
            return present == true || (entry?.state == .done && entry?.model == model)
        case .verify:
            // Never assumed: run in every sequence, done only when the guest recorded it.
            return false
        }
    }

    /// The guest recorded `step` as done (after the action and a fresh status read).
    private func isVerified(_ step: Step) -> Bool {
        if step == .verify {
            return aiRuntime.phase2Steps.first { $0.name == step.stepName }?.state == .done
        }
        return isDone(step)
    }

    private func run() async {
        guard let plan else { return }
        isRunning = true
        defer {
            isRunning = false
            syncPolling()
        }
        // Another action or a question of the AI view comes first: nothing runs now (the next
        // answer of the guest, or Riprova, tries again).
        guard aiRuntime.activity == nil, aiRuntime.pendingConfirmation == nil else {
            startedThisSession = false
            return
        }
        await aiRuntime.refresh()
        let remaining = Step.allCases.filter { !isDone($0) }
        for step in remaining {
            guard aiRuntime.activity == nil, aiRuntime.pendingConfirmation == nil else {
                startedThisSession = false
                return
            }
            let action: AIRuntimeModel.Action = switch step {
            case .install: .install
            case .model: .pull(model: plan.model ?? "", force: false)
            case .verify: .verify
            }
            await aiRuntime.request(action)
            if let error = aiRuntime.error {
                failure = Failure(title: failureTitle(step, error), detail: error.message,
                                  offersTerminal: error.offersTerminal)
                return
            }
            if aiRuntime.note != nil || stoppedWaiting { return }
            // Success only as the guest recorded it (`state.json`), never assumed.
            guard isVerified(step) else {
                failure = Failure(
                    title: failureTitle(step, nil),
                    detail: String(localized: "In the VM the step isn’t recorded as done. Click Try Again, or look at the log."),
                    offersTerminal: false)
                return
            }
        }
        completedAt = now()
        await clearPending()
    }

    private func failureTitle(_ step: Step, _ error: AIRuntimeModel.ErrorState?) -> String {
        if error?.offersTerminal == true { return String(localized: "Nido can’t connect to \(name) over SSH") }
        return switch step {
        case .install: String(localized: "Couldn’t install Ollama")
        case .model: String(localized: "Couldn’t download the model")
        case .verify: String(localized: "The check failed")
        }
    }

    // MARK: - Presentation

    var title: String {
        isComplete ? String(localized: "\(name) is ready") : String(localized: "Setting up \(name)")
    }

    var subtitle: String {
        if let completedAt {
            let time = Self.time(completedAt)
            guard let plan else { return String(localized: "Essential packages and Guest Tools ready at \(time)") }
            return plan.model.map { String(localized: "Ollama and \($0) verified at \(time)") }
                ?? String(localized: "Ollama verified at \(time)")
        }
        if !guestReady { return String(localized: "First boot: cloud-init is preparing the system") }
        return plan?.model == nil ? String(localized: "Ollama chosen at creation") : String(localized: "Ollama and the model chosen at creation")
    }

    /// The caption under the steps.
    /// Phase 1 did not finish: why, and the way out (the view offers Installa Guest Tools).
    var phase1FailureText: (title: String, detail: String)? {
        guard phase1Failed else { return nil }
        return (String(localized: "The Guest Tools of \(name) don’t respond"),
                String(localized: "The first boot didn’t start the guest monitor within 5 minutes. Look at the console in the Screen view; if cloud-init has finished, install the Guest Tools over SSH."))
    }

    var caption: String? {
        if failure != nil || phase1Failed { return nil }
        if isComplete {
            return plan == nil ? nil : String(localized: "Use Ollama from the AI view, or in the VM at 127.0.0.1:11434.")
        }
        if !guestReady {
            return plan == nil
                ? String(localized: "\(name) will be usable at the end of phase 1.")
                : String(localized: "\(name) will be usable at the end of phase 1. Ollama and the model come later, without blocking it.")
        }
        if stoppedWaiting {
            return String(localized: "Nido stopped waiting: the operation goes on in the VM and the AI view shows how it ends.")
        }
        return plan?.model == nil
            ? String(localized: "\(name) is ready: you can use it while Nido downloads Ollama.")
            : String(localized: "\(name) is ready: you can use it while Nido downloads the model.")
    }

    /// Phase 1 while it runs (S14 "fase 1"); one row once it is done.
    var phase1Rows: [Row] {
        if let guestReadyAt {
            return [Row(label: String(localized: "Phase 1 · packages and Guest Tools"), state: .done,
                        status: String(localized: "Done at \(Self.time(guestReadyAt))"))]
        }
        let booted = aiRuntime.isVMRunning
        let packages = String(localized: "Essential packages and Guest Tools")
        return [
            Row(label: String(localized: "VM created"), state: .done, status: Self.statusText(.done)),
            Row(label: String(localized: "Debian started"), state: booted ? .done : .running,
                status: Self.statusText(booted ? .done : .running)),
            phase1Failed
                ? Row(label: packages, state: .failed, status: Self.statusText(.failed))
                : Row(label: packages, state: booted ? .running : .waiting,
                      status: Self.statusText(booted ? .running : .waiting)),
            Row(label: String(localized: "Guest ready (the monitor responds)"), state: .waiting, status: Self.statusText(.waiting)),
        ]
    }

    /// Phase 2 as chosen: Ollama, the model, the check.
    var phase2Rows: [Row] {
        guard let plan else { return [] }
        var rows = [row(.install, label: "Ollama")]
        if let label = modelRowLabel { rows.append(row(.model, label: label)) }
        rows.append(row(.verify, label: Self.verifyLabel))
        return rows
    }

    /// The model's row of phase 2 ("Modello llama3.2:1b"), nil without a model.
    var modelRowLabel: String? {
        plan?.model.map { String(localized: "Model \($0)", comment: "A provisioning step; %@ is an AI model’s name.") }
    }

    private static var verifyLabel: String { String(localized: "Verification") }

    /// The model download while it runs: 0…1 and "0,6 GiB di 1,3 GiB".
    var pullProgress: (fraction: Double, detail: String)? {
        guard case .pull = aiRuntime.activity?.action, let progress = aiRuntime.activity?.progress,
              progress.totalBytes > 0
        else { return nil }
        let done = UInt64(max(0, progress.completedBytes))
        let total = UInt64(progress.totalBytes)
        return (min(1, Double(done) / Double(total)),
                String(localized: "\(ByteSize.text(done)) of \(ByteSize.text(total))"))
    }

    private func row(_ step: Step, label: String) -> Row {
        let running: Bool = switch (step, aiRuntime.activity?.action) {
        case (.install, .install?), (.verify, .verify?): true
        case (.model, .pull?): true
        default: false
        }
        if running {
            if step == .model, let progress = pullProgress {
                let percent = Int((progress.fraction * 100).rounded())
                return Row(label: label, state: .running,
                           status: String(localized: "\(percent)%", comment: "A meter's value in percent. [not a count]"))
            }
            return Row(label: label, state: .running, status: Self.statusText(.running))
        }
        if completedAt != nil { return Row(label: label, state: .done, status: Self.statusText(.done)) }
        let entry = aiRuntime.phase2Steps.first { $0.name == step.stepName }
        let state: Row.State = switch entry?.state {
        case .done?: step == .verify && !isComplete ? .waiting : .done
        case .failed?: .failed
        case .running?: .running
        default: .waiting
        }
        // The failure of this run is on the step that stopped it.
        if failure != nil, state != .done, failedStepLabel == label {
            return Row(label: label, state: .failed, status: Self.statusText(.failed))
        }
        return Row(label: label, state: state, status: Self.statusText(state))
    }

    /// The first step of the plan not done: where a failure stopped.
    private var failedStepLabel: String? {
        guard plan != nil, failure != nil else { return nil }
        for step in Step.allCases where !isDone(step) {
            switch step {
            case .install: return "Ollama"
            case .model: return modelRowLabel
            case .verify: return Self.verifyLabel
            }
        }
        return nil
    }

    nonisolated static func statusText(_ state: Row.State) -> String {
        switch state {
        case .done: String(localized: "Done (step)", defaultValue: "Done", comment: "A step’s status: it finished.")
        case .running: String(localized: "In progress")
        case .waiting: String(localized: "Waiting")
        case .failed: String(localized: "Failed")
        }
    }

    nonisolated static func time(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(.current))
    }
}
