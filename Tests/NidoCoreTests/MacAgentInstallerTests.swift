// SPDX-License-Identifier: Apache-2.0
import Foundation
import NidoAgentKit
import Testing
@testable import NidoCore

@Suite(.italian) struct MacAgentInstallerTests {
    // MARK: - Commands

    @Test func argvIsConstant() throws {
        let cases: [(GuestCommand, String)] = [
            (.installMacAgent, MacAgentInstaller.installScript),
            (.openMacAgent, MacAgentInstaller.openScript),
            (.readMacLoginState, MacAgentInstaller.loginStateScript),
        ]
        for (command, script) in cases {
            let argv = try command.argv()
            #expect(Array(argv[0...1]) == ["/bin/sh", "-c"])
            #expect(argv == ["/bin/sh", "-c", script])
            // One quoted element each: the remote shell sees the script untouched.
            #expect(try command.remoteCommand() == "'/bin/sh' '-c' " + GuestCommand.shellQuote(script))
        }
    }

    @Test func installScriptChecksSignature() {
        let script = MacAgentInstaller.installScript
        #expect(script.contains("codesign --verify --strict"))
        #expect(script.contains("io.gitlab.pichierri.Nido.Agent"))
        #expect(script.contains("set -eu"))
        #expect(script.contains("trap 'rm -rf \"$tmp\"' EXIT"))
        #expect(script.contains("PlistBuddy"))
        #expect(!script.contains("$1"))
        #expect(!script.contains("sudo"))
        #expect(MacAgentInstaller.openScript == #"open -g "$HOME/Applications/NidoAgent.app""#)
        #expect(!MacAgentInstaller.loginStateScript.contains("sudo"))
    }

    @Test func installRunsOverSSHAsTheMacUser() async throws {
        let fx = try MacGuestFixture(sshUser: "agente", withKey: false); defer { fx.cleanup() }
        let runner = ScriptedRunner { _ in result(0, out: "1.0.0\n") }
        let payload = Data("TAR".utf8)
        let out = try await fx.ssh(runner).run(.installMacAgent, stdin: payload, timeout: .seconds(60))
        #expect(out.stdout == "1.0.0\n")
        let call = try #require(runner.calls.first)
        #expect(call.stdin == payload)
        #expect(call.arguments.contains("agente@192.168.64.9"))
        #expect(call.arguments.last == (try GuestCommand.installMacAgent.remoteCommand()))
    }

    // MARK: - R3: macOS reaches the guest the way `nido ssh` does

    @Test func macWithoutKeyUsesAgentAndTheMacAccount() async throws {
        let fx = try MacGuestFixture(sshUser: "agente", withKey: false, recordKey: false); defer { fx.cleanup() }
        let runner = ScriptedRunner { _ in result(0) }
        _ = try await fx.ssh(runner).run(.readMacLoginState, timeout: .seconds(5))
        let args = try #require(runner.calls.first).arguments
        #expect(!args.contains("-i"))
        #expect(!args.contains("IdentitiesOnly=yes"))
        #expect(args.contains("BatchMode=yes"))
        #expect(args.contains("agente@192.168.64.9"))
        #expect(!args.contains("nido@192.168.64.9"))
    }

    @Test func macWithOnlyPublicKeyOffersItToTheAgent() async throws {
        let fx = try MacGuestFixture(sshUser: "agente", withKey: false); defer { fx.cleanup() }
        let runner = ScriptedRunner { _ in result(0) }
        _ = try await fx.ssh(runner).run(.readMacLoginState, timeout: .seconds(5))
        let args = try #require(runner.calls.first).arguments
        let index = try #require(args.firstIndex(of: "-i"))
        #expect(args[index + 1] == fx.publicKeyPath)
    }

    @Test func macWithPrivateKeyUsesIt() async throws {
        let fx = try MacGuestFixture(sshUser: "agente", withKey: true); defer { fx.cleanup() }
        let runner = ScriptedRunner { _ in result(0) }
        _ = try await fx.ssh(runner).run(.readMacLoginState, timeout: .seconds(5))
        let args = try #require(runner.calls.first).arguments
        let index = try #require(args.firstIndex(of: "-i"))
        #expect(args[index + 1] == fx.privateKeyPath)
    }

    @Test func linuxStillNeedsItsKeyAndUserNido() async throws {
        let fx = try GuestFixture(); defer { fx.cleanup() }
        try fx.bundle.updateConfig { $0.sshPublicKeyPath = nil }
        let runner = ScriptedRunner { _ in result(0) }
        await #expect(throws: GuestSSHError.keyNotConfigured) {
            _ = try await fx.ssh(runner).run(.readMacLoginState, timeout: .seconds(5))
        }
        #expect(runner.calls.isEmpty)
    }

    // MARK: - Login state

    @Test func parsesFileVaultOn() {
        let state = MacAgentInstaller.parseLoginState("filevault=on\nautologin=\n")
        #expect(state.fileVaultOn == true)
        #expect(state.autoLoginUser == nil)
        #expect(state.advice == L10n.string("FileVault is on in this VM: an agent can use it only after you log in through its window at each start. To start it headless, turn off FileVault and turn on automatic login in the VM."))
    }

    @Test func parsesAutoLogin() {
        let state = MacAgentInstaller.parseLoginState("filevault=off\nautologin=agente\n")
        #expect(state.fileVaultOn == false)
        #expect(state.autoLoginUser == "agente")
        #expect(state.advice == nil)
    }

    @Test func unknownOrGarbageIsUnknown() {
        let state = MacAgentInstaller.parseLoginState("filevault=unknown\nwarning: x\n")
        #expect(state.fileVaultOn == nil)
        #expect(state.advice == nil)
        #expect(MacAgentInstaller.parseLoginState("").fileVaultOn == nil)
    }

    // MARK: - Payload

    @Test func payloadIsTarOfApp() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nido-payload-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let app = dir.appendingPathComponent("NidoAgent.app/Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let plist = app.appendingPathComponent("Info.plist")
        try Data("x".utf8).write(to: plist)
        // An extended attribute is what makes tar add a `._Info.plist` entry without the flag.
        #expect(setxattr(plist.path, "com.apple.test", "v", 1, 0, 0) == 0)
        let data = try MacAgentInstaller.payload(app: dir.appendingPathComponent("NidoAgent.app"))
        #expect(String(decoding: data.prefix(14), as: UTF8.self) == "NidoAgent.app/")
        #expect(String(decoding: data[257..<262], as: UTF8.self) == "ustar")
        let archive = dir.appendingPathComponent("payload.tar")
        try data.write(to: archive)
        let listing = try ProcessInfoLister.entries(of: archive)
        #expect(listing.contains("NidoAgent.app/Contents/Info.plist"))
        #expect(!listing.contains { $0.contains("._") })
        // The attribute itself (pax records) must not travel either: no quarantine, no metadata.
        let hasXattr = ["xattr", "com.apple.test"].contains { data.range(of: Data($0.utf8)) != nil }
        #expect(!hasXattr)
    }

    @Test func payloadRefusesOtherNames() throws {
        #expect(throws: NidoError.macAgentUnavailable) {
            _ = try MacAgentInstaller.payload(app: URL(fileURLWithPath: "/tmp/Other.app"))
        }
    }

    // MARK: - Versions

    @Test func compareVersionsIsNumeric() {
        #expect(MacAgentInstaller.compareVersions("1.0.0", "1.0.0") == 0)
        #expect(MacAgentInstaller.compareVersions("1.0", "1.0.0") == 0)
        #expect(MacAgentInstaller.compareVersions("1.2", "1.10") < 0)
        #expect(MacAgentInstaller.compareVersions("2.0.1", "2.0") > 0)
        #expect(MacAgentInstaller.compareVersions("1.0.0", "1.0.1") < 0)
    }

    private func granted(_ on: Bool, version: String = "1.0.0") -> AgentAnswer {
        AgentAnswer(ok: true, status: AgentStatus(
            helperVersion: version, protocolVersion: 1, screenRecording: on, accessibility: on,
            screen: ScreenSize(width: 10, height: 10)))
    }

    @Test func installDecision() {
        func decide(_ answer: AgentAnswer) -> MacAgentInstaller.InstallDecision {
            MacAgentInstaller.installDecision(helper: answer, bundledVersion: "1.0.0")
        }
        #expect(decide(.failure(.notReady, "x")) == .install)
        #expect(decide(.failure(.timeout, "x")) == .install)
        #expect(decide(.failure(.notRunning, "x")) == .install)
        #expect(decide(granted(false, version: "0.9.0")) == .install)
        #expect(decide(granted(false)) == .current)
        #expect(decide(granted(false, version: "1.0")) == .current)
        #expect(decide(granted(false, version: "1.1.0")) == .newer)
        #expect(decide(.failure(.versionMismatch, "protocol")) == .install)
    }

    // MARK: - Polling

    /// A fake clock: `sleep` advances it by 2 s, each `status` call by `cost`. `reopens` holds the
    /// instants (seconds from the start) at which `reopen` ran.
    private final class Fake: @unchecked Sendable {
        let start = ContinuousClock.now
        lazy var instant = start
        var lines: [String] = []
        var polls = 0
        var sleeps = 0
        var reopens: [Int] = []
    }

    private func poll(
        _ answers: [AgentAnswer], cost: Duration = .zero, repeating last: AgentAnswer? = nil,
        timeout: Duration = .seconds(600), grace: Duration = .seconds(15), reopenWorks: Bool = true
    ) async -> (MacAgentInstaller.Outcome, Fake) {
        let fake = Fake()
        var queue = answers
        let outcome = await MacAgentInstaller.awaitReady(
            vm: "m1", timeout: timeout, loginGrace: grace,
            now: { fake.instant },
            status: {
                fake.polls += 1
                fake.instant = fake.instant.advanced(by: cost)
                return queue.isEmpty ? (last ?? self.granted(false)) : queue.removeFirst()
            },
            reopen: {
                fake.reopens.append(Int(fake.start.duration(to: fake.instant).components.seconds))
                return reopenWorks
            },
            sleep: { fake.sleeps += 1; fake.instant = fake.instant.advanced(by: .seconds(2)) },
            emit: { fake.lines.append($0) })
        return (outcome, fake)
    }

    private let loginHint = L10n.string("Log in to \("m1") in its window.")
    private let reopening = L10n.string("Nido Agent stopped: opening it again.")

    @Test func readyOnThirdPoll() async {
        let (outcome, fake) = await poll([granted(false), granted(false), granted(true)])
        #expect(outcome == .ready)
        #expect(fake.sleeps == 2)
        #expect(fake.lines.filter { $0 == L10n.string("In the VM, allow Nido Agent in Screen Recording and Accessibility (System Settings › Privacy & Security).") }.count == 1)
        #expect(fake.lines.last == L10n.string("Nido Agent is ready in \("m1")."))
    }

    @Test func freshOpenNotReadyStaysSilentDuringGrace() async {
        // 4 polls of notReady (6 s) then ready: the helper was only starting.
        let (outcome, fake) = await poll([
            .failure(.notReady, "x"), .failure(.notReady, "x"), .failure(.notReady, "x"),
            .failure(.notReady, "x"), granted(true)])
        #expect(outcome == .ready)
        #expect(!fake.lines.contains(loginHint))
        #expect(fake.reopens.isEmpty)
    }

    /// A helper that has not answered `loginGrace` after `open` is opened once more; only when it
    /// still does not answer `loginGrace` later is the user asked to log in.
    @Test func persistentNotReadyRetriesOpenOnceThenPrintsLoginHint() async {
        // 20 polls (38 s) of notReady, then ready.
        let (outcome, fake) = await poll(Array(repeating: .failure(.notReady, "x"), count: 20) + [granted(true)])
        #expect(outcome == .ready)
        #expect(fake.reopens == [16])
        #expect(fake.lines.filter { $0 == loginHint }.count == 1)

        // Up to 30 s (the retry at 16 s, then less than a grace): no login hint yet.
        let (_, early) = await poll(Array(repeating: .failure(.notReady, "x"), count: 15) + [granted(true)])
        #expect(early.reopens == [16])
        #expect(!early.lines.contains(loginHint))
    }

    /// The `open` of the retry fails (nobody is logged in, no SSH): the login hint at once.
    @Test func failedRetryPrintsTheLoginHint() async {
        let (outcome, fake) = await poll(
            Array(repeating: .failure(.notReady, "x"), count: 10) + [granted(true)], reopenWorks: false)
        #expect(outcome == .ready)
        #expect(fake.reopens == [16])
        #expect(fake.lines.filter { $0 == loginHint }.count == 1)
    }

    /// Seen on macOS 26.6.2: the helper answered (permissions missing), the user allowed Screen
    /// Recording, System Settings quit the helper ("Quit & Reopen") and nothing opened it again.
    /// The helper that stops answering is opened again at once, without the login hint.
    @Test func helperThatQuitIsOpenedAgain() async {
        let (outcome, fake) = await poll([
            granted(false), .failure(.notReady, "x"), .failure(.notReady, "x"), granted(true)])
        #expect(outcome == .ready)
        #expect(fake.reopens == [2])
        #expect(fake.lines.filter { $0 == reopening }.count == 1)
        #expect(!fake.lines.contains(loginHint))
    }

    /// A helper that keeps quitting is opened again at most three times.
    @Test func helperThatKeepsQuittingIsReopenedAFewTimes() async {
        let cycle: [AgentAnswer] = [granted(false), .failure(.notReady, "x")]
        let (outcome, fake) = await poll(Array([[AgentAnswer]](repeating: cycle, count: 6).joined()), timeout: .seconds(40))
        #expect(outcome == .timedOut)
        #expect(fake.reopens.count == 3)
    }

    @Test func timesOutAtTheDeadline() async {
        let (outcome, fake) = await poll([], timeout: .seconds(10))
        #expect(outcome == .timedOut)
        #expect(fake.polls == 6)  // t = 0, 2, 4, 6, 8, 10
        #expect(fake.lines.last == L10n.string("Timed out waiting for Nido Agent in \("m1"): grant the permissions, then run nido agent setup \("m1") again."))
    }

    @Test func slowStatusStillEndsAtTheDeadline() async {
        // Each status takes 20 s: 600 s allow 28 polls, not 300.
        let (outcome, fake) = await poll([], cost: .seconds(20), timeout: .seconds(600))
        #expect(outcome == .timedOut)
        #expect(fake.polls <= 28)
        #expect(fake.polls >= 27)
    }

    @Test func stoppedVMEndsPolling() async {
        #expect(await poll([.failure(.notRunning, "start it")]).0 == .stopped)
    }

    @Test func accessOffIsNotReportedAsStopped() async {
        #expect(await poll([.failure(.agentAccessOff, "off")]).0 == .accessOff)
    }

    @Test func versionMismatchEndsWithItsMessage() async {
        let (outcome, fake) = await poll([.failure(.versionMismatch, "protocol 2 needed")])
        #expect(outcome == .versionMismatch)
        #expect(fake.lines == [L10n.string("Nido Agent answered with an error: \("protocol 2 needed")")])
    }

    /// SECURITY: a helper's message is the guest's text: an escape sequence in it (OSC 52 would
    /// set the Mac's clipboard) never reaches the terminal.
    @Test func helperMessagesArePrintedWithoutControls() async {
        let osc52 = "\u{1B}]52;c;aGVsbG8=\u{07}boom\u{9B}31m"
        for failure: AgentAnswer in [.failure(.internalError, osc52), .failure(.versionMismatch, osc52)] {
            let (_, fake) = await poll([failure, granted(true)])
            let printed = fake.lines.joined(separator: "\n")
            #expect(printed.contains("boom"))
            #expect(!printed.unicodeScalars.contains { $0.properties.generalCategory == .control && $0 != "\n" })
        }
    }

    @Test func firstUnexpectedErrorIsPrintedOnce() async {
        let (outcome, fake) = await poll([
            .failure(.internalError, "boom"), .failure(.timeout, "slow"), granted(true)])
        #expect(outcome == .ready)
        #expect(fake.lines.filter { $0.contains("boom") }.count == 1)
        #expect(!fake.lines.contains { $0.contains("slow") })
    }

    // MARK: - SSH_AUTH_SOCK (macOS only)

    /// A real Unix socket in a short path (sockaddr_un holds 104 bytes).
    private func makeSocket() throws -> (path: String, close: () -> Void) {
        let path = "/tmp/nido-t-\(UUID().uuidString.prefix(8)).sock"
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            for (i, byte) in path.utf8.enumerated() { raw[i] = byte }
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        try #require(bound == 0)
        return (path, { Darwin.close(fd); unlink(path) })
    }

    @Test func macChildGetsAValidAgentSocket() async throws {
        let fx = try MacGuestFixture(sshUser: "agente", withKey: false); defer { fx.cleanup() }
        let socket = try makeSocket(); defer { socket.close() }
        let runner = ScriptedRunner { _ in result(0) }
        _ = try await fx.ssh(runner, environment: ["SSH_AUTH_SOCK": socket.path, "HOME": "/x"])
            .run(.readMacLoginState, timeout: .seconds(5))
        #expect(try #require(runner.calls.first).environment == ["SSH_AUTH_SOCK": socket.path])
        // ForwardAgent stays off.
        #expect(try #require(runner.calls.first).arguments.contains("ForwardAgent=no"))
    }

    @Test func macChildGetsNoInvalidAgentSocket() async throws {
        let fx = try MacGuestFixture(sshUser: "agente", withKey: false); defer { fx.cleanup() }
        let file = fx.root.appendingPathComponent("not-a-socket")
        FileManager.default.createFile(atPath: file.path, contents: Data())
        for value in ["", "relative.sock", "/nonexistent/agent.sock", file.path, fx.root.path] {
            let runner = ScriptedRunner { _ in result(0) }
            _ = try await fx.ssh(runner, environment: ["SSH_AUTH_SOCK": value])
                .run(.readMacLoginState, timeout: .seconds(5))
            #expect(try #require(runner.calls.first).environment.isEmpty, "\(value)")
        }
        // A socket of another user is refused.
        let socket = try makeSocket(); defer { socket.close() }
        #expect(GuestSSH.agentEnvironment(
            guest: .macos, environment: ["SSH_AUTH_SOCK": socket.path], uid: getuid() &+ 1).isEmpty)
    }

    @Test func linuxChildNeverGetsTheAgentSocket() async throws {
        let fx = try GuestFixture(); defer { fx.cleanup() }
        let socket = try makeSocket(); defer { socket.close() }
        let runner = ScriptedRunner { _ in result(0) }
        let ssh = GuestSSH(
            bundle: fx.bundle, config: try fx.bundle.readConfig(), runner: runner,
            environment: ["SSH_AUTH_SOCK": socket.path],
            resolveSSH: { _ in SSHEndpoint(host: "192.168.64.9", port: 22) })
        _ = try await ssh.run(.isServiceActive("x"), timeout: .seconds(5))
        #expect(try #require(runner.calls.first).environment.isEmpty)
    }
}


/// A macOS VM whose key may be missing, as `nido ssh` copes with.
struct MacGuestFixture {
    let root: URL
    let bundle: VMBundle
    let keyDir: URL

    init(sshUser: String, withKey: Bool, recordKey: Bool = true) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nido-mgssh-\(UUID().uuidString)", isDirectory: true)
        keyDir = root.appendingPathComponent("keys", isDirectory: true)
        try FileManager.default.createDirectory(at: keyDir, withIntermediateDirectories: true)
        let pub = keyDir.appendingPathComponent("id_test.pub")
        FileManager.default.createFile(atPath: pub.path, contents: Data("ssh-ed25519 AAAA".utf8))
        if withKey { FileManager.default.createFile(atPath: String(pub.path.dropLast(4)), contents: Data("PRIVATE".utf8)) }
        let config = VMConfig(
            id: UUID(), name: try VMName("mg"), guest: .macos, cpuCount: 2,
            memoryBytes: 4 << 30, diskBytes: 20 << 30, macAddress: "02:00:00:00:00:02",
            sshPublicKeyPath: recordKey ? pub.path : nil, sshUser: sshUser)
        bundle = try VMBundle.create(config: config, paths: NidoPaths(root: root.appendingPathComponent("VMs")))
    }

    var publicKeyPath: String { keyDir.appendingPathComponent("id_test.pub").path }
    var privateKeyPath: String { keyDir.appendingPathComponent("id_test").path }
    func cleanup() { try? FileManager.default.removeItem(at: root) }

    func ssh(_ runner: ProcessRunner, environment: [String: String] = [:]) throws -> GuestSSH {
        GuestSSH(bundle: bundle, config: try bundle.readConfig(), runner: runner, environment: environment,
                 resolveSSH: { _ in SSHEndpoint(host: "192.168.64.9", port: 22) })
    }
}

/// `tar -t` of an archive (tests only).
enum ProcessInfoLister {
    static func entries(of archive: URL) throws -> [String] {
        let out = try SystemProcessRunner().run(
            executable: URL(fileURLWithPath: "/usr/bin/tar"), arguments: ["-tf", archive.path])
        return String(decoding: out.stdout, as: UTF8.self).split(separator: "\n").map(String.init)
    }
}
