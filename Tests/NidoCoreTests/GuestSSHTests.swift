// SPDX-License-Identifier: Apache-2.0
import Foundation
import Synchronization
import Testing
@testable import NidoCore

/// Records every call and answers with a scripted result.
final class ScriptedRunner: ProcessRunner, @unchecked Sendable {
    struct Call: Sendable { let executable: String; let arguments: [String]; let stdin: Data?; let timeout: TimeInterval
        var environment: [String: String] = [:] }
    private let state = Mutex<[Call]>([])
    private let responder: @Sendable (Call) -> ProcessResult
    /// The pid handed to `onLaunch` (nil: never called, as a runner that launches nothing).
    private let launchPID: pid_t?
    init(launchPID: pid_t? = nil, _ responder: @escaping @Sendable (Call) -> ProcessResult) {
        self.responder = responder
        self.launchPID = launchPID
    }
    var calls: [Call] { state.withLock { $0 } }

    func run(executable: URL, arguments: [String]) throws -> ProcessResult {
        throw NidoError.processFailed(executable: executable.path, status: -1)
    }

    func run(
        executable: URL, arguments: [String], stdin: Data?, timeout: TimeInterval, maxOutput: Int
    ) throws -> ProcessResult {
        let call = Call(executable: executable.path, arguments: arguments, stdin: stdin, timeout: timeout)
        state.withLock { $0.append(call) }
        return responder(call)
    }

    func run(
        executable: URL, arguments: [String], stdin: Data?, timeout: TimeInterval, maxOutput: Int,
        cancellation: ProcessCancellation?, environment: [String: String],
        onStdout: (@Sendable (Data) -> Void)?
    ) throws -> ProcessResult {
        let call = Call(
            executable: executable.path, arguments: arguments, stdin: stdin, timeout: timeout,
            environment: environment)
        state.withLock { $0.append(call) }
        return responder(call)
    }

    func run(
        executable: URL, arguments: [String], stdin: Data?, timeout: TimeInterval, maxOutput: Int,
        cancellation: ProcessCancellation?, environment: [String: String],
        onLaunch: (@Sendable (pid_t) -> Void)?, onStdout: (@Sendable (Data) -> Void)?
    ) throws -> ProcessResult {
        if let launchPID { onLaunch?(launchPID) }
        return try run(
            executable: executable, arguments: arguments, stdin: stdin, timeout: timeout, maxOutput: maxOutput,
            cancellation: cancellation, environment: environment, onStdout: onStdout)
    }
}

func result(_ status: Int32, out: String = "", err: String = "", timedOut: Bool = false) -> ProcessResult {
    ProcessResult(status: status, stdout: Data(out.utf8), stderr: Data(err.utf8), timedOut: timedOut)
}

struct GuestFixture {
    let root: URL
    let bundle: VMBundle
    let keyDir: URL

    init(withKey: Bool = true, sshPublicKeyPath: String? = nil) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nido-gssh-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        keyDir = root.appendingPathComponent("keys", isDirectory: true)
        try FileManager.default.createDirectory(at: keyDir, withIntermediateDirectories: true)
        let pub = keyDir.appendingPathComponent("id_test.pub").path
        if withKey {
            FileManager.default.createFile(atPath: pub.dropLast(4).description, contents: Data("PRIVATE".utf8))
        }
        let config = VMConfig(
            id: UUID(), name: try VMName("gs"), guest: .linux, cpuCount: 2,
            memoryBytes: 4 << 30, diskBytes: 20 << 30, macAddress: "02:00:00:00:00:01",
            sshPublicKeyPath: sshPublicKeyPath ?? pub)
        bundle = try VMBundle.create(config: config, paths: NidoPaths(root: root.appendingPathComponent("VMs")))
    }

    var publicKeyPath: String { keyDir.appendingPathComponent("id_test.pub").path }
    var privateKeyPath: String { keyDir.appendingPathComponent("id_test").path }
    func cleanup() { try? FileManager.default.removeItem(at: root) }

    func ssh(_ runner: ProcessRunner) throws -> GuestSSH {
        GuestSSH(bundle: bundle, config: try bundle.readConfig(), runner: runner, resolveSSH: { _ in SSHEndpoint(host: "192.168.64.9", port: 22) })
    }
}

@Suite(.italian) struct GuestSSHTests {
    @Test func argvIsFixedAndQuoted() async throws {
        let fx = try GuestFixture(); defer { fx.cleanup() }
        let runner = ScriptedRunner { _ in result(0, out: "active\n") }
        let out = try await fx.ssh(runner).run(.isServiceActive("nido-guest-tools"), timeout: .seconds(5))
        #expect(out.stdout == "active\n")
        let call = try #require(runner.calls.first)
        #expect(call.executable == "/usr/bin/ssh")
        #expect(call.timeout == 5)
        let expected = [
            "-i", fx.privateKeyPath, "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=5",
            // The user's ~/.ssh/config cannot change what runs or how.
            "-o", "RemoteCommand=none", "-o", "RequestTTY=no", "-o", "ControlMaster=no",
            "-o", "ControlPath=none",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "HostKeyAlias=nido-\(try fx.bundle.readConfig().id.uuidString.lowercased())",
            "-o", "UserKnownHostsFile=\"\(fx.bundle.knownHostsURL.path)\"",
            "-o", "GlobalKnownHostsFile=/dev/null", "-o", "ForwardAgent=no", "-o", "ForwardX11=no",
            // No forward from the user's ssh config gives the guest a path out.
            "-o", "ClearAllForwardings=yes", "-o", "Tunnel=no", "-o", "PermitRemoteOpen=none",
            "nido@192.168.64.9", "--", "'systemctl' 'is-active' 'nido-guest-tools'",
        ]
        #expect(call.arguments == expected)
        // The remote command is the last element, after a lone `--`.
        #expect(call.arguments.filter { $0 == "--" }.count == 1)
    }

    @Test func existingVMPanicSettingsCommandIsFixed() async throws {
        let script = GuestPanicSettings.applyScript
        #expect(try GuestCommand.applyPanicSettings.argv() == ["sudo", "-n", "/bin/sh", "-c", script])
        #expect(try GuestCommand.applyPanicSettings.remoteCommand()
            == "'sudo' '-n' '/bin/sh' '-c' " + GuestCommand.shellQuote(script))
        // The same files as the seed, then the kernel command line and sysctl.
        #expect(script.contains("/etc/default/grub.d/nido.cfg"))
        #expect(script.contains("/etc/sysctl.d/90-nido.conf"))
        #expect(script.contains(GuestPanicSettings.grubContent))
        #expect(script.contains(GuestPanicSettings.sysctlContent))
        #expect(script.contains("\nupdate-grub"))
        #expect(script.contains("\nsysctl --system"))

        let fx = try GuestFixture(); defer { fx.cleanup() }
        let runner = ScriptedRunner { _ in result(0) }
        _ = try await fx.ssh(runner).run(.applyPanicSettings, timeout: .seconds(60))
        let call = try #require(runner.calls.first)
        #expect(call.arguments.last == (try GuestCommand.applyPanicSettings.remoteCommand()))
        #expect(call.stdin == nil)
    }

    /// The script run against a scratch directory (paths rewritten, `update-grub` and `sysctl`
    /// stubbed): it writes the two files with the seed's contents and running it again changes nothing.
    @Test func panicSettingsScriptIsIdempotent() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("nido-panic-\(UUID().uuidString)", isDirectory: true)
        let bin = dir.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = dir.appendingPathComponent("calls.log")
        for tool in ["update-grub", "sysctl"] {
            let stub = bin.appendingPathComponent(tool)
            try "#!/bin/sh\necho \"\(tool) $*\" >> '\(log.path)'\n".write(to: stub, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        }
        let script = GuestPanicSettings.applyScript.replacingOccurrences(of: "/etc/", with: dir.path + "/etc/")
        let grub = dir.appendingPathComponent("etc/default/grub.d/nido.cfg")
        let sysctl = dir.appendingPathComponent("etc/sysctl.d/90-nido.conf")
        for _ in 0..<2 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", script]
            process.environment = ["PATH": bin.path + ":/usr/bin:/bin"]
            try process.run()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0)
            #expect(try String(contentsOf: grub, encoding: .utf8) == GuestPanicSettings.grubContent)
            #expect(try String(contentsOf: sysctl, encoding: .utf8) == GuestPanicSettings.sysctlContent)
        }
        #expect(try String(contentsOf: log, encoding: .utf8)
            == "update-grub \nsysctl --system\nupdate-grub \nsysctl --system\n")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: grub.deletingLastPathComponent().path)
        #expect(leftovers == ["nido.cfg"])
    }

    @Test func quotingKeepsAnyElementInertForTheGuestShell() {
        #expect(GuestCommand.shellQuote("it's $(x); `y`") == #"'it'\''s $(x); `y`'"#)
    }

    @Test func privateKeyIsNeverRead() async throws {
        let fx = try GuestFixture(); defer { fx.cleanup() }
        // Mode 000: opening it would fail, lstat does not care.
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: fx.privateKeyPath)
        let runner = ScriptedRunner { _ in result(0) }
        _ = try await fx.ssh(runner).run(.isServiceActive("x"), timeout: .seconds(5))
        #expect(runner.calls.count == 1)
        // Source check: the file is only ever passed to lstat.
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/NidoCore/Guest/GuestSSH.swift"), encoding: .utf8)
        #expect(!source.contains("contentsOf: URL(fileURLWithPath: identity"))
        #expect(source.contains("lstat(identity"))
    }

    @Test func missingKeyMapsToKeyUnavailable() async throws {
        let fx = try GuestFixture(withKey: false); defer { fx.cleanup() }
        let runner = ScriptedRunner { _ in result(0) }
        await #expect(throws: GuestSSHError.keyUnavailable(fx.privateKeyPath)) {
            _ = try await fx.ssh(runner).run(.installGuestTools, timeout: .seconds(5))
        }
        #expect(runner.calls.isEmpty)
        #expect(GuestSSHError.keyUnavailable("/k/id").errorDescription
            == "la chiave /k/id non è disponibile o non è autorizzata nella VM: se ha una passphrase aggiungila all'agente (ssh-add) o apri il Terminale")
    }

    @Test func passphraseWithoutAgentMapsToKeyUnavailable() async throws {
        let fx = try GuestFixture(); defer { fx.cleanup() }
        let runner = ScriptedRunner { _ in result(255, err: "nido@192.168.64.9: Permission denied (publickey).\n") }
        await #expect(throws: GuestSSHError.keyUnavailable(fx.privateKeyPath)) {
            _ = try await fx.ssh(runner).run(.isServiceActive("x"), timeout: .seconds(5))
        }
    }

    @Test func hostKeyChangedDetected() async throws {
        let fx = try GuestFixture(); defer { fx.cleanup() }
        let runner = ScriptedRunner { _ in
            result(255, err: "@@@ WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED! @@@\nHost key verification failed.\n")
        }
        await #expect(throws: GuestSSHError.hostKeyChanged) {
            _ = try await fx.ssh(runner).run(.isServiceActive("x"), timeout: .seconds(5))
        }
    }

    @Test func unreachableTimeoutAndCommandFailure() async throws {
        let fx = try GuestFixture(); defer { fx.cleanup() }
        let down = ScriptedRunner { _ in result(255, err: "ssh: connect to host 192.168.64.9 port 22: Operation timed out\n") }
        await #expect(throws: GuestSSHError.unreachable) {
            _ = try await fx.ssh(down).run(.isServiceActive("x"), timeout: .seconds(5))
        }
        let slow = ScriptedRunner { _ in result(15, timedOut: true) }
        await #expect(throws: GuestSSHError.timeout) {
            _ = try await fx.ssh(slow).run(.isServiceActive("x"), timeout: .seconds(1))
        }
        let failing = ScriptedRunner { _ in result(4, err: "boom\u{1B}[31m red\u{7}\nsecond line\n") }
        await #expect(throws: GuestSSHError.commandFailed(code: 4, stderrTail: "boom [31m red second line")) {
            _ = try await fx.ssh(failing).run(.isServiceActive("x"), timeout: .seconds(5))
        }
    }

    @Test func stderrTailIsBoundedAndHasNoControlCharacters() {
        let long = String(repeating: "x", count: 5000) + "\u{0}\u{1B}end"
        let tail = GuestSSH.sanitize(long, limit: GuestSSH.maxStderrTail)
        #expect(tail.count <= GuestSSH.maxStderrTail)
        #expect(tail.hasSuffix("x end"))
        #expect(!tail.unicodeScalars.contains { $0.value < 0x20 })
    }

    @Test func modelNameValidated() throws {
        #expect(try GuestCommand.validateModelName("llama3.2:1b") == "llama3.2:1b")
        #expect(try GuestCommand.validateModelName("library/qwen2.5-coder:7b") == "library/qwen2.5-coder:7b")
        for bad in ["a;b", "a b", "-rf", "", "a$(x)", "a\nb", "a'b", "é", String(repeating: "a", count: 129)] {
            #expect(throws: GuestSSHError.invalidIdentifier(bad)) { try GuestCommand.validateModelName(bad) }
        }
        #expect(try GuestCommand.ollama(.pull(model: "llama3.2:1b")).remoteCommand()
            == "'sudo' '-n' '/opt/nido-guest-tools/bin/nido-provision' 'model-pull' 'llama3.2:1b'")
        #expect(throws: GuestSSHError.invalidIdentifier("-rf")) { try GuestCommand.ollama(.remove(model: "-rf")).remoteCommand() }
        #expect(try GuestCommand.chat.remoteCommand()
            == "'curl' '-sN' '--noproxy' '*' '--max-time' '900' '--data-binary' '@-' 'http://127.0.0.1:11434/api/chat'")
        #expect(try GuestCommand.readProvisionLog.remoteCommand() == "'sudo' '-n' '/opt/nido-guest-tools/bin/nido-provision' 'log'")
    }

    @Test func runnerErrorIsLaunchFailedNotUnreachable() async throws {
        let fx = try GuestFixture(); defer { fx.cleanup() }
        final class Broken: ProcessRunner, @unchecked Sendable {
            func run(executable: URL, arguments: [String]) throws -> ProcessResult { throw NidoError.pidUnknown }
            func run(executable: URL, arguments: [String], stdin: Data?, timeout: TimeInterval, maxOutput: Int) throws -> ProcessResult {
                throw NidoError.processFailed(executable: executable.path, status: -1)
            }
        }
        await #expect(throws: GuestSSHError.launchFailed("processFailed(executable: \"/usr/bin/ssh\", status: -1)")) {
            _ = try await fx.ssh(Broken()).run(.isServiceActive("x"), timeout: .seconds(5))
        }
    }

    @Test func keyPathWithPercentIsRefused() {
        #expect(throws: NidoError.unsafePath("/k/id%h")) {
            _ = try SSHArguments.background(
                identity: "/k/id%h", endpoint: SSHEndpoint(host: "1.1.1.1", port: 22), vmID: UUID(), knownHosts: URL(fileURLWithPath: "/tmp/kh"), remoteCommand: "x")
        }
    }

    @Test func noRecordedKeyIsReported() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nido-gssh-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let config = VMConfig(
            id: UUID(), name: try VMName("nk"), guest: .linux, cpuCount: 2, memoryBytes: 4 << 30,
            diskBytes: 20 << 30, macAddress: "02:00:00:00:00:02")
        let bundle = try VMBundle.create(config: config, paths: NidoPaths(root: root))
        let ssh = GuestSSH(bundle: bundle, config: config, runner: ScriptedRunner { _ in result(0) }, resolveSSH: { _ in SSHEndpoint(host: "1.1.1.1", port: 22) })
        await #expect(throws: GuestSSHError.keyNotConfigured) {
            _ = try await ssh.run(.installGuestTools, timeout: .seconds(1))
        }
    }

    // MARK: - The real runner

    /// `onLaunch` gets the pid of the child it started, before the child's output is read.
    @Test func systemRunnerReportsTheLaunchedPID() throws {
        let launched = Mutex<[pid_t]>([])
        let out = try SystemProcessRunner().run(
            executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "echo $$"], stdin: nil, timeout: 10,
            maxOutput: 1 << 10, cancellation: nil, environment: [:],
            onLaunch: { pid in launched.withLock { $0.append(pid) } }, onStdout: nil)
        let printed = String(decoding: out.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(launched.withLock { $0 }.map(String.init) == [printed])
        // Not started: never called.
        #expect(throws: (any Error).self) {
            _ = try SystemProcessRunner().run(
                executable: URL(fileURLWithPath: "/nonexistent/tool"), arguments: [], stdin: nil, timeout: 10,
                maxOutput: 1 << 10, cancellation: nil, environment: [:],
                onLaunch: { pid in launched.withLock { $0.append(pid) } }, onStdout: nil)
        }
        #expect(launched.withLock { $0 }.count == 1)
    }

    @Test func systemRunnerFeedsStdinAndKillsOnTimeout() throws {
        let runner = SystemProcessRunner()
        let echoed = try runner.run(
            executable: URL(fileURLWithPath: "/bin/cat"), arguments: [], stdin: Data("ciao".utf8),
            timeout: 5, maxOutput: 1 << 20)
        #expect(echoed.status == 0 && String(decoding: echoed.stdout, as: UTF8.self) == "ciao" && !echoed.timedOut)
        let started = Date()
        let slow = try runner.run(
            executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], stdin: nil,
            timeout: 0.5, maxOutput: 1024)
        #expect(slow.timedOut)
        #expect(Date().timeIntervalSince(started) < 10)
        let capped = try runner.run(
            executable: URL(fileURLWithPath: "/usr/bin/yes"), arguments: [], stdin: nil,
            timeout: 0.5, maxOutput: 100)
        #expect(capped.stdout.count == 100)
    }
}

@Suite struct GuestKeyAdoptionTests {
    private func key(_ seed: UInt8) -> String {
        var blob = Data()
        let type = Array("ssh-ed25519".utf8)
        withUnsafeBytes(of: UInt32(type.count).bigEndian) { blob.append(contentsOf: $0) }
        blob.append(contentsOf: type)
        withUnsafeBytes(of: UInt32(32).bigEndian) { blob.append(contentsOf: $0) }
        blob.append(Data(repeating: seed, count: 32))
        return "ssh-ed25519 \(blob.base64EncodedString())"
    }

    private func vm(authorized: String, in fx: GuestFixture) throws {
        let userData = CloudInitSeed.userData(username: "nido", publicKey: authorized)
        try CloudInitSeed.buildISO(
            at: fx.bundle.seedURL, userData: userData,
            metaData: "instance-id: x\nlocal-hostname: gs\n", runner: SystemProcessRunner())
    }

    @Test func defaultKeyAdoptedOnlyIfMatches() throws {
        let fx = try GuestFixture(); defer { fx.cleanup() }
        var config = try fx.bundle.readConfig()
        config.sshPublicKeyPath = nil
        try fx.bundle.writeConfig(config)
        try vm(authorized: key(1), in: fx)
        let defaultKey = fx.keyDir.appendingPathComponent("id_ed25519.pub")

        // A different key: nothing is recorded.
        try Data((key(2) + " me@mac\n").utf8).write(to: defaultKey)
        #expect(try GuestSSH.adoptDefaultKey(bundle: fx.bundle, defaultKey: defaultKey) == nil)
        #expect(try fx.bundle.readConfig().sshPublicKeyPath == nil)

        // No default key at all.
        try FileManager.default.removeItem(at: defaultKey)
        #expect(try GuestSSH.adoptDefaultKey(bundle: fx.bundle, defaultKey: defaultKey) == nil)

        // The matching key (the comment does not matter): recorded.
        try Data((key(1) + " me@mac\n").utf8).write(to: defaultKey)
        #expect(try GuestSSH.adoptDefaultKey(bundle: fx.bundle, defaultKey: defaultKey) == defaultKey.path)
        #expect(try fx.bundle.readConfig().sshPublicKeyPath == defaultKey.path)
    }

    @Test func adoptionKeepsAConcurrentConfigChange() throws {
        let fx = try GuestFixture(); defer { fx.cleanup() }
        var config = try fx.bundle.readConfig()
        config.sshPublicKeyPath = nil
        try fx.bundle.writeConfig(config)
        try vm(authorized: key(1), in: fx)
        let defaultKey = fx.keyDir.appendingPathComponent("id_ed25519.pub")
        try Data((key(1) + "\n").utf8).write(to: defaultKey)
        // The bundle value passed in is stale on purpose: only a fresh read keeps the new field.
        try fx.bundle.updateConfig { $0.cpuCount = 7 }
        #expect(try GuestSSH.adoptDefaultKey(bundle: fx.bundle, defaultKey: defaultKey) == defaultKey.path)
        let after = try fx.bundle.readConfig()
        #expect(after.cpuCount == 7 && after.sshPublicKeyPath == defaultKey.path)
    }

    @Test func alreadyRecordedKeyIsKept() throws {
        let fx = try GuestFixture(); defer { fx.cleanup() }
        let defaultKey = fx.keyDir.appendingPathComponent("id_ed25519.pub")
        #expect(try GuestSSH.adoptDefaultKey(bundle: fx.bundle, defaultKey: defaultKey) == fx.publicKeyPath)
    }
}

// MARK: - Authorizing Nido's key with the guest password

extension GuestSSHTests {
    static let nidoKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOO97YvP4YWGQwUFq+UeOnyDKkD29RZ8VdmeuGgPzeS6"
    static let askpass = URL(fileURLWithPath: "/Applications/Nido.app/Contents/Helpers/nido")

    /// A macOS guest whose bundle holds Nido's key (`authorized_key.pub`).
    private func macFixture() throws -> MacGuestFixture {
        let fx = try MacGuestFixture(sshUser: "agente", withKey: false)
        try Data((Self.nidoKey + " nido\n").utf8).write(to: fx.bundle.authorizedKeyURL)
        return fx
    }

    /// `ssh` whose askpass socket answers the test process itself (the real peer check wants the
    /// askpass child of an ssh started by this process).
    static func trusting(_ ssh: GuestSSH) -> GuestSSH {
        var ssh = ssh
        ssh.askpassPeerCheck = { _, _ in true }
        return ssh
    }

    @Test func authorizeAnswersOnlyTheAskpassOfItsSSH() async throws {
        let fx = try macFixture(); defer { fx.cleanup() }
        // The default check: a fetch from this test process (no child of an ssh) gets nothing,
        // so a refused login is not reported as a wrong password.
        let fetched = Mutex<Bool>(false)
        let runner = ScriptedRunner { call in
            let data = try? Askpass.fetch(socketPath: call.environment[Askpass.socketVariable] ?? "")
            fetched.withLock { $0 = data != nil }
            return result(255, err: "agente@192.168.64.9: Permission denied (keyboard-interactive).")
        }
        let error = await #expect(throws: GuestSSHError.self) {
            try await fx.ssh(runner).authorizeNidoKey(password: try #require(GuestPassword("pw")), askpass: Self.askpass)
        }
        #expect(fetched.withLock { $0 } == false)
        #expect(error == .passwordNotDelivered)
    }

    /// The peer check gets the pid of the ssh this call launched (the runner's `onLaunch`), so
    /// only that ssh's askpass child can pass the real check.
    @Test func authorizeBindsTheCheckToItsSSH() async throws {
        let fx = try macFixture(); defer { fx.cleanup() }
        let seen = Mutex<[pid_t?]>([])
        let runner = ScriptedRunner(launchPID: 4242) { call in
            _ = try? Askpass.fetch(socketPath: call.environment[Askpass.socketVariable] ?? "")
            return result(0)
        }
        var ssh = try fx.ssh(runner)
        ssh.askpassPeerCheck = { _, launched in
            seen.withLock { $0.append(launched) }
            return launched == 4242
        }
        try await ssh.authorizeNidoKey(password: try #require(GuestPassword("pw")), askpass: Self.askpass)
        #expect(seen.withLock { $0 } == [4242])
    }

    /// The fallback after `interpret` never names a key (none is used): not the askpass path, not
    /// an empty one.
    @Test func authorizeFailureNeverNamesAKey() async throws {
        let fx = try macFixture(); defer { fx.cleanup() }
        for stderr in [
            "Load key \"/x\": invalid format", "no such identity: /x", "Permission denied (publickey).",
            "Too many authentication failures",
        ] {
            let runner = ScriptedRunner { _ in result(255, err: stderr) }
            do {
                try await Self.trusting(fx.ssh(runner)).authorizeNidoKey(
                    password: try #require(GuestPassword("pw")), askpass: Self.askpass)
                Issue.record("expected an error")
            } catch let error as GuestSSHError {
                if case .keyUnavailable = error { Issue.record("\(stderr): \(error)") }
            }
        }
    }

    /// An invalid account name in `config.json` is refused as itself before ssh runs, not as
    /// "unreachable".
    @Test func authorizeKeepsTheAccountNameError() async throws {
        let fx = try macFixture(); defer { fx.cleanup() }
        try fx.bundle.updateConfig { $0.sshUser = "-oProxyCommand=x" }
        let runner = ScriptedRunner { _ in result(0) }
        let error = await #expect(throws: GuestSSHError.self) {
            try await fx.ssh(runner).authorizeNidoKey(password: try #require(GuestPassword("pw")), askpass: Self.askpass)
        }
        #expect(error == .invalidIdentifier("-oProxyCommand=x"))
        #expect(runner.calls.isEmpty)
    }

    /// `SSHArguments.passwordOnce` refusing the arguments (a `known_hosts` path ssh would read
    /// differently) keeps its own error, not "unreachable", and runs nothing.
    @Test func authorizeKeepsTheArgumentsError() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nido-pct%\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let config = VMConfig(
            id: UUID(), name: try VMName("mg"), guest: .macos, cpuCount: 2, memoryBytes: 4 << 30,
            diskBytes: 20 << 30, macAddress: "02:00:00:00:00:02", sshUser: "agente")
        let bundle = try VMBundle.create(config: config, paths: NidoPaths(root: root.appendingPathComponent("VMs")))
        try Data((Self.nidoKey + " nido\n").utf8).write(to: bundle.authorizedKeyURL)
        let runner = ScriptedRunner { _ in result(0) }
        var ssh = GuestSSH(
            bundle: bundle, config: config, runner: runner,
            resolveSSH: { _ in SSHEndpoint(host: "192.168.64.9", port: 22) })
        ssh.askpassPeerCheck = { _, _ in true }
        do {
            try await ssh.authorizeNidoKey(password: try #require(GuestPassword("pw")), askpass: Self.askpass)
            Issue.record("expected an error")
        } catch {
            #expect(error as? NidoError == .unsafePath(bundle.knownHostsURL.path), "\(error)")
        }
        #expect(runner.calls.isEmpty)
    }

    @Test func authorizeRefusesALinuxGuest() async throws {
        let fx = try GuestFixture(); defer { fx.cleanup() }
        let runner = ScriptedRunner { _ in result(0) }
        let error = await #expect(throws: GuestSSHError.self) {
            try await fx.ssh(runner).authorizeNidoKey(password: try #require(GuestPassword("pw")), askpass: Self.askpass)
        }
        #expect(error == .macGuestOnly)
        #expect(error?.errorDescription == "la chiave di Nido si può autorizzare con una password solo in una VM macOS")
        #expect(runner.calls.isEmpty)
    }

    @Test func authorizeKeepsTheKnownHostsError() async throws {
        let fx = try macFixture(); defer { fx.cleanup() }
        // A symlink in place of the bundle's known_hosts: refused as it is, not "unreachable".
        let target = fx.root.appendingPathComponent("elsewhere")
        try Data().write(to: target)
        try FileManager.default.createSymbolicLink(at: fx.bundle.knownHostsURL, withDestinationURL: target)
        let runner = ScriptedRunner { _ in result(0) }
        do {
            try await fx.ssh(runner).authorizeNidoKey(password: try #require(GuestPassword("pw")), askpass: Self.askpass)
            Issue.record("expected an error")
        } catch {
            #expect(!(error is GuestSSHError), "\(error)")
        }
        #expect(runner.calls.isEmpty)
    }

    @Test func authorizeOtherSSHFailuresCarryStderrNotAKey() async throws {
        let fx = try macFixture(); defer { fx.cleanup() }
        let runner = ScriptedRunner { _ in
            result(255, err: "Received disconnect from 192.168.64.9 port 22:2: Too many authentication failures\n")
        }
        let error = await #expect(throws: GuestSSHError.self) {
            try await fx.ssh(runner).authorizeNidoKey(password: try #require(GuestPassword("pw")), askpass: Self.askpass)
        }
        #expect(error == .commandFailed(
            code: 255, stderrTail: "Received disconnect from 192.168.64.9 port 22:2: Too many authentication failures"))
    }

    @Test func authorizeUsesAskpassNotArgv() async throws {
        let fx = try macFixture(); defer { fx.cleanup() }
        let password = try #require(GuestPassword("pässwörd-42"))
        // What ssh's askpass child would read: the runner fetches it while "ssh" runs.
        let fetched = Mutex<Data?>(nil)
        let runner = ScriptedRunner { call in
            if let path = call.environment[Askpass.socketVariable] {
                fetched.withLock { $0 = try? Askpass.fetch(socketPath: path) }
            }
            return result(0)
        }
        try await Self.trusting(fx.ssh(runner)).authorizeNidoKey(password: password, askpass: Self.askpass)

        let call = try #require(runner.calls.first)
        #expect(runner.calls.count == 1)
        #expect(call.executable == "/usr/bin/ssh")
        #expect(call.timeout == 30)
        #expect(call.arguments.contains("PubkeyAuthentication=no"))
        #expect(call.arguments.contains("NumberOfPasswordPrompts=1"))
        #expect(call.arguments.contains("BatchMode=no"))
        #expect(call.arguments.contains("PreferredAuthentications=keyboard-interactive,password"))
        #expect(!call.arguments.contains("BatchMode=yes"))
        #expect(!call.arguments.contains("-i"))
        #expect(call.arguments.contains("agente@192.168.64.9"))
        #expect(call.arguments.last == (try GuestCommand.authorizeNidoKey.remoteCommand()))
        // The password is on no command line and in no environment value.
        #expect(!call.arguments.contains { $0.contains(password.value) })
        #expect(!call.environment.values.contains { $0.contains(password.value) })
        #expect(call.environment["SSH_ASKPASS"] == Self.askpass.path)
        #expect(call.environment["SSH_ASKPASS_REQUIRE"] == "force")
        #expect(call.environment[Askpass.modeVariable] == "1")
        #expect(call.environment[Askpass.socketVariable]?.hasPrefix(Askpass.defaultDirectory.path + "/") == true)
        #expect(call.environment["SSH_AUTH_SOCK"] == nil)
        #expect(call.stdin == Data((Self.nidoKey + "\n").utf8))
        // The askpass got the password once, and the socket is gone afterwards.
        #expect(fetched.withLock { $0 } == Data(password.value.utf8))
        let socket = try #require(call.environment[Askpass.socketVariable])
        #expect(!FileManager.default.fileExists(atPath: socket))
    }

    @Test func authorizeRejectedPassword() async throws {
        let fx = try macFixture(); defer { fx.cleanup() }
        // ssh's askpass fetched the password, then the guest refused it.
        let runner = ScriptedRunner { call in
            _ = try? Askpass.fetch(socketPath: call.environment[Askpass.socketVariable] ?? "")
            return result(255, err: "agente@192.168.64.9: Permission denied (keyboard-interactive).")
        }
        let error = await #expect(throws: GuestSSHError.self) {
            try await Self.trusting(fx.ssh(runner)).authorizeNidoKey(password: try #require(GuestPassword("wrong")), askpass: Self.askpass)
        }
        #expect(error == .passwordRejected(user: "agente", vm: "mg"))
        #expect(error?.errorDescription == "la password di agente in mg è stata rifiutata")
    }

    @Test func authorizeRefusedWithoutThePasswordIsNotAWrongPassword() async throws {
        let fx = try macFixture(); defer { fx.cleanup() }
        // The askpass never fetched (it failed, or the guest asked for no password).
        let runner = ScriptedRunner { _ in result(255, err: "agente@192.168.64.9: Permission denied (publickey).") }
        let error = await #expect(throws: GuestSSHError.self) {
            try await fx.ssh(runner).authorizeNidoKey(password: try #require(GuestPassword("pw")), askpass: Self.askpass)
        }
        #expect(error == .passwordNotDelivered)
        #expect(error?.errorDescription == "Nido non è riuscito a passare la password a ssh")
    }

    @Test func authorizeOtherFailuresKeepTheirMeaning() async throws {
        let fx = try macFixture(); defer { fx.cleanup() }
        let runner = ScriptedRunner { _ in result(255, err: "ssh: connect to host 192.168.64.9 port 22: Connection refused") }
        let error = await #expect(throws: GuestSSHError.self) {
            try await fx.ssh(runner).authorizeNidoKey(password: try #require(GuestPassword("pw")), askpass: Self.askpass)
        }
        #expect(error == .unreachable)
    }

    @Test func authorizeNeedsAValidNidoKey() async throws {
        let fx = try MacGuestFixture(sshUser: "agente", withKey: false); defer { fx.cleanup() }
        let runner = ScriptedRunner { _ in result(0) }
        // No `authorized_key.pub`.
        await #expect(throws: (any Error).self) {
            try await fx.ssh(runner).authorizeNidoKey(password: try #require(GuestPassword("pw")), askpass: Self.askpass)
        }
        // Not a public key.
        try Data("ssh-ed25519 not-base64!\n".utf8).write(to: fx.bundle.authorizedKeyURL)
        await #expect(throws: (any Error).self) {
            try await fx.ssh(runner).authorizeNidoKey(password: try #require(GuestPassword("pw")), askpass: Self.askpass)
        }
        #expect(runner.calls.isEmpty)
    }

    @Test func otherCommandsStayKeyOnly() async throws {
        let fx = try macFixture(); defer { fx.cleanup() }
        let runner = ScriptedRunner { _ in result(0) }
        _ = try await fx.ssh(runner).run(.readMacLoginState, timeout: .seconds(5))
        let call = try #require(runner.calls.first)
        #expect(call.arguments.contains("BatchMode=yes"))
        #expect(!call.arguments.contains("PubkeyAuthentication=no"))
        #expect(!call.arguments.contains { $0.hasPrefix("NumberOfPasswordPrompts") })
        #expect(call.environment["SSH_ASKPASS"] == nil)
        #expect(call.environment[Askpass.socketVariable] == nil)
    }

    @Test func passwordOnceArguments() throws {
        let id = UUID()
        let knownHosts = URL(fileURLWithPath: "/tmp/kh")
        let args = try SSHArguments.passwordOnce(
            endpoint: SSHEndpoint(host: "192.168.64.9", port: 2222), vmID: id, knownHosts: knownHosts,
            remoteCommand: "'true'", user: "agente")
        let expected = [
            "ssh", "-F", "/dev/null", "-o", "BatchMode=no", "-o", "PubkeyAuthentication=no",
            "-o", "PreferredAuthentications=keyboard-interactive,password",
            "-o", "NumberOfPasswordPrompts=1",
            "-o", "KbdInteractiveAuthentication=yes", "-o", "PasswordAuthentication=yes",
            "-o", "ConnectTimeout=5", "-o", "RemoteCommand=none", "-o", "RequestTTY=no",
            "-o", "ControlMaster=no", "-o", "ControlPath=none",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "HostKeyAlias=nido-\(id.uuidString.lowercased())",
            "-o", "UserKnownHostsFile=\"/tmp/kh\"",
            "-o", "GlobalKnownHostsFile=/dev/null", "-o", "ForwardAgent=no", "-o", "ForwardX11=no",
            "-o", "ClearAllForwardings=yes", "-o", "Tunnel=no", "-o", "PermitRemoteOpen=none",
            "-p", "2222", "agente@192.168.64.9", "--", "'true'",
        ]
        #expect(args == expected)
        #expect(throws: (any Error).self) {
            _ = try SSHArguments.passwordOnce(
                endpoint: SSHEndpoint(host: "h", port: 22), vmID: id, knownHosts: knownHosts,
                remoteCommand: "'true'", user: "-oProxyCommand=x")
        }
    }

    @Test func authorizeScriptIsIdempotent() throws {
        #expect(try GuestCommand.authorizeNidoKey.argv() == ["/bin/sh", "-c", GuestCommand.authorizeKeyScript])
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("nido-auth-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let runner = SystemProcessRunner()
        func run(_ input: String) throws -> ProcessResult {
            try runner.run(
                executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", GuestCommand.authorizeKeyScript],
                stdin: Data(input.utf8), timeout: 10, maxOutput: 1 << 16, cancellation: nil,
                environment: ["HOME": home.path], onStdout: nil)
        }
        for _ in 0..<2 {
            let out = try run(Self.nidoKey + "\n")
            #expect(out.status == 0)
            #expect(out.stdout.isEmpty)
            #expect(out.stderr.isEmpty)
        }
        let ssh = home.appendingPathComponent(".ssh")
        let keys = ssh.appendingPathComponent("authorized_keys")
        #expect(try String(contentsOf: keys, encoding: .utf8) == Self.nidoKey + "\n")
        var info = stat()
        #expect(lstat(ssh.path, &info) == 0 && info.st_mode & 0o7777 == 0o700)
        #expect(lstat(keys.path, &info) == 0 && info.st_mode & 0o7777 == 0o600)

        // An existing file without a final newline keeps its last line whole.
        try Data("ssh-ed25519 AAAAother".utf8).write(to: keys)
        #expect(try run(Self.nidoKey).status == 0)
        #expect(try String(contentsOf: keys, encoding: .utf8) == "ssh-ed25519 AAAAother\n" + Self.nidoKey + "\n")
        #expect(try run(Self.nidoKey + "\n").status == 0)
        #expect(try String(contentsOf: keys, encoding: .utf8) == "ssh-ed25519 AAAAother\n" + Self.nidoKey + "\n")

        // No key on stdin: a failure, nothing appended.
        #expect(try run("").status != 0)
        #expect(try String(contentsOf: keys, encoding: .utf8) == "ssh-ed25519 AAAAother\n" + Self.nidoKey + "\n")
    }
}
