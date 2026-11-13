// SPDX-License-Identifier: Apache-2.0
import Foundation
import NidoCore
import Synchronization
import Testing

@testable import Nido

/// Ollama in a pretend guest: records every call, answers `status()` with what the test set.
final class FakeAIRuntime: AIRuntimeControlling {
    private struct State {
        var calls: [String] = []
        var status: AIRuntimeStatus
        var failure: (any Error)?
        var log = "riga 1\nriga 2\n"
        var statusFailure: (any Error)?
        /// A successful action marks its step done in `status` (as `nido-provision` does).
        var recordsSteps = true
        /// What a pull reports while it runs, and whether it then waits for `openPullGate()`.
        var pullProgress = PullProgress(completedBytes: 50, totalBytes: 100, message: "scaricamento", warning: nil)
        var gatesPull = false
        /// The chat's pieces; `finishesChat` false keeps the answer open until it is cancelled.
        var chatPieces: [String] = []
        /// Ollama's metrics after the pieces, when set.
        var chatStats: ChatStats?
        var finishesChat = true
        var chatMessages: [[ChatMessage]] = []
        var chatTerminated = false
        /// What the Mac's download reports during install, and whether install then waits until
        /// it is cancelled (a download in progress).
        var downloadReport: DownloadProgress?
        var holdsInstall = false
    }

    private let state: Mutex<State>
    private let pullGate = AsyncStream<Void>.makeStream()

    init(status: AIRuntimeStatus) {
        state = Mutex(State(status: status))
    }

    var calls: [String] { state.withLock { $0.calls } }
    /// The calls that change something (not `status`, not `log`).
    var actions: [String] { calls.filter { $0 != "status" && $0 != "log" && !$0.hasPrefix("chat ") } }

    func set(status: AIRuntimeStatus) { state.withLock { $0.status = status } }
    func fail(with error: (any Error)?) { state.withLock { $0.failure = error } }
    func failStatus(with error: (any Error)?) { state.withLock { $0.statusFailure = error } }
    func gatePull(progress: PullProgress) {
        state.withLock {
            $0.gatesPull = true
            $0.pullProgress = progress
        }
    }
    func openPullGate() { pullGate.continuation.yield() }
    func setChat(pieces: [String], stats: ChatStats? = nil, finishes: Bool) {
        state.withLock {
            $0.chatPieces = pieces
            $0.chatStats = stats
            $0.finishesChat = finishes
        }
    }
    var chatTerminated: Bool { state.withLock { $0.chatTerminated } }
    var chatMessages: [[ChatMessage]] { state.withLock { $0.chatMessages } }

    /// The guest's `state.json` does not change after an action (a step that did not really finish).
    func stopRecordingSteps() { state.withLock { $0.recordsSteps = false } }

    private func record(_ call: String, step: String? = nil, model: String? = nil) throws {
        let failure = state.withLock { s -> (any Error)? in
            s.calls.append(call)
            let failure = call == "status" || call == "log" ? nil : s.failure
            if failure == nil, s.recordsSteps, let step {
                var steps = s.status.steps
                steps[step] = ProvisionStep(name: step, state: .done, message: "fatto", model: model)
                s.status = AIRuntimeStatus(
                    installed: s.status.installed || step == "ollama-install", version: s.status.version,
                    running: s.status.running, models: s.status.models, pinnedVersion: s.status.pinnedVersion,
                    steps: steps)
            }
            return failure
        }
        if let failure { throw failure }
    }

    func status() async throws -> AIRuntimeStatus {
        try record("status")
        if let failure = state.withLock({ $0.statusFailure }) { throw failure }
        return state.withLock { $0.status }
    }

    func log() async throws -> String {
        try record("log")
        return state.withLock { $0.log }
    }

    func install(progress: @escaping @Sendable (DownloadProgress) -> Void) async throws {
        let (report, holds) = state.withLock { ($0.downloadReport, $0.holdsInstall) }
        if let report { progress(report) }
        if holds {
            // A download in progress: only a cancellation ends it.
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
            throw CancellationError()
        }
        try record("install", step: "ollama-install")
    }

    func holdInstall(reporting report: DownloadProgress) {
        state.withLock {
            $0.downloadReport = report
            $0.holdsInstall = true
        }
    }
    func verify() async throws { try record("verify", step: "ollama-verify") }
    func start() async throws { try record("start") }
    func stop() async throws { try record("stop") }
    func restart() async throws { try record("restart") }
    func update(progress: @escaping @Sendable (DownloadProgress) -> Void) async throws { try record("update") }
    func uninstall(removeModels: Bool) async throws { try record("uninstall removeModels=\(removeModels)") }

    func pull(model: String, force: Bool, progress: @escaping @Sendable (PullProgress) -> Void) async throws {
        let (report, gated) = state.withLock { ($0.pullProgress, $0.gatesPull) }
        progress(report)
        if gated { for await _ in pullGate.stream { break } }
        try record("pull \(model) force=\(force)", step: "model-pull", model: model)
    }

    func remove(model: String) async throws { try record("remove \(model)") }

    func chat(model: String, messages: [ChatMessage]) -> AsyncThrowingStream<ChatEvent, Error> {
        let (pieces, stats, finishes) = state.withLock { s in
            s.calls.append("chat \(model)")
            s.chatMessages.append(messages)
            return (s.chatPieces, s.chatStats, s.finishesChat)
        }
        let (stream, continuation) = AsyncThrowingStream<ChatEvent, Error>.makeStream()
        continuation.onTermination = { _ in self.state.withLock { $0.chatTerminated = true } }
        for piece in pieces { continuation.yield(.piece(piece)) }
        if let stats { continuation.yield(.finished(stats)) }
        if finishes { continuation.finish() }
        return stream
    }
}

func runtimeStatus(
    installed: Bool = true, running: Bool = true, models: [OllamaModel] = [],
    steps: [ProvisionStep] = []
) -> AIRuntimeStatus {
    AIRuntimeStatus(
        installed: installed, version: installed ? "0.12.6" : nil, running: running, models: models,
        pinnedVersion: "0.12.6", steps: Dictionary(uniqueKeysWithValues: steps.map { ($0.name, $0) }))
}

@MainActor
struct AIRuntimeModelTests {
    private func makeModel(_ runtime: FakeAIRuntime, guestToolsVersion: String? = "1.0.0") -> AIRuntimeModel {
        let model = AIRuntimeModel(
            readGuestToolsVersion: { guestToolsVersion }, makeRuntime: { runtime })
        model.isVMRunning = true
        return model
    }

    @Test func retryRunsFailedStepOnly() async {
        let runtime = FakeAIRuntime(status: runtimeStatus(steps: [
            ProvisionStep(name: "ollama-install", state: .done, message: "installato", updated: "2026-10-25T10:00:00+00:00"),
            ProvisionStep(
                name: "model-pull", state: .failed, message: "interrotto: usa Riprova",
                updated: "2026-10-25T10:05:00+00:00", model: "qwen3:0.6b"),
        ]))
        let model = makeModel(runtime)
        await model.refresh()
        #expect(model.failedStep?.name == "model-pull")
        #expect(model.phase2Steps.map(\.name) == ["ollama-install", "model-pull"])

        await model.retry()
        // Only the failed step, resumed (no --force), and nothing else.
        #expect(runtime.actions == ["pull qwen3:0.6b force=false"])
        #expect(model.activity == nil)

        // Nothing failed: Riprova does nothing.
        runtime.set(status: runtimeStatus(steps: [
            ProvisionStep(name: "model-pull", state: .done, message: "ok", model: "qwen3:0.6b"),
        ]))
        await model.refresh()
        #expect(model.failedStep == nil)
        await model.retry()
        #expect(runtime.actions == ["pull qwen3:0.6b force=false"])
    }

    @Test func retryOfFailedInstallRunsInstall() async {
        let runtime = FakeAIRuntime(status: runtimeStatus(installed: false, running: false, steps: [
            ProvisionStep(name: "ollama-install", state: .failed, message: "spazio insufficiente"),
        ]))
        let model = makeModel(runtime)
        await model.refresh()
        await model.retry()
        #expect(runtime.actions == ["install"])
    }

    @Test func uninstallAsksConfirmation() async {
        let runtime = FakeAIRuntime(status: runtimeStatus(models: [OllamaModel(name: "qwen3:0.6b", sizeBytes: 1)]))
        let model = makeModel(runtime)
        await model.refresh()

        await model.request(.uninstall(removeModels: false))
        #expect(model.pendingConfirmation == .uninstall)
        #expect(runtime.actions.isEmpty)
        model.cancelConfirmation()
        #expect(model.pendingConfirmation == nil)
        #expect(runtime.actions.isEmpty)

        await model.request(.uninstall(removeModels: false))
        await model.confirm(removeModels: true)
        #expect(runtime.actions == ["uninstall removeModels=true"])
        #expect(model.pendingConfirmation == nil)

        // Removing a model and overwriting one already there ask too.
        await model.request(.remove(model: "qwen3:0.6b"))
        #expect(model.pendingConfirmation == .removeModel("qwen3:0.6b"))
        await model.confirm()
        await model.request(.pull(model: "qwen3:0.6b"))
        #expect(model.pendingConfirmation == .overwriteModel("qwen3:0.6b"))
        await model.confirm()
        #expect(runtime.actions == ["uninstall removeModels=true", "remove qwen3:0.6b", "pull qwen3:0.6b force=true"])

        // A new model is pulled at once, without --force.
        await model.request(.pull(model: "gemma3:1b"))
        #expect(model.pendingConfirmation == nil)
        #expect(runtime.actions.last == "pull gemma3:1b force=false")
    }

    @Test func keyUnavailableOffersTerminal() async {
        let runtime = FakeAIRuntime(status: runtimeStatus())
        runtime.fail(with: GuestSSHError.keyUnavailable("/Users/x/.ssh/id_ed25519"))
        let model = makeModel(runtime)
        await model.request(.start)
        let error = model.error
        #expect(error?.offersTerminal == true)
        #expect(error?.message.hasPrefix("La chiave /Users/x/.ssh/id_ed25519 non è disponibile") == true)

        runtime.fail(with: AIRuntimeError.busy)
        await model.request(.restart)
        #expect(model.error?.offersTerminal == false)
        #expect(model.error?.message == "Nella VM è già in corso un'altra operazione di Ollama: riprova tra poco")
        model.dismissError()
        #expect(model.error == nil)
    }

    @Test func logOnRequest() async {
        let runtime = FakeAIRuntime(status: runtimeStatus())
        let model = makeModel(runtime)
        #expect(model.log == nil)
        await model.readLog()
        #expect(model.log == "riga 1\nriga 2\n")
        #expect(runtime.calls.contains("log"))
    }

    @Test func phaseOneFromGuestToolsAndMonitor() async {
        let runtime = FakeAIRuntime(status: runtimeStatus())
        let without = makeModel(runtime, guestToolsVersion: nil)
        await without.loadConfiguration()
        #expect(without.phase1 == .notInstalled)

        let model = makeModel(runtime)
        await model.loadConfiguration()
        #expect(model.phase1 == .waitingForGuest)
        model.guestResponds = true
        #expect(model.phase1 == .ready)
    }

    @Test func phaseTwoFollowsMonitorSteps() async throws {
        let runtime = FakeAIRuntime(status: runtimeStatus(steps: [
            ProvisionStep(name: "model-pull", state: .running, message: "In corso", updated: "2026-10-25T10:00:00+00:00",
                          model: "qwen3:0.6b"),
        ]))
        let model = makeModel(runtime)
        await model.refresh()
        #expect(model.phase2Steps.first?.state == .running)
        // The monitor's provisioning field (vsock) is newer: it wins without an SSH round trip.
        let doc = #"{"version":"2.0","provisioning":{"version":1,"steps":{"model-pull":{"state":"failed","message":"interrotto","model":"qwen3:0.6b","updated":"2026-10-25T10:01:00+00:00"}}}}"#
        model.monitorSteps = try GuestStatus.decode(Data(doc.utf8)).provisioning?.steps ?? [:]
        #expect(model.failedStep?.state == .failed)
        #expect(model.failedStep?.message == "interrotto")
    }

    // MARK: - Retry and confirmation

    /// "Riprova" while a confirmation is shown does nothing: the question comes first.
    @Test func retryRespectsPendingConfirmation() async {
        let runtime = FakeAIRuntime(status: runtimeStatus(models: [OllamaModel(name: "qwen3:0.6b", sizeBytes: 1)], steps: [
            ProvisionStep(name: "model-pull", state: .failed, message: "interrotto", model: "qwen3:0.6b"),
        ]))
        let model = makeModel(runtime)
        await model.refresh()
        await model.request(.remove(model: "qwen3:0.6b"))
        #expect(model.pendingConfirmation == .removeModel("qwen3:0.6b"))
        await model.retry()
        #expect(runtime.actions.isEmpty)
        #expect(model.pendingConfirmation == .removeModel("qwen3:0.6b"))
    }

    /// A status read in the background (after an action, or by the view) that fails is not the
    /// user's action error: it goes to `refreshError`.
    @Test func backgroundRefreshFailureIsNotAnActionError() async {
        let runtime = FakeAIRuntime(status: runtimeStatus())
        let model = makeModel(runtime)
        runtime.failStatus(with: GuestSSHError.unreachable)
        await model.refresh()
        #expect(model.error == nil)
        #expect(model.refreshError != nil)
        runtime.failStatus(with: nil)
        await model.refresh()
        #expect(model.refreshError == nil)
    }

    // MARK: - AI section

    /// A download shows the guest's progress while it runs; Scarica is not offered meanwhile.
    @Test func pullShowsProgress() async {
        let runtime = FakeAIRuntime(status: runtimeStatus())
        let progress = PullProgress(
            completedBytes: 1_181_116_007, totalBytes: 2_684_354_560, message: "scaricamento", warning: nil)
        runtime.gatePull(progress: progress)
        let model = makeModel(runtime)
        await model.refresh()
        let task = Task { await model.requestPull("  qwen3:4b ") }
        while model.activity?.progress == nil { await Task.yield() }
        #expect(model.activity?.action == .pull(model: "qwen3:4b"))
        #expect(model.activity?.progress == progress)
        #expect(AIRuntimeModel.progressText(progress) == "Download · 1,1 GiB di 2,5 GiB · 44 %")
        #expect(!model.canStartAction)
        runtime.openPullGate()
        await task.value
        #expect(model.activity == nil)
        #expect(runtime.actions == ["pull qwen3:4b force=false"])

        // A name that is not an official identifier is refused before anything runs.
        await model.requestPull("rm -rf /")
        #expect(model.error?.message == "Nome del modello non valido: usa nome:variante, per esempio llama3.2:1b.")
        #expect(runtime.actions == ["pull qwen3:4b force=false"])
        await model.requestPull("   ")
        #expect(runtime.actions == ["pull qwen3:4b force=false"])
    }

    /// "Installa Ollama" first downloads the archive on the Mac: its progress shows like a
    /// model's, and cancelling it says that the VM was not touched.
    @Test func macDownloadShowsProgressAndCancels() async {
        let runtime = FakeAIRuntime(status: runtimeStatus(installed: false, running: false))
        runtime.holdInstall(reporting: DownloadProgress(receivedBytes: 400 << 20, expectedBytes: 1_564_567_595))
        let model = makeModel(runtime)
        await model.refresh()
        let task = Task { await model.request(.install) }
        while model.activity?.progress == nil { await Task.yield() }
        let progress = model.activity?.progress
        #expect(progress?.message == AIRuntimeModel.macDownloadMessage)
        #expect(progress?.completedBytes == 400 << 20)
        #expect(progress?.totalBytes == 1_564_567_595)
        model.cancel()
        await task.value
        #expect(model.activity == nil)
        #expect(model.note == "Download di Ollama annullato: la VM non è stata toccata. Riprova quando vuoi.")
        #expect(model.error == nil)
        #expect(runtime.actions.isEmpty)
    }

    /// Removing a model asks first, with its size; overwriting one asks with the agreed copy.
    @Test func removeModelAsks() async {
        let model3 = OllamaModel(name: "llama3.2:1b", sizeBytes: 1_395_864_371)
        let runtime = FakeAIRuntime(status: runtimeStatus(models: [model3]))
        let model = makeModel(runtime)
        await model.refresh()
        #expect(ByteSize.text(model3.sizeBytes) == "1,3 GiB")

        await model.request(.remove(model: "llama3.2:1b"))
        #expect(runtime.actions.isEmpty)
        let remove = model.confirmationCopy(vmName: "debian-ai")
        #expect(remove?.title == "Rimuovere llama3.2:1b da debian-ai?")
        #expect(remove?.message == "Il modello (1,3 GiB) viene cancellato dalla VM. Puoi scaricarlo di nuovo quando vuoi.")
        #expect(remove?.action == "Rimuovi")
        #expect(remove?.isDestructive == true)
        model.cancelConfirmation()
        #expect(runtime.actions.isEmpty)

        await model.request(.remove(model: "llama3.2:1b"))
        await model.confirm()
        #expect(runtime.actions == ["remove llama3.2:1b"])

        await model.requestPull("llama3.2:1b")
        let overwrite = model.confirmationCopy(vmName: "debian-ai")
        #expect(overwrite?.title == "Il modello llama3.2:1b esiste già nella VM: scaricarlo di nuovo e sovrascriverlo?")
        #expect(overwrite?.action == "Sovrascrivi")
        #expect(runtime.actions == ["remove llama3.2:1b"])
        await model.confirm()
        #expect(runtime.actions == ["remove llama3.2:1b", "pull llama3.2:1b force=true"])

        await model.request(.uninstall(removeModels: false))
        let uninstall = model.confirmationCopy(vmName: "debian-ai")
        #expect(uninstall?.title == "Disinstallare Ollama da debian-ai?")
        #expect(uninstall?.removeModelsDetail == "llama3.2:1b: 1,3 GiB nella VM.")
        #expect(uninstall?.action == "Disinstalla")
    }

    /// Guest-reported byte counts out of any real range never trap the app, which hosts every VM
    /// (audit NV-1): the pull percentage is clamped before it becomes an Int.
    @Test func progressTextSurvivesHostileCounts() {
        let huge = PullProgress(completedBytes: .max, totalBytes: 1, message: "", warning: nil)
        #expect(AIRuntimeModel.progressText(huge).hasSuffix("· 100 %"))
        let big = PullProgress(completedBytes: 100_000_000_000_000_000, totalBytes: 1, message: "", warning: nil)
        #expect(AIRuntimeModel.progressText(big).hasSuffix("· 100 %"))
    }

    /// The memory warning under a download comes from the guest with its code: shown in the app's
    /// language, as a sentence. Older Guest Tools' Italian text is shown as it arrives.
    @Test func memoryWarningIsShownByItsCode() {
        #expect(AIRuntimeModel.warningText(
            "model_memory_low: the VM has 2.0 GiB of RAM and the model takes 4.1 GiB: it may be slow or fail to start")
            == "La VM ha 2,0 GiB di RAM, il modello occupa 4,1 GiB: potrebbe essere lento o non avviarsi")
        #expect(AIRuntimeModel.warningText("la VM ha 2.0 GiB di RAM, il modello occupa 4.1 GiB: potrebbe essere lento o non avviarsi")
            == "La VM ha 2.0 GiB di RAM, il modello occupa 4.1 GiB: potrebbe essere lento o non avviarsi")
        #expect(AIRuntimeModel.warningText("") == "")
    }

    /// The uninstall summary adds guest model sizes without overflowing (audit NV-1).
    @Test func uninstallCopySurvivesHostileSizes() async {
        let models = [OllamaModel(name: "a", sizeBytes: .max), OllamaModel(name: "b", sizeBytes: .max)]
        let runtime = FakeAIRuntime(status: runtimeStatus(models: models))
        let model = makeModel(runtime)
        await model.refresh()
        await model.request(.uninstall(removeModels: false))
        let uninstall = model.confirmationCopy(vmName: "debian-ai")
        #expect(uninstall?.removeModelsDetail?.hasPrefix("a e b: ") == true)
    }

    /// The chat streams the answer piece by piece; Interrompi stops the guest's request.
    @Test func chatCancelStopsStream() async {
        let runtime = FakeAIRuntime(status: runtimeStatus(models: [OllamaModel(name: "llama3.2:1b", sizeBytes: 1)]))
        runtime.setChat(pieces: ["Uno, ", "due"], finishes: false)
        let model = makeModel(runtime)
        await model.refresh()
        let chat = model.chat
        #expect(chat.models == ["llama3.2:1b"])
        #expect(chat.selectedModel == "llama3.2:1b")
        chat.draft = "  Conta fino a tre "
        let task = Task { await chat.send() }
        while chat.turns.last?.text != "Uno, due" { await Task.yield() }
        #expect(chat.isAnswering)
        #expect(chat.draft.isEmpty)
        #expect(chat.turns.map(\.role) == [.user, .assistant])
        #expect(runtime.chatMessages == [[ChatMessage(role: .user, content: "Conta fino a tre")]])

        // One chat at a time: a second message waits for this answer.
        chat.draft = "Altro"
        await chat.send()
        #expect(runtime.chatMessages.count == 1)

        chat.cancel()
        await task.value
        #expect(!chat.isAnswering)
        #expect(runtime.chatTerminated)
        #expect(chat.turns.map(\.text) == ["Conta fino a tre", "Uno, due"])
        #expect(chat.note == "Risposta interrotta.")

        // The next turn carries the conversation so far (in memory only).
        runtime.setChat(pieces: ["Tre."], finishes: true)
        await chat.send()
        #expect(runtime.chatMessages.last == [
            ChatMessage(role: .user, content: "Conta fino a tre"), ChatMessage(role: .assistant, content: "Uno, due"),
            ChatMessage(role: .user, content: "Altro"),
        ])
        #expect(chat.turns.last?.text == "Tre.")
        #expect(chat.note == nil)

        chat.clear()
        #expect(chat.turns.isEmpty)
    }

    /// The VM stops while an answer arrives: the chat stops too.
    @Test func chatStopsWithTheVM() async {
        let runtime = FakeAIRuntime(status: runtimeStatus(models: [OllamaModel(name: "llama3.2:1b", sizeBytes: 1)]))
        runtime.setChat(pieces: ["Ciao"], finishes: false)
        let model = makeModel(runtime)
        await model.refresh()
        model.chat.draft = "Ciao"
        let task = Task { await model.chat.send() }
        while model.chat.turns.last?.text != "Ciao" || model.chat.turns.count < 2 { await Task.yield() }
        model.isVMRunning = false
        await task.value
        #expect(runtime.chatTerminated)
        #expect(!model.chat.isAnswering)
        #expect(!model.chat.canSend)
    }

    // MARK: - Review fixes

    /// "Cancella anche i modelli" is off whenever the uninstall sheet opens, also after it was
    /// switched on and the sheet cancelled.
    @Test func uninstallRemoveModelsResets() async {
        let runtime = FakeAIRuntime(status: runtimeStatus(models: [OllamaModel(name: "qwen3:0.6b", sizeBytes: 1)]))
        let model = makeModel(runtime)
        await model.refresh()
        await model.request(.uninstall(removeModels: false))
        #expect(!model.removeModelsOnUninstall)
        model.removeModelsOnUninstall = true
        model.cancelConfirmation()
        #expect(!model.removeModelsOnUninstall)
        await model.request(.uninstall(removeModels: false))
        #expect(!model.removeModelsOnUninstall)
        model.removeModelsOnUninstall = true
        await model.confirm(removeModels: model.removeModelsOnUninstall)
        #expect(runtime.actions == ["uninstall removeModels=true"])
        #expect(!model.removeModelsOnUninstall)
    }

    /// While an answer streams, Ferma, Rimuovi and Disinstalla wait (nothing changes Ollama
    /// under the chat).
    @Test func actionsWaitForTheChat() async {
        let runtime = FakeAIRuntime(status: runtimeStatus(models: [OllamaModel(name: "llama3.2:1b", sizeBytes: 1)]))
        runtime.setChat(pieces: ["Ciao"], finishes: false)
        let model = makeModel(runtime)
        await model.refresh()
        model.chat.draft = "Ciao"
        let task = Task { await model.chat.send() }
        while model.chat.turns.count < 2 || model.chat.turns.last?.text != "Ciao" { await Task.yield() }
        #expect(!model.canStartAction)
        await model.request(.stop)
        await model.request(.remove(model: "llama3.2:1b"))
        await model.request(.uninstall(removeModels: false))
        #expect(runtime.actions.isEmpty)
        #expect(model.pendingConfirmation == nil)
        model.chat.cancel()
        await task.value
        #expect(model.canStartAction)
        await model.request(.stop)
        #expect(runtime.actions == ["stop"])
    }

    /// "Cancella la chat" during an answer: no "Risposta interrotta." afterwards.
    @Test func clearDuringAnswerLeavesNoNote() async {
        let runtime = FakeAIRuntime(status: runtimeStatus(models: [OllamaModel(name: "llama3.2:1b", sizeBytes: 1)]))
        runtime.setChat(pieces: ["Ciao"], finishes: false)
        let model = makeModel(runtime)
        await model.refresh()
        model.chat.draft = "Ciao"
        let task = Task { await model.chat.send() }
        while model.chat.turns.count < 2 || model.chat.turns.last?.text != "Ciao" { await Task.yield() }
        model.chat.clear()
        await task.value
        #expect(model.chat.turns.isEmpty)
        #expect(model.chat.note == nil)
        #expect(model.chat.error == nil)
        #expect(runtime.chatTerminated)
    }

    /// An answer longer than the cap is cut there and stopped, with a note.
    @Test func longAnswerIsCapped() async {
        let runtime = FakeAIRuntime(status: runtimeStatus())
        runtime.setChat(pieces: ["abc", "defgh", "ijk"], finishes: false)
        let chat = LocalChatModel(makeRuntime: { runtime }, maxAnswerCharacters: 5)
        chat.isVMRunning = true
        chat.setModels(["llama3.2:1b"])
        chat.draft = "Scrivi"
        await chat.send()
        #expect(chat.turns.last?.text == "abcde")
        #expect(chat.note == "Risposta troppo lunga: Nido l'ha interrotta a 5 caratteri.")
        #expect(runtime.chatTerminated)
        #expect(!chat.isAnswering)
        #expect(LocalChatModel.defaultMaxAnswerCharacters == 200_000)
    }

    /// The answer's length is kept as it grows (never recounted from the whole text for each
    /// piece), starts again at 0 for each answer and still cuts exactly at the cap.
    @Test func answerLengthIsKeptPerAnswer() async {
        let runtime = FakeAIRuntime(status: runtimeStatus())
        runtime.setChat(pieces: ["ab", "cd", "e"], finishes: true)
        let chat = LocalChatModel(makeRuntime: { runtime }, maxAnswerCharacters: 6)
        chat.isVMRunning = true
        chat.setModels(["llama3.2:1b"])
        chat.draft = "Uno"
        await chat.send()
        #expect(chat.turns.last?.text == "abcde")
        #expect(chat.answerCharacters == 5)
        chat.draft = "Due"
        await chat.send()
        #expect(chat.turns.last?.text == "abcde")  // a new answer: the count starts again
        #expect(chat.answerCharacters == 5)
        #expect(chat.note == nil)
        runtime.setChat(pieces: ["abcd", "efgh"], finishes: false)
        chat.draft = "Tre"
        await chat.send()
        #expect(chat.turns.last?.text == "abcdef")
        #expect(chat.answerCharacters == 6)
        #expect(chat.note == "Risposta troppo lunga: Nido l'ha interrotta a 6 caratteri.")
    }

    /// The cap counts Unicode scalars, not Characters: a guest's answer of letters loaded with
    /// combining marks (one Character each) cannot grow past the cap in bytes (audit NV-3).
    @Test func capCountsScalarsNotCharacters() async {
        let heavy = "a" + String(repeating: "\u{301}", count: 100)
        let runtime = FakeAIRuntime(status: runtimeStatus())
        runtime.setChat(pieces: [heavy, heavy], finishes: true)
        let chat = LocalChatModel(makeRuntime: { runtime }, maxAnswerCharacters: 50)
        chat.isVMRunning = true
        chat.setModels(["llama3.2:1b"])
        chat.draft = "Scrivi"
        await chat.send()
        #expect((chat.turns.last?.text.unicodeScalars.count ?? .max) <= 50)
        #expect(chat.note == "Risposta troppo lunga: Nido l'ha interrotta a 50 caratteri.")
    }

    // MARK: - Chat: Markdown, metrics, copy, batching

    /// Ollama's metrics stay with their answer; "Copia" copies the answer as written, never one
    /// still arriving, never a user message's empty answer.
    @Test func answerKeepsStatsAndCopies() async throws {
        let runtime = FakeAIRuntime(status: runtimeStatus())
        let stats = ChatStats(totalDuration: .milliseconds(4200), evalCount: 55, evalDuration: .seconds(3))
        runtime.setChat(pieces: ["**Ciao**", " mondo"], stats: stats, finishes: true)
        var copied: [String] = []
        let chat = LocalChatModel(makeRuntime: { runtime }, copyText: { copied.append($0) })
        chat.isVMRunning = true
        chat.setModels(["gemma3:1b"])
        chat.draft = "Ciao"
        await chat.send()
        let answer = try #require(chat.turns.last)
        #expect(answer.text == "**Ciao** mondo")
        #expect(answer.model == "gemma3:1b")
        #expect(chat.turns[0].model == nil)
        #expect(answer.stats == stats)
        #expect(LocalChatModel.statsLine(answer.stats) == "4,2 s · 18,3 token/s")
        chat.copy(answer.id)
        chat.copy(chat.turns[0].id)
        #expect(copied == ["**Ciao** mondo", "Ciao"])
        #expect(chat.answeringID == nil)
    }

    /// Ollama stopped (or never started after a reboot): the chat says what to do.
    @Test func ollamaNotRunningSaysHowToStartIt() {
        let message = AIRuntimeModel.errorState(for: AIRuntimeError.notRunning)?.message
        #expect(message == "Ollama non è in esecuzione nella VM: avvialo con Avvia nel pannello Locale.")
    }

    @Test func statsLineShowsWhatOllamaGave() {
        #expect(LocalChatModel.statsLine(nil) == nil)
        #expect(LocalChatModel.statsLine(ChatStats(totalDuration: nil, evalCount: nil, evalDuration: nil)) == nil)
        #expect(LocalChatModel.statsLine(ChatStats(totalDuration: .seconds(95), evalCount: nil, evalDuration: nil))
            == "1 min 35 s")
        #expect(LocalChatModel.statsLine(ChatStats(totalDuration: nil, evalCount: 2000, evalDuration: .seconds(1)))
            == "2000,0 token/s")
    }

    /// Pieces that arrive together are shown together, and a piece that arrives after the
    /// interval while the stream then stalls is still shown (the timer flushes it).
    @Test func piecesAreBatchedAndNeverHeldBack() async {
        let runtime = FakeAIRuntime(status: runtimeStatus())
        runtime.setChat(pieces: ["a", "b", "c"], finishes: false)
        let chat = LocalChatModel(makeRuntime: { runtime }, flushInterval: .milliseconds(30))
        chat.isVMRunning = true
        chat.setModels(["gemma3:1b"])
        chat.draft = "Ciao"
        let task = Task { await chat.send() }
        while chat.turns.count < 2 { await Task.yield() }
        // The first piece shows at once, the rest within the interval though the stream stalls.
        let deadline = ContinuousClock.now + .seconds(5)
        while chat.turns.last?.text != "abc", ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(chat.turns.last?.text == "abc")
        #expect(chat.isAnswering)
        #expect(!chat.isWaitingForFirstPiece)
        chat.cancel()
        await task.value
        #expect(chat.note == "Risposta interrotta.")
    }

    /// Before the first piece the answer is "waiting"; its empty bubble goes if nothing arrives.
    @Test func waitingForTheFirstPiece() async {
        let runtime = FakeAIRuntime(status: runtimeStatus())
        runtime.setChat(pieces: [], finishes: false)
        let chat = LocalChatModel(makeRuntime: { runtime })
        chat.isVMRunning = true
        chat.setModels(["gemma3:1b"])
        chat.draft = "Ciao"
        let revision = chat.revision
        let task = Task { await chat.send() }
        while chat.turns.count < 2 { await Task.yield() }
        #expect(chat.isWaitingForFirstPiece)
        #expect(chat.revision > revision)
        chat.cancel()
        await task.value
        #expect(!chat.isWaitingForFirstPiece)
        #expect(chat.turns.count == 1)
    }
}
