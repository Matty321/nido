// SPDX-License-Identifier: Apache-2.0
import CryptoKit
import Darwin
import Foundation
import Testing
@testable import NidoCore

/// A stand-in for `VMSession` that can be suspended, restored and started: records the calls,
/// writes a fake saved state.
@MainActor
final class FakeSuspendableMachine: SuspendableMachine {
    let bundleURL: URL
    var state: VMRunState
    let attachedStateHash: String
    var unsupportedReason: String?
    var saveFails = false
    var restoreError: NidoError?
    let stopRequestedDuringRestore = false
    /// When true, `stop` leaves the machine paused (a forced stop that failed).
    var stopFails = false
    var calls: [String] = []

    init(bundle: VMBundle, hash: String = "fake-hash", state: VMRunState = .running) {
        bundleURL = bundle.url
        attachedStateHash = hash
        self.state = state
    }

    func validateSaveRestoreSupport() throws {
        if let unsupportedReason { throw NidoError.snapshotUnsupported(unsupportedReason) }
    }

    func start() async throws {
        calls.append("start")
        state = .running
    }

    func pause() async throws {
        calls.append("pause")
        guard state == .running else { throw NidoError.notRunning("vm") }
        state = .paused
    }

    /// When true, `resume` fails and the machine stays paused.
    var resumeFails = false

    func resume() async throws {
        calls.append("resume")
        guard state == .paused else { throw NidoError.notRunning("vm") }
        if resumeFails { throw NidoError.notRunning("ripresa rifiutata") }
        state = .running
    }

    func saveMachineState(to url: URL) async throws {
        calls.append("save")
        guard state == .paused else { throw NidoError.notRunning("vm") }
        if saveFails {
            try Data("half".utf8).write(to: url)
            throw NidoError.snapshotUnsupported("disco pieno")
        }
        try Data("saved-state".utf8).write(to: url)
    }

    func restoreMachineState(from url: URL) async throws {
        calls.append("restore")
        if let restoreError { throw restoreError }
        guard FileManager.default.fileExists(atPath: url.path) else { throw NidoError.restoreFailed("manca") }
        state = .paused
    }

    func stop(gracePeriod: Duration) async {
        calls.append("stop")
        if stopFails { state = .error("non si ferma"); return }
        state = .stopped
    }
}

@Suite(.italian) struct SuspendTests {
    struct Env {
        let tmp: URL
        let paths: NidoPaths
        let bundle: VMBundle

        init(guest: GuestOS = .linux) throws {
            tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("nido-test-suspend-\(UUID().uuidString)", isDirectory: true)
            paths = NidoPaths(root: tmp.appendingPathComponent("VMs", isDirectory: true))
            let config = VMConfig(
                id: UUID(), name: try VMName("vm"), guest: guest, cpuCount: 2,
                memoryBytes: 1 << 30, diskBytes: 1 << 20, macAddress: "02:00:00:00:00:01")
            bundle = try VMBundle.create(config: config, paths: paths)
        }

        /// A suspended VM: `state.vzvmsave` and the hash it was saved with.
        func suspend(hash: String?, file: Bool = true) throws {
            if file {
                try Data("saved-state".utf8).write(to: bundle.stateURL)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: bundle.stateURL.path)
            }
            var config = try bundle.readConfig()
            config.suspendedConfigHash = hash
            try bundle.writeConfig(config)
        }

        var stateExists: Bool {
            var info = stat()
            return lstat(bundle.stateURL.path, &info) == 0
        }

        func hash() throws -> String? { try bundle.readConfig().suspendedConfigHash }

        func cleanup() { try? FileManager.default.removeItem(at: tmp) }
    }

    func perms(_ url: URL) throws -> Int {
        let a = try FileManager.default.attributesOfItem(atPath: url.path)
        return (a[.posixPermissions] as! NSNumber).intValue
    }

    // MARK: - Suspend

    @Test @MainActor func suspendWritesStateAndHash() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let machine = FakeSuspendableMachine(bundle: env.bundle, hash: "attached-hash")
        try await SuspendedState.suspend(machine, bundle: env.bundle)
        #expect(machine.calls == ["pause", "save", "stop"])
        #expect(machine.state == .stopped)
        #expect(env.stateExists)
        #expect(try perms(env.bundle.stateURL) == 0o600)
        // The hash of the machine that ran (R-M3A-12), not the plain config hash.
        #expect(try env.hash() == "attached-hash")
        #expect(env.bundle.hasSuspendedState(try env.bundle.readConfig()))
    }

    @Test @MainActor func suspendOfAPausedVMDoesNotResumeIt() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let machine = FakeSuspendableMachine(bundle: env.bundle, state: .paused)
        try await SuspendedState.suspend(machine, bundle: env.bundle)
        #expect(machine.calls == ["save", "stop"])
        #expect(try env.hash() == "fake-hash")
    }

    @Test @MainActor func suspendReplacesAStaleState() async throws {
        let env = try Env()
        defer { env.cleanup() }
        try Data("stale".utf8).write(to: env.bundle.stateURL)
        let machine = FakeSuspendableMachine(bundle: env.bundle)
        try await SuspendedState.suspend(machine, bundle: env.bundle)
        #expect(String(decoding: try Data(contentsOf: env.bundle.stateURL), as: UTF8.self) == "saved-state")
    }

    @Test @MainActor func failedSaveResumesAndKeepsNothing() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let machine = FakeSuspendableMachine(bundle: env.bundle)
        machine.saveFails = true
        await #expect(throws: NidoError.self) { try await SuspendedState.suspend(machine, bundle: env.bundle) }
        #expect(machine.calls == ["pause", "save", "resume"])
        #expect(machine.state == .running)
        #expect(!env.stateExists)
        #expect(try env.hash() == nil)
    }

    @Test @MainActor func unsupportedConfigurationIsRefusedBeforePausing() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let machine = FakeSuspendableMachine(bundle: env.bundle)
        machine.unsupportedReason = "dispositivo non supportato"
        await #expect(throws: NidoError.suspendFailed(SuspendedState.unsupportedReason("dispositivo non supportato"))) {
            try await SuspendedState.suspend(machine, bundle: env.bundle)
        }
        #expect(machine.calls.isEmpty)
        #expect(!env.stateExists)
    }

    @Test @MainActor func failedStopAfterSaveInvalidatesTheState() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let machine = FakeSuspendableMachine(bundle: env.bundle)
        machine.stopFails = true
        await #expect(throws: NidoError.self) { try await SuspendedState.suspend(machine, bundle: env.bundle) }
        // The machine may go on: its saved state must never be resumed over a newer disk.
        #expect(try env.hash() == nil)
        #expect(!env.stateExists)
    }

    @Test @MainActor func suspendRefusedWhenNotRunning() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let machine = FakeSuspendableMachine(bundle: env.bundle, state: .stopped)
        await #expect(throws: NidoError.notRunning("vm")) { try await SuspendedState.suspend(machine, bundle: env.bundle) }
        #expect(machine.calls.isEmpty)
    }

    // MARK: - Start

    @Test @MainActor func startRestoresWhenHashMatches() async throws {
        let env = try Env()
        defer { env.cleanup() }
        try env.suspend(hash: "fake-hash")
        let machine = FakeSuspendableMachine(bundle: env.bundle, state: .stopped)
        let outcome = try await SuspendedState.boot(machine, bundle: env.bundle)
        #expect(outcome == .resumed)
        #expect(machine.calls == ["restore", "resume"])
        #expect(machine.state == .running)
        // Consumed: a later start never resumes it over the disk the guest has written since.
        #expect(try env.hash() == nil)
        #expect(!env.stateExists)
    }

    @Test @MainActor func startDiscardsStateWhenConfigChanged() async throws {
        let env = try Env()
        defer { env.cleanup() }
        try env.suspend(hash: "hash-with-2-cpus")
        let machine = FakeSuspendableMachine(bundle: env.bundle, hash: "hash-with-4-cpus", state: .stopped)
        let outcome = try await SuspendedState.boot(machine, bundle: env.bundle)
        #expect(outcome == .discarded(SuspendedState.configChangedWarning))
        #expect(SuspendedState.configChangedWarning == "Lo stato sospeso è stato scartato perché la configurazione è cambiata")
        #expect(machine.calls == ["start"])
        #expect(try env.hash() == nil)
        #expect(!env.stateExists)
    }

    @Test @MainActor func restoreFailureDiscardsAndStartsCold() async throws {
        let env = try Env()
        defer { env.cleanup() }
        try env.suspend(hash: "fake-hash")
        let machine = FakeSuspendableMachine(bundle: env.bundle, state: .stopped)
        machine.restoreError = .restoreFailed("formato di un'altra versione di macOS")
        let outcome = try await SuspendedState.boot(machine, bundle: env.bundle)
        guard case .discarded(let warning) = outcome else {
            Issue.record("atteso discarded, ottenuto \(outcome)")
            return
        }
        #expect(warning.contains("formato di un'altra versione di macOS"))
        #expect(machine.calls == ["restore", "start"])
        #expect(try env.hash() == nil)
        #expect(!env.stateExists)
    }

    /// The disk caching mode (`.cached` + `.full`) is not part of the compatibility hash:
    /// a state saved before the change recorded the hash of the same five inputs (CPU, memory, MAC,
    /// attached folders, Rosetta), so the next start still resumes it. The expected value is the
    /// SHA-256 of the canonical JSON written out here: adding any machine input (a disk mode among
    /// them) changes the hash and fails this test, which is the point. A state the framework
    /// refuses anyway is `oldSuspendedStateFallsBackToColdBoot`.
    @Test @MainActor func suspendedStateBeforeDiskModeChangeStillResumes() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let canonical = #"{"cpuCount":2,"macAddress":"02:00:00:00:00:01","memoryBytes":1073741824,"#
            + #""rosetta":false,"sharedFolders":[]}"#
        let preChange = SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
        try env.suspend(hash: preChange)
        let config = try env.bundle.readConfig()
        #expect(config.effectiveStateHash(attachedShareNames: [], rosettaAttached: false) == preChange)
        #expect(SuspendedState.nextStartResumes(bundle: env.bundle, config: config, rosettaState: .notInstalled))

        let machine = FakeSuspendableMachine(bundle: env.bundle, hash: preChange, state: .stopped)
        #expect(try await SuspendedState.boot(machine, bundle: env.bundle) == .resumed)
        #expect(machine.calls == ["restore", "resume"])
    }

    /// A state saved by a VM built before M3c (no vsock device) cannot be restored into the new
    /// configuration: Virtualization.framework refuses, the state is discarded with a warning
    /// and the VM boots cold (it must never fail to start).
    @Test @MainActor func oldSuspendedStateFallsBackToColdBoot() async throws {
        let env = try Env()
        defer { env.cleanup() }
        try env.suspend(hash: "fake-hash")
        let machine = FakeSuspendableMachine(bundle: env.bundle, state: .stopped)
        machine.restoreError = .restoreFailed("la configurazione non corrisponde (dispositivo vsock mancante)")
        let outcome = try await SuspendedState.boot(machine, bundle: env.bundle)
        guard case .discarded(let warning) = outcome else {
            Issue.record("atteso discarded, ottenuto \(outcome)")
            return
        }
        #expect(!warning.isEmpty)
        #expect(machine.calls == ["restore", "start"])
        #expect(machine.state == .running)
        #expect(try env.hash() == nil)
        #expect(!env.stateExists)
    }

    @Test @MainActor func otherRestoreErrorsAreThrown() async throws {
        let env = try Env()
        defer { env.cleanup() }
        try env.suspend(hash: "fake-hash")
        let machine = FakeSuspendableMachine(bundle: env.bundle, state: .stopped)
        machine.restoreError = .vmMustBeStopped("vm")
        await #expect(throws: NidoError.vmMustBeStopped("vm")) {
            _ = try await SuspendedState.boot(machine, bundle: env.bundle)
        }
        // The hash was cleared before the restore: the state is never resumed later.
        #expect(try env.hash() == nil)
    }

    @Test @MainActor func stateWithoutHashIsDiscarded() async throws {
        let env = try Env()
        defer { env.cleanup() }
        try env.suspend(hash: nil)
        let machine = FakeSuspendableMachine(bundle: env.bundle, state: .stopped)
        let outcome = try await SuspendedState.boot(machine, bundle: env.bundle)
        guard case .discarded = outcome else {
            Issue.record("atteso discarded, ottenuto \(outcome)")
            return
        }
        #expect(machine.calls == ["start"])
        #expect(!env.stateExists)
    }

    @Test @MainActor func hashWithoutStateIsCleared() async throws {
        let env = try Env()
        defer { env.cleanup() }
        try env.suspend(hash: "fake-hash", file: false)
        let machine = FakeSuspendableMachine(bundle: env.bundle, state: .stopped)
        let outcome = try await SuspendedState.boot(machine, bundle: env.bundle)
        guard case .discarded = outcome else {
            Issue.record("atteso discarded, ottenuto \(outcome)")
            return
        }
        #expect(machine.calls == ["start"])
        #expect(try env.hash() == nil)
    }

    @Test @MainActor func coldStartWithoutState() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let machine = FakeSuspendableMachine(bundle: env.bundle, state: .stopped)
        #expect(try await SuspendedState.boot(machine, bundle: env.bundle) == .coldStart)
        #expect(machine.calls == ["start"])
    }

    @Test @MainActor func suspendThenStartResumes() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let first = FakeSuspendableMachine(bundle: env.bundle)
        try await SuspendedState.suspend(first, bundle: env.bundle)
        let second = FakeSuspendableMachine(bundle: env.bundle, state: .stopped)
        #expect(try await SuspendedState.boot(second, bundle: env.bundle) == .resumed)
    }

    // MARK: - Listing

    @Test func suspendedLooksValidOnlyWithStateAndHash() throws {
        let env = try Env()
        defer { env.cleanup() }
        #expect(!env.bundle.hasSuspendedState(try env.bundle.readConfig()))
        try env.suspend(hash: "h", file: false)
        #expect(!env.bundle.hasSuspendedState(try env.bundle.readConfig()))
        try env.suspend(hash: nil)
        #expect(!env.bundle.hasSuspendedState(try env.bundle.readConfig()))
        try env.suspend(hash: "h")
        #expect(env.bundle.hasSuspendedState(try env.bundle.readConfig()))
        // An empty file is not a saved state.
        try Data().write(to: env.bundle.stateURL)
        #expect(!env.bundle.hasSuspendedState(try env.bundle.readConfig()))
    }

    @Test func listShowsSuspended() async throws {
        let env = try Env()
        defer { env.cleanup() }
        try env.suspend(hash: "h")
        let summaries = try await VMRegistry(paths: env.paths).summaries()
        #expect(summaries.map(\.isSuspended) == [true])
        #expect(summaries.map(\.status) == [.stopped])
        // Running: the lock wins (a resumed VM whose state is being consumed).
        let lock = try BundleLock.acquire(env.bundle, owner: .cli)
        defer { lock.release() }
        #expect(try await VMRegistry(paths: env.paths).summaries().map(\.isSuspended) == [false])
    }

    // MARK: - nido stop --suspend

    @Test func suspendRequestRefusesAnAppVM() throws {
        let env = try Env()
        defer { env.cleanup() }
        let name = try VMName("vm")
        #expect(throws: NidoError.notRunning("vm")) { try VMControl.requestSuspend(bundle: env.bundle, name: name) }
        let lock = try BundleLock.acquire(env.bundle, owner: .app)
        defer { lock.release() }
        #expect(throws: NidoError.ownedByApp("vm")) { try VMControl.requestSuspend(bundle: env.bundle, name: name) }
    }
}

extension SuspendTests {
    /// R-M3A-16 (b): only a file a suspend writes is handed to the framework.
    @Test @MainActor func invalidStateFileIsDiscardedWithoutRestoring() async throws {
        let env = try Env()
        defer { env.cleanup() }
        try env.suspend(hash: "fake-hash", file: false)
        try Data().write(to: env.bundle.stateURL)  // empty
        let machine = FakeSuspendableMachine(bundle: env.bundle, state: .stopped)
        let outcome = try await SuspendedState.boot(machine, bundle: env.bundle)
        #expect(outcome == .discarded("Lo stato sospeso è stato scartato perché il file dello stato non è valido"))
        #expect(machine.calls == ["start"])
        #expect(try env.hash() == nil)
        #expect(!env.stateExists)

        // A hard-linked state (nlink 2) is not valid either.
        try env.suspend(hash: "fake-hash")
        try FileManager.default.linkItem(at: env.bundle.stateURL, to: env.tmp.appendingPathComponent("link"))
        let second = FakeSuspendableMachine(bundle: env.bundle, state: .stopped)
        guard case .discarded = try await SuspendedState.boot(second, bundle: env.bundle) else {
            Issue.record("atteso discarded")
            return
        }
        #expect(second.calls == ["start"])
    }
}

/// A machine whose restore waits for the test (`finishRestore`), with `VMSession`'s contract for a
/// stop asked meanwhile: kept and carried out when the restore ends (stopped instead of paused on
/// success; `stopRequestedDuringRestore` and never started on failure).
@MainActor
final class GatedRestoreMachine: SuspendableMachine {
    let bundleURL: URL
    var state: VMRunState = .stopped
    let attachedStateHash = "fake-hash"
    var restoreError: NidoError?
    var calls: [String] = []
    private(set) var isRestoring = false
    private(set) var stopRequestedDuringRestore = false
    private var restoreGate: CheckedContinuation<Void, Never>?
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []

    init(bundle: VMBundle) { bundleURL = bundle.url }

    func validateSaveRestoreSupport() throws {}
    func start() async throws { calls.append("start"); state = .running }
    func pause() async throws { calls.append("pause"); state = .paused }
    func resume() async throws {
        calls.append("resume")
        guard state == .paused else { throw NidoError.notRunning("vm") }
        state = .running
    }
    func saveMachineState(to url: URL) async throws {}

    func restoreMachineState(from url: URL) async throws {
        calls.append("restore")
        isRestoring = true
        await withCheckedContinuation { restoreGate = $0 }
        isRestoring = false
        defer {
            let waiters = stopWaiters
            stopWaiters = []
            waiters.forEach { $0.resume() }
        }
        if let restoreError { throw restoreError }
        state = .paused
        if stopRequestedDuringRestore {
            calls.append("forced-stop")
            state = .stopped
        }
    }

    func stop(gracePeriod: Duration) async {
        if isRestoring {
            stopRequestedDuringRestore = true
            await withCheckedContinuation { stopWaiters.append($0) }
        }
        guard state.acceptsStop else { return }
        calls.append("stop")
        state = .stopped
    }

    var restoreStarted: Bool { restoreGate != nil }

    func finishRestore() {
        restoreGate?.resume()
        restoreGate = nil
    }
}

extension SuspendTests {
    /// Waits (yielding the main actor) until `condition` holds.
    @MainActor
    func eventually(_ condition: () -> Bool) async {
        for _ in 0..<1000 where !condition() { await Task.yield() }
    }

    /// R-M3A-22: Ctrl-C / nido stop / Arresta while the saved state is being restored is not
    /// lost: the machine ends stopped and the guest never runs.
    @Test @MainActor func stopDuringRestoreStopsInsteadOfResuming() async throws {
        let env = try Env()
        defer { env.cleanup() }
        try env.suspend(hash: "fake-hash")
        let machine = GatedRestoreMachine(bundle: env.bundle)
        let boot = Task { try await SuspendedState.boot(machine, bundle: env.bundle) }
        await eventually { machine.restoreStarted }
        let stop = Task { await machine.stop(gracePeriod: .seconds(30)) }
        await eventually { machine.stopRequestedDuringRestore }
        machine.finishRestore()
        let outcome = try await boot.value
        await stop.value
        #expect(outcome == .stoppedWhileResuming)
        #expect(!machine.calls.contains("resume"))
        #expect(!machine.calls.contains("start"))
        #expect(machine.state == .stopped)
        // The state was consumed by the restore: never resumed again.
        #expect(try env.hash() == nil)
        #expect(!env.stateExists)
    }

    /// A stop asked during a restore that fails: no cold start follows.
    @Test @MainActor func stopDuringFailedRestoreDoesNotStartCold() async throws {
        let env = try Env()
        defer { env.cleanup() }
        try env.suspend(hash: "fake-hash")
        let machine = GatedRestoreMachine(bundle: env.bundle)
        machine.restoreError = .restoreFailed("formato non valido")
        let boot = Task { try await SuspendedState.boot(machine, bundle: env.bundle) }
        await eventually { machine.restoreStarted }
        let stop = Task { await machine.stop(gracePeriod: .seconds(30)) }
        await eventually { machine.stopRequestedDuringRestore }
        machine.finishRestore()
        let outcome = try await boot.value
        await stop.value
        #expect(outcome == .stoppedWhileResuming)
        #expect(machine.calls == ["restore"])
        #expect(machine.state == .stopped)
        #expect(try env.hash() == nil)
        #expect(!env.stateExists)
    }

    /// The restore without a stop still resumes (the gate itself changes nothing).
    @Test @MainActor func gatedRestoreWithoutStopResumes() async throws {
        let env = try Env()
        defer { env.cleanup() }
        try env.suspend(hash: "fake-hash")
        let machine = GatedRestoreMachine(bundle: env.bundle)
        let boot = Task { try await SuspendedState.boot(machine, bundle: env.bundle) }
        await eventually { machine.restoreStarted }
        machine.finishRestore()
        #expect(try await boot.value == .resumed)
        #expect(machine.calls == ["restore", "resume"])
        #expect(machine.state == .running)
    }
}

/// `PendingStop`: what `VMSession` uses to keep a stop asked while it restores a saved state.
@Suite struct PendingStopTests {
    @Test @MainActor func requestWaitsForTheEndOfTheWindow() async throws {
        let gate = PendingStop()
        #expect(!gate.isActive)
        gate.begin()
        var returned = false
        let waiter = Task { @MainActor in
            await gate.requestAndWait()
            returned = true
        }
        for _ in 0..<100 { await Task.yield() }
        #expect(gate.isRequested)
        #expect(!returned)
        gate.end()
        await waiter.value
        #expect(returned)
        #expect(!gate.isActive)
        #expect(gate.isRequested)
    }

    @Test @MainActor func requestOutsideTheWindowReturnsAtOnce() async {
        let gate = PendingStop()
        await gate.requestAndWait()
        #expect(!gate.isRequested)
    }
}

extension SuspendTests {
    /// CORE m1: the cleared hash is made durable (bundle directory synced) before the state is
    /// handed to the framework.
    @Test @MainActor func clearedHashIsSyncedBeforeTheRestore() async throws {
        let env = try Env()
        defer { env.cleanup() }
        try env.suspend(hash: "fake-hash")
        let machine = FakeSuspendableMachine(bundle: env.bundle, state: .stopped)
        let bundle = env.bundle
        let outcome = try await SuspendedState.boot(machine, bundle: env.bundle, syncDirectory: { url in
            #expect(url.standardizedFileURL.path == bundle.url.standardizedFileURL.path)
            let hash = try bundle.readConfig().suspendedConfigHash
            machine.calls.append("sync \(hash ?? "nil")")
        })
        #expect(outcome == .resumed)
        #expect(machine.calls == ["sync nil", "restore", "resume"])
    }

    /// SWIFT m4: a resume that fails after a failed save is reported with the save's error.
    @Test @MainActor func failedResumeAfterAFailedSaveIsReported() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let machine = FakeSuspendableMachine(bundle: env.bundle)
        machine.saveFails = true
        machine.resumeFails = true
        do {
            try await SuspendedState.suspend(machine, bundle: env.bundle)
            Issue.record("attesa un'eccezione")
        } catch NidoError.failedAndNotResumed(let reason, let resumeReason) {
            #expect(reason.contains("disco pieno"))
            #expect(!resumeReason.isEmpty)
        }
        #expect(NidoError.failedAndNotResumed("x", resumeError: "y").localizedDescription
            == "x; inoltre la VM non è ripartita (y): è in pausa")
    }

    /// `nextStartResumes`: an edit after the suspend means the saved state will be discarded.
    @Test func nextStartResumesOnlyWhileTheMachineWouldMatch() throws {
        let env = try Env()
        defer { env.cleanup() }
        var config = try env.bundle.readConfig()
        #expect(!SuspendedState.nextStartResumes(bundle: env.bundle, config: config, rosettaState: .installed))
        try env.suspend(hash: config.stateHash())
        config = try env.bundle.readConfig()
        #expect(SuspendedState.nextStartResumes(bundle: env.bundle, config: config, rosettaState: .installed))
        var edited = config
        edited.cpuCount = 4
        #expect(!SuspendedState.nextStartResumes(bundle: env.bundle, config: edited, rosettaState: .installed))
        edited = config
        edited.rosetta = true
        #expect(!SuspendedState.nextStartResumes(bundle: env.bundle, config: edited, rosettaState: .installed))
        // Rosetta missing on the Mac: not attached, the hash still matches.
        #expect(SuspendedState.nextStartResumes(bundle: env.bundle, config: edited, rosettaState: .notInstalled))
        edited = config
        edited.sharedFolders = [SharedFolder(name: "gone", hostPath: "/nonexistent-nido")]
        // A folder missing on the Mac is left out at start: the hash still matches.
        #expect(SuspendedState.nextStartResumes(bundle: env.bundle, config: edited, rosettaState: .installed))
    }

    // MARK: - macOS guests (M3b)

    /// A macOS guest that cannot save its state (`validateSaveRestoreSupport`): the message, and
    /// nothing paused or written.
    @Test @MainActor func macSuspendUnsupportedLeavesNoState() async throws {
        let env = try Env(guest: .macos)
        defer { env.cleanup() }
        let machine = FakeSuspendableMachine(bundle: env.bundle)
        machine.unsupportedReason = "il guest macOS non lo supporta"
        await #expect(throws: NidoError.suspendFailed(SuspendedState.unsupportedReason("il guest macOS non lo supporta"))) {
            try await SuspendedState.suspend(machine, bundle: env.bundle)
        }
        #expect(machine.calls.isEmpty)
        #expect(!env.stateExists)
        #expect(try env.hash() == nil)
    }

    /// A macOS machine never attaches Rosetta (`MacConfigurationBuilder`): a stray `rosetta` flag
    /// in its config does not make the next start look like a discard.
    @Test func macNextStartResumesIgnoresRosetta() throws {
        let env = try Env(guest: .macos)
        defer { env.cleanup() }
        _ = try env.bundle.updateConfig { $0.rosetta = true }
        let config = try env.bundle.readConfig()
        try env.suspend(hash: config.effectiveStateHash(attachedShareNames: [], rosettaAttached: false))
        #expect(SuspendedState.nextStartResumes(
            bundle: env.bundle, config: try env.bundle.readConfig(), rosettaState: .installed))
    }

}
