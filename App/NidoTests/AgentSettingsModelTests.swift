// SPDX-License-Identifier: Apache-2.0
import Foundation
import NidoAgentKit
import NidoCore
import Synchronization
import Testing

@testable import Nido

@MainActor
struct AgentSettingsModelTests {
    private func makeBundle(guest: GuestOS = .macos, access: Bool? = nil) throws -> (VMBundle, VMConfig, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nido-agent-settings-\(UUID().uuidString)", isDirectory: true)
        var config = VMConfig(
            id: UUID(), name: try VMName("macos-agenti"), guest: guest, cpuCount: 4,
            memoryBytes: UInt64(8) << 30, diskBytes: UInt64(64) << 30, macAddress: "52:54:00:12:34:57")
        config.agentAccess = access
        let bundle = try VMBundle.create(config: config, paths: NidoPaths(root: root))
        return (bundle, config, root)
    }

    private func status(version: String = "1.0.0", recording: Bool = true, accessibility: Bool = true) -> AgentAnswer {
        AgentAnswer(
            ok: true,
            status: AgentStatus(
                helperVersion: version, protocolVersion: 1, screenRecording: recording, accessibility: accessibility,
                screen: ScreenSize(width: 1920, height: 1080)))
    }

    private func model(
        _ bundle: VMBundle, _ config: VMConfig, running: Bool = false,
        setup: @escaping AgentSettingsModel.Setup = { _, _ in true },
        passwords: any GuestPasswordStore = MemoryGuestPasswordStore(),
        authenticator: any OwnerAuthenticator = FakeAuthenticator(answer: true),
        status: @escaping @Sendable () async -> AgentAnswer = { .failure(.notRunning, "") },
        windowSetsUp: @escaping @MainActor () -> Bool = { false },
        copyToVM: @escaping AgentSettingsModel.CopyToVM = { _, _ in .failure(.notRunning, "") },
        onChanged: @escaping @MainActor () -> Void = {}
    ) -> AgentSettingsModel {
        AgentSettingsModel(
            bundle: bundle, config: config, isRunning: { running }, status: status,
            setup: setup, bundledVersion: { "1.0.0" }, passwords: passwords, authenticator: authenticator,
            isWindowSettingUp: windowSetsUp, copyToVM: copyToVM, onConfigurationChanged: onChanged)
    }

    // MARK: - The account password

    @Test func passwordNeededShowsField() async throws {
        let (bundle, config, root) = try makeBundle(access: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = model(bundle, config, running: true, setup: { _, _ in throw MacAgentSetupError.passwordNeeded("macos-agenti") })
        #expect(!model.needsPassword)
        await model.install()
        #expect(model.needsPassword)
        #expect(model.passwordState == .none)
    }

    @Test func rejectedPasswordShowsFieldAndKeepsStored() async throws {
        let (bundle, config, root) = try makeBundle(access: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MemoryGuestPasswordStore()
        try store.save(try #require(GuestPassword("wrong")), vm: config.id)
        let model = model(bundle, config, running: true, setup: { _, _ in
            throw GuestSSHError.passwordRejected(user: "agent", vm: "macos-agenti")
        }, passwords: store)
        await model.install()
        #expect(model.needsPassword)
        #expect(try store.read(vm: config.id)?.value == "wrong")
    }

    /// The typed password goes to the setup, which tries it and keeps it only once it worked:
    /// the pane saves nothing itself.
    @Test func submitPasswordGoesThroughTheSetup() async throws {
        let (bundle, config, root) = try makeBundle(access: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MemoryGuestPasswordStore()
        let received = Mutex<[String?]>([])
        let storedWhileRunning = Mutex<[Bool]>([])
        let model = model(bundle, config, running: true, setup: { typed, _ in
            received.withLock { $0.append(typed?.value) }
            storedWhileRunning.withLock { $0.append((try? store.read(vm: config.id)) != nil) }
            guard let typed else { throw MacAgentSetupError.passwordNeeded("macos-agenti") }
            // What `MacAgentSetup` does once the password worked.
            try store.save(typed, vm: config.id)
            return true
        }, passwords: store)
        await model.install()
        #expect(model.needsPassword)
        await model.submitPassword("hunter2")
        #expect(received.withLock { $0 } == [nil, "hunter2"])
        #expect(storedWhileRunning.withLock { $0 } == [false, false])
        #expect(!model.needsPassword)
        #expect(model.passwordState == .stored)
    }

    /// A typed password the guest refuses is not kept: the stored one stays, the field stays.
    @Test func refusedTypedPasswordIsNotSaved() async throws {
        let (bundle, config, root) = try makeBundle(access: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MemoryGuestPasswordStore()
        try store.save(try #require(GuestPassword("old")), vm: config.id)
        let model = model(bundle, config, running: true, setup: { _, _ in
            throw GuestSSHError.passwordRejected(user: "agent", vm: "macos-agenti")
        }, passwords: store)
        await model.submitPassword("wrong")
        #expect(try store.read(vm: config.id)?.value == "old")
        #expect(model.needsPassword)
        #expect(model.errorMessage != nil)
    }

    @Test func submitInvalidPasswordSavesNothing() async throws {
        let (bundle, config, root) = try makeBundle(access: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MemoryGuestPasswordStore()
        let calls = Mutex(0)
        let model = model(bundle, config, running: true, setup: { _, _ in calls.withLock { $0 += 1 }; return true }, passwords: store)
        await model.submitPassword("")
        #expect(try store.read(vm: config.id) == nil)
        #expect(calls.withLock { $0 } == 0)
        #expect(model.errorMessage != nil)
    }

    @Test func revealNeedsOwner() async throws {
        let (bundle, config, root) = try makeBundle(access: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MemoryGuestPasswordStore()
        try store.save(try #require(GuestPassword("s3cret")), vm: config.id)
        let auth = FakeAuthenticator(answer: false)
        let model = model(bundle, config, passwords: store, authenticator: auth)
        #expect(await model.revealPassword() == nil)
        #expect(model.shownPassword == nil)
        #expect(auth.reasons == [String(localized: "show the password of the account in \(config.name.rawValue)")])
    }

    @Test func revealReturnsStoredAndLeaveClearsIt() async throws {
        let (bundle, config, root) = try makeBundle(access: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MemoryGuestPasswordStore()
        try store.save(try #require(GuestPassword("s3cret")), vm: config.id)
        let model = model(bundle, config, passwords: store)
        #expect(await model.revealPassword() == "s3cret")
        #expect(model.shownPassword == "s3cret")
        model.leave()
        #expect(model.shownPassword == nil)
    }

    /// The stored password is shown also with agent access off (the wizard says Settings › Agent
    /// shows it): the row does not depend on the switch.
    @Test func storedPasswordShownWithAccessOff() async throws {
        let (bundle, config, root) = try makeBundle(access: nil)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MemoryGuestPasswordStore()
        let model = model(bundle, config, passwords: store)
        await model.refresh()
        #expect(!model.showsStoredPassword)

        try store.save(try #require(GuestPassword("s3cret")), vm: config.id)
        let later = self.model(bundle, config, passwords: store)
        await later.refresh()
        #expect(!later.agentAccess)
        #expect(later.showsStoredPassword)
        #expect(await later.revealPassword() == "s3cret")
    }

    /// Opening the pane only asks whether an item exists, never its data (no Keychain prompt).
    @Test func passwordStateReadsNoSecret() async throws {
        let (bundle, config, root) = try makeBundle(access: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CountingStore()
        try store.save(try #require(GuestPassword("s3cret")), vm: config.id)
        let model = model(bundle, config, passwords: store)
        await model.refresh()
        #expect(model.passwordState == .stored)
        #expect(store.reads == 0)
    }

    /// A Keychain error while showing the password is told, not swallowed.
    @Test func revealShowsKeychainError() async throws {
        let (bundle, config, root) = try makeBundle(access: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CountingStore()
        store.failsReads = true
        let model = model(bundle, config, passwords: store)
        #expect(await model.revealPassword() == nil)
        #expect(model.shownPassword == nil)
        #expect(model.errorMessage?.contains("-25293") == true)
    }

    // MARK: - The password to the VM's clipboard

    /// Records what the pane sends to the VM's clipboard and answers `answer`.
    private final class ClipboardRecorder: Sendable {
        private let sent = Mutex<[(text: String, clearAfter: Int)]>([])
        let answer: AgentAnswer
        init(answer: AgentAnswer = AgentAnswer(ok: true)) { self.answer = answer }
        var calls: [(text: String, clearAfter: Int)] { sent.withLock { $0 } }
        var send: AgentSettingsModel.CopyToVM {
            { [self] text, seconds in
                sent.withLock { $0.append((text, seconds)) }
                return answer
            }
        }
    }

    @Test func copyToVMNeedsOwner() async throws {
        let (bundle, config, root) = try makeBundle(access: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MemoryGuestPasswordStore()
        try store.save(try #require(GuestPassword("s3cret")), vm: config.id)
        let auth = FakeAuthenticator(answer: false)
        let clipboard = ClipboardRecorder()
        let model = model(bundle, config, running: true, passwords: store, authenticator: auth, copyToVM: clipboard.send)
        await model.copyPasswordToVM()
        #expect(clipboard.calls.isEmpty)
        #expect(model.copyNotice == nil)
        #expect(auth.reasons == [String(localized: "copy the password of the account in \(config.name.rawValue) to its clipboard")])
    }

    @Test func copyToVMSendsTheStoredPasswordFor60Seconds() async throws {
        let (bundle, config, root) = try makeBundle(access: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MemoryGuestPasswordStore()
        try store.save(try #require(GuestPassword("s3cret")), vm: config.id)
        let clipboard = ClipboardRecorder()
        let model = model(bundle, config, running: true, passwords: store, copyToVM: clipboard.send)
        await model.refresh()
        #expect(model.canCopyPasswordToVM)
        await model.copyPasswordToVM()
        #expect(clipboard.calls.map(\.text) == ["s3cret"])
        #expect(clipboard.calls.map(\.clearAfter) == [60])
        #expect(model.errorMessage == nil)
        #expect(model.copyNotice == String(localized: "In the VM, press ⌘V. The VM’s clipboard is cleared in 60 seconds."))
        // Never shown in the pane on the way.
        #expect(model.shownPassword == nil)
        model.leave()
        #expect(model.copyNotice == nil)
    }

    /// An older Nido Agent does not know the request (`badRequest`): the pane says to update it.
    @Test func copyToVMWithAnOldHelperSaysUpdate() async throws {
        let (bundle, config, root) = try makeBundle(access: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MemoryGuestPasswordStore()
        try store.save(try #require(GuestPassword("s3cret")), vm: config.id)
        let clipboard = ClipboardRecorder(answer: .failure(.badRequest, "could not read the request: unknown op 'setClipboard'"))
        let model = model(bundle, config, running: true, passwords: store, copyToVM: clipboard.send)
        await model.copyPasswordToVM()
        #expect(model.errorMessage == String(localized: "Update Nido Agent to use this."))
        #expect(model.copyNotice == nil)
    }

    /// The VM gone, the helper not answering, a Keychain error: each is told, nothing is sent
    /// without a password.
    @Test func copyToVMFailuresAreTold() async throws {
        let (bundle, config, root) = try makeBundle(access: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MemoryGuestPasswordStore()
        try store.save(try #require(GuestPassword("s3cret")), vm: config.id)
        for code in [AgentErrorCode.notRunning, .notReady, .timeout] {
            let clipboard = ClipboardRecorder(answer: .failure(code, "x"))
            let model = model(bundle, config, running: true, passwords: store, copyToVM: clipboard.send)
            await model.copyPasswordToVM()
            #expect(model.errorMessage?.isEmpty == false)
            #expect(model.errorMessage?.contains("s3cret") == false)
            #expect(model.copyNotice == nil)
        }

        let failing = CountingStore()
        try failing.save(try #require(GuestPassword("s3cret")), vm: config.id)
        failing.failsReads = true
        let clipboard = ClipboardRecorder()
        let model = model(bundle, config, running: true, passwords: failing, copyToVM: clipboard.send)
        await model.copyPasswordToVM()
        #expect(clipboard.calls.isEmpty)
        #expect(model.errorMessage?.contains("-25293") == true)
    }

    /// The button needs the VM running and a stored password.
    @Test func copyToVMNeedsARunningVMAndAPassword() async throws {
        let (bundle, config, root) = try makeBundle(access: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MemoryGuestPasswordStore()
        let none = model(bundle, config, running: true, passwords: store)
        await none.refresh()
        #expect(!none.canCopyPasswordToVM)

        try store.save(try #require(GuestPassword("s3cret")), vm: config.id)
        let stopped = model(bundle, config, running: false, passwords: store)
        await stopped.refresh()
        #expect(!stopped.canCopyPasswordToVM)
        let running = model(bundle, config, running: true, passwords: store)
        await running.refresh()
        #expect(running.canCopyPasswordToVM)
    }

    /// While the VM's window sets Nido Agent up after a provisioned start, the pane does not start
    /// a second setup.
    @Test func installWaitsForTheWindowSetup() async throws {
        let (bundle, config, root) = try makeBundle(access: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let busy = Mutex(true)
        let calls = Mutex(0)
        let model = model(
            bundle, config, running: true, setup: { _, _ in calls.withLock { $0 += 1 }; return true },
            status: { .failure(.notReady, "") }, windowSetsUp: { busy.withLock { $0 } })
        await model.refresh()
        #expect(model.helperState == .notAnswering)
        #expect(!model.canInstall)
        #expect(!model.canSubmitPassword)
        #expect(model.windowSetupNote != nil)
        await model.install()
        await model.submitPassword("hunter2")
        #expect(calls.withLock { $0 } == 0)
        busy.withLock { $0 = false }
        #expect(model.canInstall)
        #expect(model.windowSetupNote == nil)
    }

    @Test func toggleWritesConfig() async throws {
        let (bundle, config, root) = try makeBundle()
        defer { try? FileManager.default.removeItem(at: root) }
        let changed = Mutex(0)
        let model = model(bundle, config, onChanged: { changed.withLock { $0 += 1 } })
        #expect(!model.agentAccess && model.helperState == .off)
        await model.setAgentAccess(true)
        #expect(model.agentAccess)
        #expect(try bundle.readConfig().agentAccess == true)
        #expect(changed.withLock { $0 } == 1)
        await model.setAgentAccess(false)
        #expect(try bundle.readConfig().agentAccess == false)
        #expect(model.helperState == .off)
    }

    @Test func turningOnWhileRunningSaysNextStart() async throws {
        let (bundle, config, root) = try makeBundle()
        defer { try? FileManager.default.removeItem(at: root) }
        let running = model(bundle, config, running: true)
        await running.setAgentAccess(true)
        #expect(running.restartNote == String(localized: "Takes effect at the next start."))
        let stopped = model(bundle, config)
        await stopped.setAgentAccess(true)
        #expect(stopped.restartNote == nil)
    }

    @Test func helperStatesMapFromAnswers() {
        func state(_ answer: AgentAnswer, _ bundled: String? = "1.0.0") -> AgentSettingsModel.HelperState? {
            AgentSettingsModel.state(for: answer, bundledVersion: bundled)
        }
        #expect(state(.failure(.notRunning, "")) == .notRunning)
        #expect(state(.failure(.notReady, "")) == .notAnswering)
        #expect(state(.failure(.permissionMissing, "")) == .waitingForPermissions)
        #expect(state(.failure(.timeout, "")) == nil)
        #expect(state(.failure(.versionMismatch, "")) == .outdated(""))
        #expect(state(.failure(.agentAccessOff, "")) == .off)
        #expect(state(status(recording: false)) == .waitingForPermissions)
        #expect(state(status(accessibility: false)) == .waitingForPermissions)
        #expect(state(status(version: "0.9.0")) == .outdated("0.9.0"))
        #expect(state(status()) == .ready("1.0.0"))
        #expect(state(status(version: "2.0.0")) == .ready("2.0.0"))
        #expect(state(status(), nil) == .ready("1.0.0"))
    }

    @Test func refreshReadsStatusOnlyWhileRunning() async throws {
        let (bundle, config, root) = try makeBundle(access: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let answer = status()
        let model = AgentSettingsModel(
            bundle: bundle, config: config, isRunning: { true }, status: { answer },
            setup: { _, _ in true }, bundledVersion: { "1.0.0" })
        await model.refresh()
        #expect(model.helperState == .ready("1.0.0"))
        let stopped = self.model(bundle, config)
        await stopped.refresh()
        #expect(stopped.helperState == .notRunning)
    }

    @Test func installShowsEventsAndEnds() async throws {
        let (bundle, config, root) = try makeBundle(access: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = model(bundle, config, running: true, setup: { _, emit in
            emit(.installed(version: "1.0.0"))
            emit(.grantPermissions)
            emit(.ready)
            return true
        })
        await model.install()
        #expect(!model.isInstalling)
        #expect(model.log == [
            MacAgentSetupEvent.installed(version: "1.0.0").line(vm: "macos-agenti"),
            MacAgentSetupEvent.grantPermissions.line(vm: "macos-agenti"),
            MacAgentSetupEvent.ready.line(vm: "macos-agenti"),
        ])
        #expect(model.errorMessage == nil)
    }

    @Test func installEventsDriveStateAndAdvice() async throws {
        let (bundle, config, root) = try makeBundle(access: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let states = Mutex<[AgentSettingsModel.HelperState]>([])
        let holder = Mutex<AgentSettingsModel?>(nil)
        let gate = AsyncStream.makeStream(of: Void.self)
        let model = model(bundle, config, running: true, setup: { _, emit in
            emit(.fileVaultAdvice("FileVault is on"))
            emit(.logIn)
            for await _ in gate.stream { break }
            emit(.grantPermissions)
            return true
        })
        holder.withLock { $0 = model }
        let run = Task { await model.install() }
        for _ in 0..<1000 where model.helperState != .waitingForLogin { try await Task.sleep(for: .milliseconds(5)) }
        states.withLock { $0.append(model.helperState) }
        #expect(model.fileVaultAdvice == "FileVault is on")
        gate.continuation.yield()
        await run.value
        #expect(states.withLock { $0 } == [.waitingForLogin])
        #expect(model.log.contains(MacAgentSetupEvent.grantPermissions.line(vm: "macos-agenti")))
    }

    @Test func refreshIgnoresAnswerAfterAccessTurnedOff() async throws {
        let (bundle, config, root) = try makeBundle(access: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let box = Mutex<AgentSettingsModel?>(nil)
        let answer = status()
        let model = AgentSettingsModel(
            bundle: bundle, config: config, isRunning: { true },
            status: { await Task.yield(); return answer }, setup: { _, _ in true }, bundledVersion: { "1.0.0" })
        box.withLock { $0 = model }
        async let refreshing: Void = model.refresh()
        await model.setAgentAccess(false)
        await refreshing
        #expect(model.helperState == .off)
    }

    /// A helper that does not answer may be installed and waiting for a login: the line says both.
    @Test func notAnsweringSaysLoginOrInstall() async throws {
        let (bundle, config, root) = try makeBundle(access: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AgentSettingsModel(
            bundle: bundle, config: config, isRunning: { true }, status: { .failure(.notReady, "") },
            setup: { _, _ in true }, bundledVersion: { "1.0.0" })
        await model.refresh()
        #expect(model.helperState == .notAnswering)
        #expect(model.helperLine == String(localized: "Nido Agent doesn’t answer: log in to the VM in its window, or install it."))
        #expect(model.helperNeedsInstall)
    }

    /// `nido agent enable` and `disable` write `config.json` while the pane is open: `refresh`
    /// reads it again.
    @Test func refreshFollowsTheCLI() async throws {
        let (bundle, config, root) = try makeBundle()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = model(bundle, config)
        #expect(!model.agentAccess && model.helperState == .off)
        _ = try bundle.updateConfig { $0.agentAccess = true }
        await model.refresh()
        #expect(model.agentAccess)
        #expect(model.helperState == .notRunning)
        _ = try bundle.updateConfig { $0.agentAccess = false }
        await model.refresh()
        #expect(!model.agentAccess)
        #expect(model.helperState == .off)
    }

    /// "Takes effect at the next start." only while the running VM has no agent socket (`status`
    /// answers `notRunning`), gone once the socket answers.
    @Test func restartNoteFollowsTheSocket() async throws {
        let (bundle, config, root) = try makeBundle(access: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let answer = Mutex(status())
        let model = AgentSettingsModel(
            bundle: bundle, config: config, isRunning: { true }, status: { answer.withLock { $0 } },
            setup: { _, _ in true }, bundledVersion: { "1.0.0" })
        // Started with agent access on: off and on again while it runs, the socket still serves.
        await model.setAgentAccess(false)
        await model.setAgentAccess(true)
        #expect(model.restartNote == nil)
        #expect(model.helperState == .ready("1.0.0"))
        // Started without it: no socket.
        answer.withLock { $0 = .failure(.notRunning, "agent access was turned on after macos-agenti started: restart it") }
        await model.refresh()
        #expect(model.restartNote == String(localized: "Takes effect at the next start."))
        #expect(model.helperLine == String(localized: "Restart the VM to set up Nido Agent."))
        // A timeout says nothing either way.
        answer.withLock { $0 = .failure(.timeout, "") }
        await model.refresh()
        #expect(model.restartNote != nil)
        answer.withLock { $0 = .failure(.notReady, "") }
        await model.refresh()
        #expect(model.restartNote == nil)
        #expect(model.helperState == .notAnswering)
        #expect(AgentSettingsModel.needsRestart(after: .failure(.notRunning, ""), running: false) == nil)
    }

    /// The app's Install says what to click, not what to run.
    @Test func setupErrorsUseTheAppWords() async throws {
        let (bundle, config, root) = try makeBundle(access: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for error: MacAgentSetupError in [.accessOff("macos-agenti"), .loginWindow("macos-agenti")] {
            let failing = model(bundle, config, running: true, setup: { _, _ in throw error })
            await failing.install()
            #expect(failing.errorMessage == error.message(on: .app))
            #expect(failing.errorMessage != error.errorDescription)
            #expect(failing.errorMessage?.contains("nido agent") == false)
        }
    }

    /// The log reads in order: the events, then "Cancelled."; the FileVault advice only in its
    /// notice; the not-ready message points down to the log.
    @Test func logOrderAndAdvice() async throws {
        let (bundle, config, root) = try makeBundle(access: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cancelled = model(bundle, config, running: true, setup: { _, emit in
            emit(.fileVaultAdvice("FileVault is on"))
            emit(.installed(version: "1.0.0"))
            emit(.grantPermissions)
            throw CancellationError()
        })
        await cancelled.install()
        #expect(cancelled.log == [
            MacAgentSetupEvent.installed(version: "1.0.0").line(vm: "macos-agenti"),
            MacAgentSetupEvent.grantPermissions.line(vm: "macos-agenti"),
            String(localized: "Cancelled."),
        ])
        #expect(cancelled.fileVaultAdvice == "FileVault is on")
        #expect(cancelled.errorMessage == nil)
        let notReady = model(bundle, config, running: true, setup: { _, _ in false })
        await notReady.install()
        #expect(notReady.errorMessage == String(localized: "Nido Agent isn’t ready. See the messages below."))
    }

    @Test func installErrorIsShown() async throws {
        let (bundle, config, root) = try makeBundle(access: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let failing = model(bundle, config, running: true, setup: { _, _ in throw MacAgentSetupError.remoteLoginOff })
        await failing.install()
        #expect(failing.errorMessage == MacAgentSetupError.remoteLoginOff.errorDescription)
        #expect(!failing.isInstalling)
        let notReady = model(bundle, config, running: true, setup: { _, emit in
            emit(.error("timed out"))
            return false
        })
        await notReady.install()
        #expect(notReady.errorMessage != nil)
        #expect(notReady.log == ["timed out"])
    }

    @Test func cancelStopsInstall() async throws {
        let (bundle, config, root) = try makeBundle(access: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let failures: [@Sendable () -> any Error] = [{ CancellationError() }, { GuestSSHError.cancelled }]
        for failure in failures {
            let model = model(bundle, config, running: true, setup: { _, _ in
                for _ in 0..<500 where !Task.isCancelled { try? await Task.sleep(for: .milliseconds(10)) }
                throw failure()
            })
            let run = Task { await model.install() }
            for _ in 0..<1000 where !model.isInstalling { await Task.yield() }
            #expect(model.isInstalling)
            model.cancelInstall()
            await run.value
            #expect(!model.isInstalling)
            #expect(model.errorMessage == nil)
        }
    }

    @Test func mcpCommandUsesVMName() throws {
        let (bundle, config, root) = try makeBundle()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(model(bundle, config).mcpCommand == "claude mcp add nido-macos-agenti -- nido mcp macos-agenti")
    }

    /// A template never runs; as Sharing, its agent access changes after Edit Template.
    @Test func paneHiddenForTemplate() throws {
        let (bundle, config, root) = try makeBundle()
        defer { try? FileManager.default.removeItem(at: root) }
        var template = config
        template.isTemplate = true
        try bundle.writeConfig(template)
        let model = try VMSettingsModel(bundle: bundle, rosettaState: { .installed })
        #expect(!model.sectionNames.contains("Agent"))
        #expect(!model.showsAgent)
        try bundle.writeConfig(config)
        #expect(try VMSettingsModel(bundle: bundle, rosettaState: { .installed }).showsAgent)
    }

    @Test func paneHiddenForLinux() throws {
        let (bundle, _, root) = try makeBundle(guest: .linux)
        defer { try? FileManager.default.removeItem(at: root) }
        let linux = try VMSettingsModel(bundle: bundle, rosettaState: { .installed })
        #expect(!linux.sectionNames.contains("Agent"))
        #expect(!linux.showsAgent)
    }
}


/// Counts the reads of the password's data; `failsReads` makes them fail as the Keychain would.
private final class CountingStore: GuestPasswordStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [UUID: GuestPassword] = [:]
    private var readCount = 0
    var failsReads = false
    var reads: Int { lock.withLock { readCount } }

    func read(vm: UUID) throws -> GuestPassword? {
        try lock.withLock {
            readCount += 1
            if failsReads { throw GuestPasswordStoreError.keychain(-25293) }
            return items[vm]
        }
    }
    func contains(vm: UUID) throws -> Bool { lock.withLock { items[vm] != nil } }
    func save(_ password: GuestPassword, vm: UUID) throws { lock.withLock { items[vm] = password } }
    func delete(vm: UUID) throws { lock.withLock { items[vm] = nil } }
}
