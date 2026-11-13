// SPDX-License-Identifier: Apache-2.0
import Foundation
import Synchronization
import Testing
@testable import NidoCore

/// Records every call and answers with a scripted result.
final class ScriptedRunner: ProcessRunner, @unchecked Sendable {
    struct Call: Sendable { let executable: String; let arguments: [String]; let stdin: Data?; let timeout: TimeInterval }
    private let state = Mutex<[Call]>([])
    private let responder: @Sendable (Call) -> ProcessResult
    init(_ responder: @escaping @Sendable (Call) -> ProcessResult) { self.responder = responder }
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
