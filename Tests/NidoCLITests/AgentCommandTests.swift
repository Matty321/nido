// SPDX-License-Identifier: Apache-2.0
import Foundation
import NidoAgentKit
import Synchronization
import Testing
@testable import NidoCLI
@testable import NidoCore

@Suite(.italian) struct AgentCommandTests {
    private func makeBundle(guest: GuestOS, agentAccess: Bool? = nil) throws -> (VMBundle, URL) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("nido-tests-agent-cli-\(UUID().uuidString)", isDirectory: true)
        let paths = NidoPaths(root: tmp)
        var config = VMConfig(
            id: UUID(), name: try VMName("vm"), guest: guest, cpuCount: 2,
            memoryBytes: 4 << 30, diskBytes: 20 << 30, macAddress: "02:00:00:00:00:01")
        config.agentAccess = agentAccess
        return (try VMBundle.create(config: config, paths: paths), tmp)
    }

    @Test func parsesClick() throws {
        let action = try AgentSupport.parseAction(["click", "10", "20", "--right", "--count", "2"])
        #expect(action == .click(x: 10, y: 20, button: .right, count: 2))
        #expect(try AgentSupport.parseAction(["click", "1.5", "2"]) == .click(x: 1.5, y: 2, button: .left, count: 1))
    }

    @Test func rejectsCountFour() throws {
        #expect(throws: (any Error).self) {
            _ = try AgentSupport.parseAction(["click", "10", "20", "--count", "4"])
        }
        #expect(throws: (any Error).self) {
            _ = try AgentSupport.parseAction(["click", "10", "20", "--count", "0"])
        }
    }

    @Test func rejectsBadCombo() throws {
        #expect(throws: KeyMapError.unknownKey("nope")) {
            _ = try AgentSupport.parseAction(["key", "cmd+nope"])
        }
        #expect(try AgentSupport.parseAction(["key", "cmd+a"]) == .key(combo: "cmd+a"))
        #expect(try AgentSupport.parseAction(["key", "cmd+é"]) == .key(combo: "cmd+é"))
    }

    @Test func parsesTheOtherActions() throws {
        #expect(try AgentSupport.parseAction(["status"]) == .status)
        #expect(try AgentSupport.parseAction(["screenshot"]) == .screenshot(maxLongEdge: 1280))
        #expect(try AgentSupport.parseAction(["screenshot", "--max", "64"]) == .screenshot(maxLongEdge: 64))
        #expect(throws: (any Error).self) { _ = try AgentSupport.parseAction(["screenshot", "--max", "63"]) }
        #expect(throws: (any Error).self) { _ = try AgentSupport.parseAction(["screenshot", "--max", "4097"]) }
        #expect(try AgentSupport.parseAction(["drag", "1", "2", "3", "4"])
            == .drag(fromX: 1, fromY: 2, toX: 3, toY: 4))
        #expect(try AgentSupport.parseAction(["scroll", "--dx", "0", "--dy", "-5"])
            == .scroll(dx: 0, dy: -5, x: nil, y: nil))
        #expect(try AgentSupport.parseAction(["scroll", "--dy", "3", "--x", "5", "--y", "6"])
            == .scroll(dx: 0, dy: 3, x: 5, y: 6))
        #expect(throws: (any Error).self) { _ = try AgentSupport.parseAction(["scroll", "--x", "5"]) }
        #expect(try AgentSupport.parseAction(["type", "hello world"]) == .type(text: "hello world"))
        #expect(throws: (any Error).self) { _ = try AgentSupport.parseAction(["frobnicate"]) }
        #expect(throws: (any Error).self) { _ = try AgentSupport.parseAction([]) }
        #expect(throws: (any Error).self) { _ = try AgentSupport.parseAction(["click", "10"]) }
        #expect(throws: (any Error).self) { _ = try AgentSupport.parseAction(["click", "a", "b"]) }
    }

    @Test func invocationCarriesOutputAndWait() throws {
        #expect(try AgentSupport.parseInvocation(["screenshot", "--output", "/x/a.png"])
            == .send(.screenshot(maxLongEdge: 1280), output: "/x/a.png"))
        #expect(try AgentSupport.parseInvocation(["wait", "250"]) == .wait(milliseconds: 250))
        #expect(try AgentSupport.parseInvocation(["status"]) == .send(.status, output: nil))
        #expect(throws: (any Error).self) { _ = try AgentSupport.parseInvocation(["click", "1", "2", "--output", "x"]) }
    }

    @Test func waitBounds() throws {
        #expect(try AgentSupport.waitMilliseconds(10000) == .milliseconds(10000))
        #expect(try AgentSupport.waitMilliseconds(0) == .zero)
        #expect(throws: (any Error).self) { _ = try AgentSupport.waitMilliseconds(10001) }
        #expect(throws: (any Error).self) { _ = try AgentSupport.waitMilliseconds(-1) }
        #expect(throws: (any Error).self) { _ = try AgentSupport.parseInvocation(["wait", "10001"]) }
        #expect(throws: (any Error).self) { _ = try AgentSupport.parseInvocation(["wait", "-1"]) }
    }

    @Test func actRefusedWithoutAgentAccess() throws {
        let (bundle, tmp) = try makeBundle(guest: .macos)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let config = try bundle.readConfig()
        #expect(throws: CLIError.agentAccessOff("vm")) { try AgentSupport.requireAgentAccess(config) }
        #expect(CLISupport.message(for: CLIError.agentAccessOff("vm"))
            == "L’accesso dell’agente è disattivato per vm: attivalo con nido agent enable vm")
        var on = config
        on.agentAccess = true
        try AgentSupport.requireAgentAccess(on)
    }

    @Test func enableRefusesLinux() throws {
        let (bundle, tmp) = try makeBundle(guest: .linux)
        defer { try? FileManager.default.removeItem(at: tmp) }
        #expect(throws: CLIError.agentNotForLinux) { _ = try AgentSupport.setAgentAccess(true, bundle: bundle) }
        #expect(try bundle.readConfig().agentAccess == nil)
        #expect(CLIError.agentNotForLinux.errorDescription == "L’accesso dell’agente è solo per le VM macOS.")
    }

    @Test func enableAndDisableWriteConfig() throws {
        let (bundle, tmp) = try makeBundle(guest: .macos)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let on = try AgentSupport.setAgentAccess(true, bundle: bundle)
        #expect(try bundle.readConfig().agentAccess == true)
        #expect(on == "L’accesso dell’agente è attivato per vm.")
        let off = try AgentSupport.setAgentAccess(false, bundle: bundle)
        #expect(try bundle.readConfig().agentAccess == false)
        #expect(off == "L’accesso dell’agente è disattivato per vm.")
    }

    /// Agent access is part of the saved state's configuration: changing it on a suspended VM
    /// says, as `nido share` does, that the saved state will be discarded at the next start.
    @Test func changingAccessOfASuspendedVMWarns() throws {
        let (bundle, tmp) = try makeBundle(guest: .macos)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let warning = "Attenzione: la VM è sospesa: al prossimo avvio lo stato salvato verrà scartato."
        #expect(!(try AgentSupport.setAgentAccess(true, bundle: bundle)).contains(warning))
        try Data("state".utf8).write(to: bundle.stateURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: bundle.stateURL.path)
        var config = try bundle.readConfig()
        config.suspendedConfigHash = config.stateHash()
        try bundle.writeConfig(config)

        // The same setting again: the saved state still resumes.
        #expect(!(try AgentSupport.setAgentAccess(true, bundle: bundle)).contains(warning))
        let off = try AgentSupport.setAgentAccess(false, bundle: bundle)
        #expect(off == "L’accesso dell’agente è disattivato per vm.\n" + warning)
    }

    @Test func enableWhileRunningSaysNextStart() throws {
        let (bundle, tmp) = try makeBundle(guest: .macos)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let lock = try BundleLock.acquire(bundle, owner: .cli)
        defer { lock.release() }
        let message = try AgentSupport.setAgentAccess(true, bundle: bundle)
        #expect(message == "L’accesso dell’agente è attivato per vm. Ha effetto dal prossimo avvio.")
        #expect(try bundle.readConfig().agentAccess == true)
    }

    /// `nido agent setup` before SSH: with FileVault on and nobody logged in, the guest's sshd is
    /// not up (or the guest has no address yet) and the helper is not ready: the hint says to log
    /// in through the window, not to turn on Remote Login.
    @Test func setupGateMatrix() {
        let notReady = AgentAnswer.failure(.notReady, "waiting for login or Nido Agent")
        let ready = AgentAnswer(ok: true, status: AgentStatus(
            helperVersion: "1.0.0", protocolVersion: 1, screenRecording: true, accessibility: true,
            screen: ScreenSize(width: 1, height: 1)))
        let absent = AgentAnswer.failure(.timeout, "slow")
        let unserved = AgentAnswer.failure(.notRunning, "restart it")

        let noAddress = AgentSupport.SSHReach.noAddress(.notOnNetwork("vm"))

        // A refusal means the guest's network is up: Remote Login, also on a first run where the
        // helper is not installed yet (notReady).
        #expect(AgentSupport.setupGate(helper: notReady, ssh: .refused) == .remoteLoginOff)
        #expect(AgentSupport.setupGate(helper: ready, ssh: .refused) == .remoteLoginOff)
        #expect(AgentSupport.setupGate(helper: absent, ssh: .refused) == .remoteLoginOff)
        // No SSH answer, or no address yet, while the helper is not ready: the login window.
        #expect(AgentSupport.setupGate(helper: notReady, ssh: .noAnswer) == .loginWindow)
        #expect(AgentSupport.setupGate(helper: notReady, ssh: noAddress) == .loginWindow)
        #expect(AgentSupport.setupGate(helper: notReady, ssh: .open) == .proceed)
        for helper in [ready, absent] {
            for ssh: AgentSupport.SSHReach in [.open, .noAnswer, noAddress] {
                #expect(AgentSupport.setupGate(helper: helper, ssh: ssh) == .proceed)
            }
        }
        for ssh: AgentSupport.SSHReach in [.open, .refused, .noAnswer, noAddress] {
            #expect(AgentSupport.setupGate(helper: unserved, ssh: ssh) == .notServed("restart it"))
        }
        #expect(CLIError.agentLoginWindow("vm").errorDescription
            == "vm potrebbe essere ferma alla finestra di login (FileVault): accedi dalla sua finestra, poi esegui di nuovo nido agent setup.")
    }

    /// FileVault on, nobody logged in: sshd answers but rejects the key. That is a login, not a key problem.
    @Test func keyRefusedBeforeLoginSaysLogIn() {
        let notReady = AgentAnswer.failure(.notReady, "waiting for login or Nido Agent")
        let hint = AgentSupport.loginHint(for: GuestSSHError.keyUnavailable("key"), helper: notReady, vm: "vm")
        #expect(hint?.errorDescription == CLIError.agentLoginWindow("vm").errorDescription)
    }

    @Test func keyRefusedWithReadyHelperStaysKeyError() {
        let ready = AgentAnswer(ok: true, status: AgentStatus(
            helperVersion: "1.0.0", protocolVersion: 1, screenRecording: true, accessibility: true,
            screen: ScreenSize(width: 1, height: 1)))
        #expect(AgentSupport.loginHint(for: GuestSSHError.keyUnavailable("key"), helper: ready, vm: "vm") == nil)
    }

    @Test func otherErrorsUntouched() {
        let notReady = AgentAnswer.failure(.notReady, "x")
        #expect(AgentSupport.loginHint(for: GuestSSHError.timeout, helper: notReady, vm: "vm") == nil)
    }

    /// The probe of `nido agent setup`: no address yet is kept for the gate; any other error of
    /// the SSH endpoint is thrown with its own message, never taken for a login window.
    @Test func setupProbeKeepsOtherErrors() throws {
        let endpoint = SSHEndpoint(host: "192.168.64.2", port: 22)
        let found: () throws -> SSHEndpoint = { endpoint }
        #expect(try AgentSupport.sshReach(resolve: found, probe: { _ in .open }) == .open)
        #expect(try AgentSupport.sshReach(resolve: found, probe: { _ in .refused }) == .refused)
        #expect(try AgentSupport.sshReach(resolve: found, probe: { _ in .noAnswer }) == .noAnswer)
        #expect(try AgentSupport.sshReach(resolve: { throw NidoError.notOnNetwork("vm") }, probe: { _ in .open })
            == .noAddress(.notOnNetwork("vm")))
        #expect(throws: NidoError.controlledNetworkInterrupted) {
            _ = try AgentSupport.sshReach(resolve: { throw NidoError.controlledNetworkInterrupted }, probe: { _ in .open })
        }
        #expect(throws: NidoError.notRunning("vm")) {
            _ = try AgentSupport.sshReach(resolve: { throw NidoError.notRunning("vm") }, probe: { _ in .open })
        }
        struct Other: Error, Equatable {}
        #expect(throws: Other()) {
            _ = try AgentSupport.sshReach(resolve: { throw Other() }, probe: { _ in .open })
        }
    }

    @Test func jsonIsOneLine() throws {
        let answer = AgentAnswer(
            ok: true, path: "/a/b.png", image: PixelSize(10, 20),
            screen: ScreenSize(width: 5, height: 6), message: "line1\nline2")
        let json = AgentSupport.json(answer)
        #expect(!json.contains("\n"))
        // A line break in a message is the guest's text too: a space.
        #expect(json == #"{"image":{"height":20,"width":10},"message":"line1 line2","ok":true,"path":"/a/b.png","screen":{"height":6,"width":5}}"#)
        #expect(AgentSupport.json(AgentAnswer(ok: true)) == #"{"ok":true}"#)
    }

    /// SECURITY: JSON escapes C0 controls but not C1 ones (U+009B is a CSI for some terminals):
    /// what the guest wrote in an answer is cleaned before it is encoded.
    @Test func guestTextIsCleanedBeforeJSON() throws {
        let dirty = "a\u{1B}]52;c;eA==\u{07}\u{9B}31m\u{85}b"
        let act = AgentSupport.json(AgentAnswer.failure(.internalError, dirty))
        let status = AgentSupport.statusJSON(agentAccess: true, running: true, helper: AgentAnswer(
            ok: true, status: AgentStatus(helperVersion: "1.0\u{9B}2J", protocolVersion: 1, screenRecording: true,
                                          accessibility: true, screen: ScreenSize(width: 1, height: 1)),
            message: dirty))
        for json in [act, status] {
            #expect(!json.unicodeScalars.contains { $0.properties.generalCategory == .control })
            #expect(!json.contains("\\u001b") && !json.contains("\\u0007"))
            #expect(json.contains("a ]52;c;eA== 31m b"))
        }
        #expect(status.contains(#""helperVersion":"1.0 2J""#))
    }

    @Test func statusReportIsSortedJSON() throws {
        let stopped = AgentSupport.statusJSON(agentAccess: true, running: false, helper: nil)
        #expect(stopped == #"{"agentAccess":true,"running":false}"#)
        let running = AgentSupport.statusJSON(
            agentAccess: true, running: true, helper: AgentAnswer.failure(.notReady, "x"))
        #expect(running == #"{"agentAccess":true,"helper":{"error":"notReady","message":"x","ok":false},"running":true}"#)
    }

    @Test func throwingClientStillYieldsStatusJSON() throws {
        struct Boom: Error {}
        let transport = AgentSupport.helperAnswer { throw AgentFailure(code: .internalError, message: "lost") }
        #expect(!transport.ok && transport.error == .internalError && transport.message == "lost")
        let other = AgentSupport.helperAnswer { throw Boom() }
        #expect(!other.ok && other.error == .internalError)
        let json = AgentSupport.statusJSON(agentAccess: true, running: true, helper: transport)
        #expect(json == #"{"agentAccess":true,"helper":{"error":"internalError","message":"lost","ok":false},"running":true}"#)
        #expect(AgentSupport.helperAnswer { AgentAnswer(ok: true) }.ok)
    }

    @Test func failedCopyTurnsScreenshotAnswerIntoFailure() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("nido-tests-agent-done-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let source = tmp.appendingPathComponent("s.png")
        try Data([9]).write(to: source)
        let existing = tmp.appendingPathComponent("there.png")
        try Data([1]).write(to: existing)
        let answer = AgentAnswer(ok: true, path: source.path)
        let failed = AgentSupport.completeScreenshot(answer, output: existing.path)
        #expect(!failed.ok && failed.error == .internalError && failed.path == source.path)
        #expect(failed.message?.contains("esiste già") == true)
        #expect(!AgentSupport.completeScreenshot(AgentAnswer(ok: true), output: existing.path).ok)
        let fresh = tmp.appendingPathComponent("new.png")
        #expect(AgentSupport.completeScreenshot(answer, output: fresh.path) == answer)
        #expect(try Data(contentsOf: fresh) == Data([9]))
        #expect(AgentSupport.completeScreenshot(answer, output: nil) == answer)
    }

    @Test func copyScreenshotRefusesToOverwrite() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("nido-tests-agent-copy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let source = tmp.appendingPathComponent("s.png")
        try Data([1, 2, 3]).write(to: source)
        let dest = tmp.appendingPathComponent("out.png")
        try AgentSupport.copyScreenshot(from: source.path, to: dest.path)
        #expect(try Data(contentsOf: dest) == Data([1, 2, 3]))
        let mode = try FileManager.default.attributesOfItem(atPath: dest.path)[.posixPermissions] as? Int
        #expect(((mode ?? 0) & 0o022) == 0)
        #expect(throws: CLIError.outputExists(dest.path)) {
            try AgentSupport.copyScreenshot(from: source.path, to: dest.path)
        }
        #expect(try Data(contentsOf: dest) == Data([1, 2, 3]))
    }

    // MARK: - An unusable stored password after a ready setup

    /// A store whose item is no usable password until `save` replaces it (or whose `save` fails).
    private final class UnusableStore: GuestPasswordStore, @unchecked Sendable {
        private let lock = NSLock()
        private var saved: GuestPassword?
        var readError: GuestPasswordStoreError? = .unusableItem
        var failsSave = false
        var stored: GuestPassword? { lock.withLock { saved } }
        func read(vm: UUID) throws -> GuestPassword? {
            try lock.withLock {
                if let saved { return saved }
                if let readError { throw readError }
                return nil
            }
        }
        func save(_ password: GuestPassword, vm: UUID) throws {
            try lock.withLock {
                if failsSave { throw GuestPasswordStoreError.keychain(-25308) }
                saved = password
            }
        }
        func delete(vm: UUID) throws {}
    }

    /// The key already works, so the setup never read the stored item: an unusable one is
    /// replaced with the password asked once at the terminal; without a terminal, a warning.
    @Test func unusableItemIsReplacedAfterAReadySetup() async throws {
        let id = UUID()
        let fresh = try #require(GuestPassword("fresh-one"))
        let store = UnusableStore()
        let asks = Mutex(0)
        let replaced = await AgentSupport.replaceUnusablePassword(vm: "mac", id: id, store: store, ask: {
            asks.withLock { $0 += 1 }
            return fresh
        })
        #expect(replaced == .replaced("La password salvata per mac è stata sostituita."))
        #expect(asks.withLock { $0 } == 1)
        #expect(store.stored == fresh)

        // No terminal, or nothing typed: the item's text, as a warning.
        let unusable = GuestPasswordStoreError.unusableItem.errorDescription ?? "?"
        #expect(await AgentSupport.replaceUnusablePassword(vm: "mac", id: id, store: UnusableStore(), ask: nil)
            == .warning(unusable))
        #expect(await AgentSupport.replaceUnusablePassword(vm: "mac", id: id, store: UnusableStore(), ask: { nil })
            == .warning(unusable))

        // The Keychain refuses the new one: said, not hidden.
        let refusing = UnusableStore()
        refusing.failsSave = true
        guard case .warning(let line) = await AgentSupport.replaceUnusablePassword(
            vm: "mac", id: id, store: refusing, ask: { fresh })
        else {
            Issue.record("expected a warning")
            return
        }
        #expect(line.hasPrefix("Non è stato possibile sostituire la password salvata per mac:"))
        #expect(line.contains("-25308"))

        // A usable item, none, or another Keychain error: nothing asked, nothing said.
        for readError in [nil, GuestPasswordStoreError.keychain(-25293)] as [GuestPasswordStoreError?] {
            let other = UnusableStore()
            other.readError = readError
            #expect(await AgentSupport.replaceUnusablePassword(vm: "mac", id: id, store: other, ask: {
                Issue.record("asked")
                return fresh
            }) == .unchanged)
        }
        let usable = UnusableStore()
        try usable.save(fresh, vm: id)
        #expect(await AgentSupport.replaceUnusablePassword(vm: "mac", id: id, store: usable, ask: nil) == .unchanged)
    }
}
