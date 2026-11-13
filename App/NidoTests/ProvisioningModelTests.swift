// SPDX-License-Identifier: Apache-2.0
import Foundation
import NidoCore
import Testing

@testable import Nido

@MainActor
struct ProvisioningModelTests {
    private func makeRuntime(_ runtime: FakeAIRuntime) -> AIRuntimeModel {
        let model = AIRuntimeModel(readGuestToolsVersion: { "1.0.0" }, makeRuntime: { runtime })
        model.isVMRunning = true
        return model
    }

    /// Nothing reaches the guest before it answers; then Ollama, the model and the check, once.
    @Test func phaseTwoWaitsForTheGuest() async {
        let runtime = FakeAIRuntime(status: runtimeStatus(installed: false, running: false))
        let provisioning = ProvisioningModel(aiRuntime: makeRuntime(runtime))
        provisioning.begin(ProvisioningPlan(model: "qwen3:0.6b"))
        #expect(provisioning.isShown)
        #expect(provisioning.phase1Rows.map(\.state) == [.done, .done, .running, .waiting])
        #expect(provisioning.phase2Rows.map(\.label) == ["Ollama", "Modello qwen3:0.6b", "Verifica"])
        #expect(runtime.actions.isEmpty)
        await provisioning.guestAnswered()
        #expect(runtime.actions == ["install", "pull qwen3:0.6b force=false", "verify"])
        #expect(provisioning.isComplete)
        #expect(provisioning.phase1Rows.allSatisfy { $0.state == .done })
        // A later sample does not run anything again.
        await provisioning.guestAnswered()
        #expect(runtime.actions.count == 3)
    }

    /// Without Ollama the panel follows phase 1 only and ends when the guest answers.
    @Test func phaseOneOnly() async {
        let runtime = FakeAIRuntime(status: runtimeStatus(installed: false, running: false))
        let provisioning = ProvisioningModel(aiRuntime: makeRuntime(runtime))
        provisioning.begin(nil)
        #expect(provisioning.phase2Rows.isEmpty)
        await provisioning.guestAnswered()
        #expect(runtime.actions.isEmpty)
        #expect(provisioning.isComplete)
    }

    /// A failure stops the sequence with the error; Riprova resumes from the failed step (Ollama,
    /// already installed, is not installed again).
    @Test func retryResumesFromTheFailedStep() async {
        let runtime = FakeAIRuntime(status: runtimeStatus(installed: true, running: true, steps: [
            ProvisionStep(name: "ollama-install", state: .done, message: "installato"),
        ]))
        runtime.fail(with: GuestSSHError.unreachable)
        let ai = makeRuntime(runtime)
        let provisioning = ProvisioningModel(aiRuntime: ai)
        provisioning.begin(ProvisioningPlan(model: "qwen3:0.6b"))
        await provisioning.guestAnswered()
        #expect(runtime.actions == ["pull qwen3:0.6b force=false"])
        #expect(provisioning.failure != nil)
        #expect(!provisioning.isComplete)

        runtime.fail(with: nil)
        await provisioning.retry()
        #expect(runtime.actions == ["pull qwen3:0.6b force=false", "pull qwen3:0.6b force=false", "verify"])
        #expect(provisioning.failure == nil)
        #expect(provisioning.isComplete)
    }

    // MARK: - Review fixes

    /// A runtime busy with a question (or another action): nothing runs and nothing is declared done.
    @Test func busyRuntimeNeverCompletes() async {
        let runtime = FakeAIRuntime(status: runtimeStatus(
            installed: false, running: false, models: [OllamaModel(name: "qwen3:0.6b", sizeBytes: 1)]))
        let ai = makeRuntime(runtime)
        await ai.refresh()
        await ai.request(.remove(model: "qwen3:0.6b"))
        #expect(ai.pendingConfirmation != nil)
        let provisioning = ProvisioningModel(aiRuntime: ai)
        provisioning.begin(ProvisioningPlan(model: "qwen3:0.6b"))
        await provisioning.guestAnswered()
        #expect(runtime.actions.isEmpty)
        #expect(!provisioning.isComplete)
    }

    /// An action that returns without the guest recording its step done: no success.
    @Test func unverifiedStepDoesNotComplete() async {
        let runtime = FakeAIRuntime(status: runtimeStatus(installed: false, running: false))
        runtime.stopRecordingSteps()
        let provisioning = ProvisioningModel(aiRuntime: makeRuntime(runtime))
        provisioning.begin(ProvisioningPlan(model: nil))
        await provisioning.guestAnswered()
        #expect(runtime.actions == ["install"])
        #expect(!provisioning.isComplete)
        #expect(provisioning.failure != nil)
    }

    /// "Non installare": the plan goes (and its record in the config), phase 1 stays.
    @Test func declineClearsThePlan() async {
        let runtime = FakeAIRuntime(status: runtimeStatus(installed: false, running: false))
        var cleared = 0
        let provisioning = ProvisioningModel(aiRuntime: makeRuntime(runtime), clearPending: { cleared += 1 })
        provisioning.begin(ProvisioningPlan(model: "qwen3:0.6b"))
        await provisioning.decline()
        #expect(provisioning.plan == nil)
        #expect(cleared == 1)
        await provisioning.guestAnswered()
        #expect(runtime.actions.isEmpty)
        #expect(provisioning.isComplete)
    }

    /// Verified success clears the record too.
    @Test func successClearsThePending() async {
        let runtime = FakeAIRuntime(status: runtimeStatus(installed: false, running: false))
        var cleared = 0
        let provisioning = ProvisioningModel(aiRuntime: makeRuntime(runtime), clearPending: { cleared += 1 })
        provisioning.begin(ProvisioningPlan(model: nil))
        await provisioning.guestAnswered()
        #expect(provisioning.isComplete)
        #expect(cleared == 1)
    }

    /// The guest never answered within the grace: phase 1 failed, polling stops; the guest
    /// answering later (Monitor tab) recovers.
    @Test func phaseOneFailureStopsPolling() async {
        let runtime = FakeAIRuntime(status: runtimeStatus(installed: false, running: false))
        let monitor = MonitorModel()
        let provisioning = ProvisioningModel(aiRuntime: makeRuntime(runtime), monitor: monitor)
        provisioning.begin(ProvisioningPlan(model: nil))
        #expect(monitor.keepsPolling)
        provisioning.guestNeverAnswered()
        #expect(provisioning.phase1Failed)
        #expect(!monitor.keepsPolling)
        #expect(provisioning.phase1Rows.contains { $0.state == .failed })
        await provisioning.guestAnswered()
        #expect(!provisioning.phase1Failed)
        #expect(provisioning.isComplete)
    }

    /// "Smetti di attendere" and a failure stop the background polling (the Monitor tab polls by itself).
    @Test func stopWaitingStopsPolling() {
        let runtime = FakeAIRuntime(status: runtimeStatus())
        let monitor = MonitorModel()
        let provisioning = ProvisioningModel(aiRuntime: makeRuntime(runtime), monitor: monitor)
        provisioning.begin(ProvisioningPlan(model: nil))
        #expect(monitor.keepsPolling)
        provisioning.stopWaiting()
        #expect(!monitor.keepsPolling)
    }
}
