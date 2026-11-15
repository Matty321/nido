// SPDX-License-Identifier: Apache-2.0
import Foundation
import NidoAgentKit
import Synchronization
import Testing
@testable import NidoCore

@Suite(.italian) struct MacAgentSetupTests {
    private let notReady = AgentAnswer.failure(.notReady, "waiting for login or Nido Agent")
    private let unserved = AgentAnswer.failure(.notRunning, "restart it")

    private func helper(version: String = "1.0.0", granted: Bool = false) -> AgentAnswer {
        AgentAnswer(ok: true, status: AgentStatus(
            helperVersion: version, protocolVersion: 1, screenRecording: granted, accessibility: granted,
            screen: ScreenSize(width: 1, height: 1)))
    }

    // MARK: - Gate

    @Test func gateMatrix() {
        let absent = AgentAnswer.failure(.timeout, "slow")
        let noAddress = MacAgentSetup.SSHReach.noAddress(.notOnNetwork("vm"))
        #expect(MacAgentSetup.gate(helper: notReady, ssh: .refused) == .remoteLoginOff)
        #expect(MacAgentSetup.gate(helper: helper(), ssh: .refused) == .remoteLoginOff)
        #expect(MacAgentSetup.gate(helper: notReady, ssh: .noAnswer) == .loginWindow)
        #expect(MacAgentSetup.gate(helper: notReady, ssh: noAddress) == .loginWindow)
        #expect(MacAgentSetup.gate(helper: notReady, ssh: .open) == .proceed)
        for h in [helper(), absent] {
            for ssh: MacAgentSetup.SSHReach in [.open, .noAnswer, noAddress] {
                #expect(MacAgentSetup.gate(helper: h, ssh: ssh) == .proceed)
            }
        }
        for ssh: MacAgentSetup.SSHReach in [.open, .refused, .noAnswer, noAddress] {
            #expect(MacAgentSetup.gate(helper: unserved, ssh: ssh) == .notServed("restart it"))
        }
    }

    @Test func loginHint() {
        #expect(MacAgentSetup.loginHint(for: GuestSSHError.keyUnavailable("k"), helper: notReady, vm: "vm") == .loginWindow("vm"))
        #expect(MacAgentSetup.loginHint(for: GuestSSHError.keyUnavailable("k"), helper: helper(), vm: "vm") == nil)
        #expect(MacAgentSetup.loginHint(for: GuestSSHError.timeout, helper: notReady, vm: "vm") == nil)
    }

    // MARK: - Words

    /// The lines of `nido agent setup` do not change.
    @Test func eventLines() {
        #expect(MacAgentSetupEvent.installed(version: "1.0.0").line(vm: "m1") == L10n.string("Nido Agent \("1.0.0") installed in \("m1")."))
        #expect(MacAgentSetupEvent.alreadyCurrent(version: "1").line(vm: "m1") == L10n.string("Nido Agent is already installed in \("m1")."))
        #expect(MacAgentSetupEvent.keptNewer(version: "2").line(vm: "m1")
            == L10n.string("The Nido Agent in \("m1") is newer than the one in this Nido: keeping it."))
        #expect(MacAgentSetupEvent.logIn.line(vm: "m1") == L10n.string("Log in to \("m1") in its window."))
        #expect(MacAgentSetupEvent.ready.line(vm: "m1") == L10n.string("Nido Agent is ready in \("m1")."))
        #expect(MacAgentSetupEvent.error("x").line(vm: "m1") == "x")
        #expect(MacAgentSetupError.loginWindow("vm").errorDescription
            == "vm potrebbe essere ferma alla finestra di login (FileVault): accedi dalla sua finestra, poi esegui di nuovo nido agent setup.")
        #expect(MacAgentSetupError.guestLoginNeeded("vm").errorDescription == L10n.string("Log in to \("vm") in its window."))
    }

    /// The app's Agent pane names its own controls, not commands; the CLI keeps its words.
    @Test func appWords() {
        for error: MacAgentSetupError in [.notForLinux, .notServed("x"), .loginWindow("vm"), .remoteLoginOff,
                                          .guestLoginNeeded("vm"), .accessOff("vm")] {
            #expect(error.message(on: .cli) == error.errorDescription)
        }
        #expect(MacAgentSetupError.notForLinux.errorDescription == L10n.string("Agent access is for macOS VMs."))
        #expect(MacAgentSetupError.loginWindow("vm").message(on: .app)
            == L10n.string("\("vm") may be waiting at its login window (FileVault): log in through its window, then click Install Nido Agent again."))
        #expect(MacAgentSetupError.accessOff("vm").message(on: .app)
            == L10n.string("Agent access is off for \("vm"): turn on Agent access above."))
        #expect(MacAgentInstaller.WaitEvent.timedOut.line(vm: "vm", on: .app)
            == L10n.string("Timed out waiting for Nido Agent in \("vm"): grant the permissions, then click Install Nido Agent again."))
        for surface: MacAgentSetup.Surface in [.cli, .app] {
            #expect(!MacAgentSetupError.loginWindow("vm").message(on: surface).contains("nido agent") == (surface == .app))
            #expect(!MacAgentSetupError.accessOff("vm").message(on: surface).contains("nido agent") == (surface == .app))
            #expect(!MacAgentInstaller.WaitEvent.timedOut.line(vm: "vm", on: surface).contains("nido agent") == (surface == .app))
        }
        #expect(MacAgentInstaller.WaitEvent.ready.line(vm: "vm", on: .app) == MacAgentInstaller.WaitEvent.ready.line(vm: "vm"))
    }

    // MARK: - live

    /// `live` checks the guest, agent access and the running VM before it looks for the app.
    @Test func liveChecksFirst() throws {
        let fx = try GuestFixture(); defer { fx.cleanup() }
        let located = Mutex(0)
        let locate: () throws -> URL = { located.withLock { $0 += 1 }; return fx.root }
        var config = try fx.bundle.readConfig()
        #expect(throws: MacAgentSetupError.notForLinux) {
            _ = try MacAgentSetup.live(bundle: fx.bundle, config: config, surface: .app, locateApp: locate)
        }
        config.guest = .macos
        #expect(throws: MacAgentSetupError.accessOff("gs")) {
            _ = try MacAgentSetup.live(bundle: fx.bundle, config: config, surface: .app, locateApp: locate)
        }
        config.agentAccess = true
        #expect(throws: NidoError.notRunning("gs")) {
            _ = try MacAgentSetup.live(bundle: fx.bundle, config: config, surface: .cli, locateApp: locate)
        }
        #expect(located.withLock { $0 } == 0)
        let lock = try BundleLock.acquire(fx.bundle, owner: .cli)
        defer { lock.release() }
        _ = try MacAgentSetup.live(bundle: fx.bundle, config: config, surface: .cli, locateApp: locate)
        #expect(located.withLock { $0 } == 1)
    }

    // MARK: - The flow

    /// A client whose `status` answers come from a script (the last one repeats) and are counted.
    private final class Status: AgentActions, @unchecked Sendable {
        private let state = Mutex<(queue: [AgentAnswer], last: AgentAnswer, count: Int)>(([], .failure(.notReady, "x"), 0))
        init(_ answers: [AgentAnswer]) {
            state.withLock { $0.queue = answers; $0.last = answers.last ?? .failure(.notReady, "x") }
        }
        var count: Int { state.withLock { $0.count } }
        func send(_ action: AgentAction) throws -> AgentAnswer {
            state.withLock {
                $0.count += 1
                return $0.queue.isEmpty ? $0.last : $0.queue.removeFirst()
            }
        }
    }

    private struct Rig {
        let fx: GuestFixture
        let app: URL
        let runner: ScriptedRunner
        func cleanup() { fx.cleanup() }
    }

    /// `login` is what the guest's login-state script prints; `open` the status of `open`;
    /// `key` makes every command fail as a refused key.
    /// `refusals` makes the first n commands fail as a refused key, then they work.
    private func rig(
        login: String = "filevault=off\nautologin=\n", open: Int32 = 0, key: Bool = false, refusals: Int = 0
    ) throws -> Rig {
        let remaining = Mutex(refusals)
        let fx = try GuestFixture()
        let app = fx.root.appendingPathComponent("NidoAgent.app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let plist = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleShortVersionString": "1.0.0"], format: .xml, options: 0)
        try plist.write(to: app.appendingPathComponent("Contents/Info.plist"))
        let runner = ScriptedRunner { call in
            let command = call.arguments.last ?? ""
            if remaining.withLock({ n in n > 0 ? { n -= 1; return true }() : false }) {
                return result(255, err: "Permission denied (publickey,password,keyboard-interactive).")
            }
            if key { return result(255, err: "Permission denied (publickey,password,keyboard-interactive).") }
            if command.contains("open -g") { return result(open, err: open == 0 ? "" : "no session") }
            return result(0, out: login)
        }
        return Rig(fx: fx, app: app, runner: runner)
    }

    private func setup(
        _ rig: Rig, client: Status, reach: MacAgentSetup.SSHReach = .open, timeout: Duration = .seconds(600),
        now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        surface: MacAgentSetup.Surface = .cli,
        reachFn: (@Sendable () throws -> MacAgentSetup.SSHReach)? = nil,
        passwords: any GuestPasswordStore = MemoryGuestPasswordStore(),
        askpass: URL? = URL(fileURLWithPath: "/usr/bin/true"),
        askPassword: (@Sendable () async -> GuestPassword?)? = nil,
        typedPassword: GuestPassword? = nil,
        waitForRemoteLogin: Duration? = nil,
        authorize: (@Sendable (GuestPassword, URL) async throws -> Void)? = nil
    ) throws -> MacAgentSetup {
        MacAgentSetup(
            bundle: rig.fx.bundle, config: try rig.fx.bundle.readConfig(), ssh: try rig.fx.ssh(rig.runner),
            client: client, bundledApp: rig.app, reach: reachFn ?? { reach }, timeout: timeout, now: now,
            sleep: sleep, surface: surface, passwords: passwords, vmID: try rig.fx.bundle.readConfig().id,
            askpass: askpass, askPassword: askPassword, typedPassword: typedPassword,
            waitForRemoteLogin: waitForRemoteLogin, authorize: authorize)
    }

    private func pw(_ text: String = "abcde-fghjk-mnpqr-stuvw") throws -> GuestPassword {
        try #require(GuestPassword(text))
    }

    private static let rejected = GuestSSHError.passwordRejected(user: "nido", vm: "gs")

    private final class Events: @unchecked Sendable {
        private let list = Mutex<[MacAgentSetupEvent]>([])
        func add(_ event: MacAgentSetupEvent) { list.withLock { $0.append(event) } }
        var all: [MacAgentSetupEvent] { list.withLock { $0 } }
    }

    @Test func readyAfterPermissions() async throws {
        let r = try rig(login: "filevault=on\nautologin=\n"); defer { r.cleanup() }
        let client = Status([helper(), helper(), helper(granted: true)])
        let events = Events()
        let ready = try await setup(r, client: client, sleep: { _ in }).run { events.add($0) }
        #expect(ready)
        #expect(events.all == [
            .fileVaultAdvice(try #require(MacLoginState(fileVaultOn: true).advice)),
            .alreadyCurrent(version: "1.0.0"), .grantPermissions, .ready,
        ])
    }

    @Test func newerHelperIsKept() async throws {
        let r = try rig(); defer { r.cleanup() }
        let client = Status([helper(version: "2.0.0"), helper(version: "2.0.0", granted: true)])
        let events = Events()
        _ = try await setup(r, client: client, sleep: { _ in }).run { events.add($0) }
        #expect(events.all == [.keptNewer(version: "2.0.0"), .ready])
    }

    /// FileVault on, nobody logged in: sshd up, key refused, helper not ready.
    @Test func keyRefusedBeforeLoginIsALogin() async throws {
        let r = try rig(key: true); defer { r.cleanup() }
        await #expect(throws: MacAgentSetupError.loginWindow("gs")) {
            _ = try await setup(r, client: Status([notReady])).run { _ in }
        }
    }

    @Test func gateErrorsAreThrown() async throws {
        let r = try rig(); defer { r.cleanup() }
        await #expect(throws: MacAgentSetupError.remoteLoginOff) {
            _ = try await setup(r, client: Status([notReady]), reach: .refused).run { _ in }
        }
        await #expect(throws: MacAgentSetupError.loginWindow("gs")) {
            _ = try await setup(r, client: Status([notReady]), reach: .noAnswer).run { _ in }
        }
        await #expect(throws: MacAgentSetupError.notServed("restart it")) {
            _ = try await setup(r, client: Status([unserved])).run { _ in }
        }
        await #expect(throws: NidoError.notOnNetwork("vm")) {
            _ = try await setup(r, client: Status([helper()]), reach: .noAddress(.notOnNetwork("vm"))).run { _ in }
        }
        #expect(r.runner.calls.isEmpty)
    }

    @Test func openRefusedMeansLogin() async throws {
        let r = try rig(open: 1); defer { r.cleanup() }
        await #expect(throws: MacAgentSetupError.guestLoginNeeded("gs")) {
            _ = try await setup(r, client: Status([helper()])).run { _ in }
        }
    }

    /// The VM stopping or agent access going off while waiting end it with their own errors.
    @Test func waitEndsAreErrors() async throws {
        let r = try rig(); defer { r.cleanup() }
        await #expect(throws: NidoError.notRunning("gs")) {
            _ = try await setup(r, client: Status([helper(), unserved]), sleep: { _ in }).run { _ in }
        }
        await #expect(throws: MacAgentSetupError.accessOff("gs")) {
            _ = try await setup(r, client: Status([helper(), .failure(.agentAccessOff, "off")]), sleep: { _ in }).run { _ in }
        }
    }

    /// The 10 minute limit, on a fake clock: false, and the timeout is reported.
    @Test func timesOutWithoutThePermissions() async throws {
        let r = try rig(); defer { r.cleanup() }
        let clock = Mutex(ContinuousClock.now)
        let events = Events()
        let ready = try await setup(
            r, client: Status([helper()]), now: { clock.withLock { $0 } },
            sleep: { d in clock.withLock { $0 = $0.advanced(by: d) } }
        ).run { events.add($0) }
        #expect(!ready)
        #expect(events.all.last == .error(MacAgentInstaller.WaitEvent.timedOut.line(vm: "gs")))
        #expect(events.all.filter { $0 == .grantPermissions }.count == 1)
    }

    /// In the app the timeout names the pane's button.
    @Test func appTimeoutNamesTheButton() async throws {
        let r = try rig(); defer { r.cleanup() }
        let clock = Mutex(ContinuousClock.now)
        let events = Events()
        let ready = try await setup(
            r, client: Status([helper()]), now: { clock.withLock { $0 } },
            sleep: { d in clock.withLock { $0 = $0.advanced(by: d) } }, surface: .app
        ).run { events.add($0) }
        #expect(!ready)
        #expect(events.all.last == .error(MacAgentInstaller.WaitEvent.timedOut.line(vm: "gs", on: .app)))
    }

    /// Cancelling the calling task ends the wait at once, with the real sleep (2 s per poll): no
    /// spinning on a sleep that returns early, and no 10 minute wait.
    @Test func cancellationEndsTheWait() async throws {
        let r = try rig(); defer { r.cleanup() }
        let client = Status([helper()])
        let mac = try setup(r, client: client)
        let task = Task { try await mac.run { _ in } }
        while client.count < 2 { try await Task.sleep(for: .milliseconds(5)) }
        let start = ContinuousClock.now
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(start.duration(to: .now) < .seconds(1))
        let polls = client.count
        try await Task.sleep(for: .milliseconds(100))
        #expect(client.count == polls)
    }

    // MARK: - Key authorization and first boot

    @Test func storedPasswordAuthorizesThenRetries() async throws {
        let r = try rig(refusals: 1); defer { r.cleanup() }
        let store = MemoryGuestPasswordStore()
        let p = try pw()
        try store.save(p, vm: try r.fx.bundle.readConfig().id)
        let used = Mutex<[GuestPassword]>([])
        let events = Events()
        let ready = try await setup(
            r, client: Status([helper(), helper(granted: true)]), sleep: { _ in }, passwords: store,
            authorize: { password, _ in used.withLock { $0.append(password) } }
        ).run { events.add($0) }
        #expect(ready)
        #expect(used.withLock { $0 } == [p])
        #expect(events.all.contains(.keyAuthorized))
        #expect(MacAgentSetupEvent.keyAuthorized.line(vm: "gs") == L10n.string("Nido’s key is now authorized in \("gs")."))
    }

    @Test func askedPasswordIsSavedOnlyAfterSuccess() async throws {
        let p = try pw()
        let r = try rig(refusals: 1); defer { r.cleanup() }
        let id = try r.fx.bundle.readConfig().id
        let store = MemoryGuestPasswordStore()
        _ = try await setup(
            r, client: Status([helper(), helper(granted: true)]), sleep: { _ in }, passwords: store,
            askPassword: { p }, authorize: { _, _ in }
        ).run { _ in }
        #expect(try store.read(vm: id) == p)

        let r2 = try rig(refusals: 1); defer { r2.cleanup() }
        let store2 = MemoryGuestPasswordStore()
        await #expect(throws: GuestSSHError.passwordRejected(user: "nido", vm: "gs")) {
            _ = try await setup(
                r2, client: Status([helper()]), sleep: { _ in }, passwords: store2,
                askPassword: { p }, authorize: { _, _ in throw Self.rejected }
            ).run { _ in }
        }
        #expect(try store2.read(vm: try r2.fx.bundle.readConfig().id) == nil)
    }

    @Test func noPasswordIsPasswordNeeded() async throws {
        let r = try rig(refusals: 1); defer { r.cleanup() }
        await #expect(throws: MacAgentSetupError.passwordNeeded("gs")) {
            _ = try await setup(r, client: Status([helper()])).run { _ in }
        }
        // The FileVault hint still wins when the helper is not ready.
        let r2 = try rig(refusals: 1); defer { r2.cleanup() }
        await #expect(throws: MacAgentSetupError.loginWindow("gs")) {
            _ = try await setup(r2, client: Status([notReady])).run { _ in }
        }
    }

    @Test func rejectedStoredPasswordIsKept() async throws {
        let r = try rig(refusals: 1); defer { r.cleanup() }
        let store = MemoryGuestPasswordStore()
        let p = try pw()
        let id = try r.fx.bundle.readConfig().id
        try store.save(p, vm: id)
        await #expect(throws: GuestSSHError.passwordRejected(user: "nido", vm: "gs")) {
            _ = try await setup(
                r, client: Status([helper()]), passwords: store,
                authorize: { _, _ in throw Self.rejected }
            ).run { _ in }
        }
        #expect(try store.read(vm: id) == p)
    }

    /// A password typed in Settings › Agent is tried before the stored one and replaces it only
    /// once it worked.
    @Test func typedPasswordIsTriedFirstAndSavedOnlyOnSuccess() async throws {
        let old = try pw("old-pass"), new = try pw("new-pass")
        let r = try rig(refusals: 1); defer { r.cleanup() }
        let id = try r.fx.bundle.readConfig().id
        let store = MemoryGuestPasswordStore()
        try store.save(old, vm: id)
        let used = Mutex<[GuestPassword]>([])
        let ready = try await setup(
            r, client: Status([helper(), helper(granted: true)]), sleep: { _ in }, passwords: store,
            typedPassword: new, authorize: { password, _ in used.withLock { $0.append(password) } }
        ).run { _ in }
        #expect(ready)
        #expect(used.withLock { $0 } == [new])
        #expect(try store.read(vm: id) == new)

        let r2 = try rig(refusals: 1); defer { r2.cleanup() }
        let id2 = try r2.fx.bundle.readConfig().id
        let store2 = MemoryGuestPasswordStore()
        try store2.save(old, vm: id2)
        let asked = Mutex(0)
        await #expect(throws: GuestSSHError.passwordRejected(user: "nido", vm: "gs")) {
            _ = try await setup(
                r2, client: Status([helper()]), sleep: { _ in }, passwords: store2,
                askPassword: { asked.withLock { $0 += 1 }; return new }, typedPassword: new,
                authorize: { _, _ in throw Self.rejected }
            ).run { _ in }
        }
        #expect(try store2.read(vm: id2) == old)
        #expect(asked.withLock { $0 } == 0)
    }

    /// A stored password the guest refuses: the user is asked once, and the new one is saved only
    /// once it worked.
    @Test func rejectedStoredPasswordAsksOnce() async throws {
        let old = try pw("old-pass"), new = try pw("new-pass")
        let r = try rig(refusals: 1); defer { r.cleanup() }
        let id = try r.fx.bundle.readConfig().id
        let store = MemoryGuestPasswordStore()
        try store.save(old, vm: id)
        let asked = Mutex(0)
        let used = Mutex<[GuestPassword]>([])
        let events = Events()
        let ready = try await setup(
            r, client: Status([helper(), helper(granted: true)]), sleep: { _ in }, passwords: store,
            askPassword: { asked.withLock { $0 += 1 }; return new },
            authorize: { password, _ in
                used.withLock { $0.append(password) }
                if password == old { throw Self.rejected }
            }
        ).run { events.add($0) }
        #expect(ready)
        #expect(asked.withLock { $0 } == 1)
        #expect(used.withLock { $0 } == [old, new])
        #expect(try store.read(vm: id) == new)
        #expect(events.all.contains(.keyAuthorized))

        // Refused again: the stored one stays, and nobody is asked a second time.
        let r2 = try rig(refusals: 1); defer { r2.cleanup() }
        let id2 = try r2.fx.bundle.readConfig().id
        let store2 = MemoryGuestPasswordStore()
        try store2.save(old, vm: id2)
        let asked2 = Mutex(0)
        await #expect(throws: GuestSSHError.passwordRejected(user: "nido", vm: "gs")) {
            _ = try await setup(
                r2, client: Status([helper()]), sleep: { _ in }, passwords: store2,
                askPassword: { asked2.withLock { $0 += 1 }; return new },
                authorize: { _, _ in throw Self.rejected }
            ).run { _ in }
        }
        #expect(asked2.withLock { $0 } == 1)
        #expect(try store2.read(vm: id2) == old)
    }

    /// Once a command with Nido's key worked, the Terminal Access panel stops opening by itself
    /// (`VMConfig.sshSucceeded`), as after `nido ssh`.
    @Test func keyLoginIsRecorded() async throws {
        let r = try rig(); defer { r.cleanup() }
        #expect(try r.fx.bundle.readConfig().sshSucceeded != true)
        _ = try await setup(r, client: Status([helper(granted: true)]), sleep: { _ in }).run { _ in }
        #expect(try r.fx.bundle.readConfig().sshSucceeded == true)

        // Never when no command reached the guest.
        let r2 = try rig(); defer { r2.cleanup() }
        await #expect(throws: MacAgentSetupError.remoteLoginOff) {
            _ = try await setup(r2, client: Status([notReady]), reach: .refused).run { _ in }
        }
        let r3 = try rig(key: true); defer { r3.cleanup() }
        await #expect(throws: MacAgentSetupError.loginWindow("gs")) {
            _ = try await setup(r3, client: Status([notReady])).run { _ in }
        }
        #expect(try r2.fx.bundle.readConfig().sshSucceeded != true)
        #expect(try r3.fx.bundle.readConfig().sshSucceeded != true)
    }

    @Test func rejectedPasswordOnLockedGuestIsLoginHint() async throws {
        let r = try rig(refusals: 1); defer { r.cleanup() }
        await #expect(throws: MacAgentSetupError.loginWindow("gs")) {
            _ = try await setup(
                r, client: Status([notReady]), askPassword: { try? self.pw() },
                authorize: { _, _ in throw Self.rejected }
            ).run { _ in }
        }
    }

    @Test func missingAskpassIsClear() async throws {
        let r = try rig(refusals: 1); defer { r.cleanup() }
        await #expect(throws: MacAgentSetupError.askpassMissing) {
            _ = try await setup(
                r, client: Status([helper()]), askpass: nil, askPassword: { try? self.pw() }
            ).run { _ in }
        }
    }

    @Test func waitsForRemoteLoginOnFirstBoot() async throws {
        let r = try rig(); defer { r.cleanup() }
        let answers = Mutex<[MacAgentSetup.SSHReach]>([.refused, .refused, .open])
        let sleeps = Mutex(0)
        let ready = try await setup(
            r, client: Status([helper(granted: true)]),
            sleep: { _ in sleeps.withLock { $0 += 1 } },
            reachFn: { answers.withLock { $0.count > 1 ? $0.removeFirst() : $0[0] } },
            waitForRemoteLogin: .seconds(600)
        ).run { _ in }
        #expect(ready)
        #expect(sleeps.withLock { $0 } == 2)
    }

    @Test func waitEndsWithRemoteLoginOff() async throws {
        let r = try rig(); defer { r.cleanup() }
        let clock = Mutex(ContinuousClock.now)
        let start = clock.withLock { $0 }
        await #expect(throws: MacAgentSetupError.remoteLoginOff) {
            _ = try await setup(
                r, client: Status([helper()]), reach: .refused, now: { clock.withLock { $0 } },
                sleep: { d in clock.withLock { $0 = $0.advanced(by: d) } },
                waitForRemoteLogin: .seconds(600)
            ).run { _ in }
        }
        #expect(start.duration(to: clock.withLock { $0 }) >= .seconds(600))
    }
}
