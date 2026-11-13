// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import NidoCore

private let body = "AAAAC3NzaC1lZDI1NTE5AAAAIOO97YvP4YWGQwUFq+UeOnyDKkD29RZ8VdmeuGgPzeS6"
private let validKey = "ssh-ed25519 \(body)"

private final class FakeRunner: ProcessRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [(URL, [String])] = []
    let status: Int32
    init(status: Int32 = 0) { self.status = status }
    var calls: [(URL, [String])] { lock.withLock { _calls } }
    func run(executable: URL, arguments: [String]) throws -> ProcessResult {
        lock.withLock { _calls.append((executable, arguments)) }
        if status == 0, arguments.count > 6 {
            FileManager.default.createFile(
                atPath: arguments[6], contents: Data("iso".utf8), attributes: [.posixPermissions: 0o644])
        }
        return ProcessResult(status: status, stdout: Data(), stderr: Data())
    }
}

@Suite(.italian) struct CloudInitSeedTests {
    @Test func acceptsKeyAndDropsComment() throws {
        #expect(try CloudInitSeed.validatePublicKey("\(validKey) user@host") == validKey)
        #expect(try CloudInitSeed.validatePublicKey("  \(validKey)\n") == validKey)
        #expect(try CloudInitSeed.validatePublicKey(validKey) == validKey)
        #expect(try CloudInitSeed.validatePublicKey("\(validKey) My Laptop Key") == validKey)
        #expect(try CloudInitSeed.validatePublicKey("ssh-ed25519\t\(body)\tcomment with\ttabs") == validKey)
    }

    @Test(arguments: [
        "ssh-ed25519 \(body)\nssh-ed25519 \(body)",
        "\(validKey) c\r\nx",
        "\(validKey) c\rx",
        "\(validKey) c\nx",
        "\(validKey)\r\nssh-ed25519 \(body)",
        "ssh-dss \(body)",
        "ssh-ed25519 not*base64!",
        "ssh-ed25519",
        "",
        "ssh-ed25519 ",
        "ssh-rsa \(body)",  // type/body mismatch
        "ssh-ed25519 AAAA",  // too short for wire format
        "ssh-ed25519 \(body)=x",
    ])
    func rejectsInvalidKeys(_ key: String) {
        #expect(throws: NidoError.invalidPublicKey) { try CloudInitSeed.validatePublicKey(key) }
    }

    @Test func userDataIsKeyOnly() {
        let ud = CloudInitSeed.userData(username: "nido", publicKey: validKey)
        #expect(ud.hasPrefix("#cloud-config"))
        #expect(ud.contains("ssh_pwauth: false"))
        #expect(ud.contains("lock_passwd: true"))
        #expect(ud.contains("disable_root: true"))
        #expect(ud.contains("\"\(validKey)\""))
        #expect(!ud.contains("hostname"))
        for bad in ["password", "chpasswd", "plain_text_passwd", "hashed_passwd"] {
            #expect(!ud.contains(bad))
        }
        #expect(ud.range(of: #"^\s*passwd:"#, options: .regularExpression) == nil)
        let re = try! Regex(#"(?m)^\s*passwd:"#)
        #expect(ud.firstMatch(of: re) == nil)
    }

    /// M3b: a first boot cut short (the app quit while cloud-init replaced the SSH host
    /// keys) must not leave the guest without SSH. Every boot, before sshd, `ssh-keygen -A`
    /// creates the host keys that are missing (it never replaces one that exists). Constants only,
    /// in every new Linux seed (with or without a profile) and in every clone's.
    @Test func seedRegeneratesMissingHostKeys() throws {
        let command = CloudInitSeed.regenerateHostKeysBootCommand
        #expect(command == "[sh, -c, 'command -v ssh-keygen >/dev/null 2>&1 || exit 0; ssh-keygen -A']")
        // A plain `bootcmd` entry (no `cloud-init-per`): it runs at every boot.
        #expect(!command.contains("cloud-init-per"))
        for profile in [ProvisioningProfile.empty, .standard] {
            let text = CloudInitSeed.userData(username: "nido", publicKey: validKey, profile: profile)
            let doc = try MiniYAML.parse(text)
            let items = try #require(doc["bootcmd"]?.items)
            #expect(items.count == 1)
            #expect(items.first?.items?.map(\.text) == ["sh", "-c", "command -v ssh-keygen >/dev/null 2>&1 || exit 0; ssh-keygen -A"])
            #expect(text.components(separatedBy: command).count == 2)
        }
        // Clones (also of a VM made before this change) and clones of templates get it too.
        let old = "#cloud-config\nusers: []\n"
        for clone in [
            CloudInitSeed.userDataForClone(old),
            CloudInitSeed.userDataForClone(CloudInitSeed.userData(username: "nido", publicKey: validKey)),
            CloudInitSeed.userDataForTemplateClone(username: "nido", publicKey: validKey),
        ] {
            let items = try #require(try MiniYAML.parse(clone)["bootcmd"]?.items)
            #expect(items.count == 2)
            #expect(clone.components(separatedBy: command).count == 2)
            #expect(clone.components(separatedBy: CloudInitSeed.newMachineIDBootCommand).count == 2)
        }
    }

    @Test func metaDataNormalizesHostname() throws {
        let id = UUID()
        let md = CloudInitSeed.metaData(instanceID: id, hostname: try VMName("Dev_VM.2"))
        #expect(md == "instance-id: \(id.uuidString.lowercased())\nlocal-hostname: dev-vm-2\n")
    }

    private func tempOutput() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("nido-seed-\(UUID().uuidString).iso")
    }

    @Test func buildISOInvokesHdiutilExactly() throws {
        let runner = FakeRunner()
        let out = tempOutput()
        defer { try? FileManager.default.removeItem(at: out) }
        try CloudInitSeed.buildISO(at: out, userData: "u", metaData: "m", runner: runner)
        let mode = (try FileManager.default.attributesOfItem(atPath: out.path)[.posixPermissions] as! NSNumber).intValue
        #expect(mode == 0o600)
        let call = try #require(runner.calls.first)
        #expect(call.0.path == "/usr/bin/hdiutil")
        let args = call.1
        #expect(args.count == 8)
        #expect(Array(args.prefix(6)) == ["makehybrid", "-iso", "-joliet", "-default-volume-name", "cidata", "-o"])
        #expect(args[6] == out.path)
        // temp dir removed afterwards
        #expect(!FileManager.default.fileExists(atPath: args[7]))
    }

    @Test func buildISOStagesFilesPrivately() throws {
        final class Inspector: ProcessRunner, @unchecked Sendable {
            nonisolated(unsafe) var seen: [String: (String, Int)] = [:]
            nonisolated(unsafe) var dirMode = 0
            func run(executable: URL, arguments: [String]) throws -> ProcessResult {
                let dir = arguments[7]
                let fm = FileManager.default
                dirMode = (try fm.attributesOfItem(atPath: dir)[.posixPermissions] as! NSNumber).intValue
                for f in ["user-data", "meta-data"] {
                    let p = dir + "/" + f
                    seen[f] = (
                        try String(contentsOfFile: p, encoding: .utf8),
                        (try fm.attributesOfItem(atPath: p)[.posixPermissions] as! NSNumber).intValue)
                }
                fm.createFile(atPath: arguments[6], contents: Data("iso".utf8), attributes: [.posixPermissions: 0o644])
                return ProcessResult(status: 0, stdout: Data(), stderr: Data())
            }
        }
        let r = Inspector()
        let out = tempOutput()
        defer { try? FileManager.default.removeItem(at: out) }
        try CloudInitSeed.buildISO(at: out, userData: "UD", metaData: "MD", runner: r)
        #expect(r.dirMode == 0o700)
        #expect(r.seen["user-data"]?.0 == "UD" && r.seen["user-data"]?.1 == 0o600)
        #expect(r.seen["meta-data"]?.0 == "MD" && r.seen["meta-data"]?.1 == 0o600)
    }

    @Test func networkConfigUsesMACAsDHCPIdentifier() throws {
        let nc = try CloudInitSeed.networkConfig(macAddress: "7A:80:2E:82:30:A5")
        #expect(nc == """
            version: 2
            ethernets:
              primary:
                match:
                  macaddress: "7a:80:2e:82:30:a5"
                dhcp4: true
                dhcp-identifier: mac

            """)
    }

    @Test(arguments: ["", "7a:80:2e:82:30", "7a:80:2e:82:30:a5:00", "7a-80-2e-82-30-a5", "7a:80:2e:82:30:g5",
                      "7a:80:2e:82:30:a5\"\nversion: 1"])
    func networkConfigRejectsInvalidMAC(_ mac: String) {
        #expect(throws: NidoError.invalidResources("indirizzo MAC non valido")) {
            try CloudInitSeed.networkConfig(macAddress: mac)
        }
    }

    @Test func buildISOStagesNetworkConfigWhenGiven() throws {
        final class Inspector: ProcessRunner, @unchecked Sendable {
            nonisolated(unsafe) var files: [String] = []
            nonisolated(unsafe) var network: (String, Int)?
            func run(executable: URL, arguments: [String]) throws -> ProcessResult {
                let dir = arguments[7]
                let fm = FileManager.default
                files = try fm.contentsOfDirectory(atPath: dir).sorted()
                let p = dir + "/network-config"
                network = (
                    try String(contentsOfFile: p, encoding: .utf8),
                    (try fm.attributesOfItem(atPath: p)[.posixPermissions] as! NSNumber).intValue)
                fm.createFile(atPath: arguments[6], contents: Data("iso".utf8), attributes: [.posixPermissions: 0o644])
                return ProcessResult(status: 0, stdout: Data(), stderr: Data())
            }
        }
        let r = Inspector()
        let out = tempOutput()
        defer { try? FileManager.default.removeItem(at: out) }
        try CloudInitSeed.buildISO(at: out, userData: "UD", metaData: "MD", networkConfig: "NC", runner: r)
        #expect(r.files == ["meta-data", "network-config", "user-data"])
        #expect(r.network?.0 == "NC" && r.network?.1 == 0o600)
    }

    @Test func buildISOFailureMapsToProcessFailedAndCleansUp() {
        let runner = FakeRunner(status: 3)
        #expect(throws: NidoError.processFailed(executable: "/usr/bin/hdiutil", status: 3)) {
            try CloudInitSeed.buildISO(at: tempOutput(), userData: "u", metaData: "m", runner: runner)
        }
        if let dir = runner.calls.first?.1.last {
            #expect(!FileManager.default.fileExists(atPath: dir))
        }
    }

    @Test func buildISORefusesExistingOutput() throws {
        let out = tempOutput()
        try Data("x".utf8).write(to: out)
        defer { try? FileManager.default.removeItem(at: out) }
        let runner = FakeRunner()
        #expect(throws: NidoError.alreadyExists(out.path)) {
            try CloudInitSeed.buildISO(at: out, userData: "u", metaData: "m", runner: runner)
        }
        #expect(runner.calls.isEmpty)
    }

    @Test func systemRunnerRejectsBadExecutables() {
        let r = SystemProcessRunner()
        #expect(throws: NidoError.processFailed(executable: "relative/tool", status: -1)) {
            try r.run(executable: URL(string: "relative/tool")!, arguments: [])
        }
        #expect(throws: NidoError.processFailed(executable: "/nonexistent/tool", status: -1)) {
            try r.run(executable: URL(fileURLWithPath: "/nonexistent/tool"), arguments: [])
        }
    }

    @Test func systemRunnerCapturesLargeOutput() throws {
        let r = SystemProcessRunner()
        let big = try r.run(executable: URL(fileURLWithPath: "/usr/bin/head"), arguments: ["-c", "300000", "/dev/zero"])
        #expect(big.status == 0)
        #expect(big.stdout.count == 300000)
    }

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/hdiutil")))
    func realHdiutilBuildsISO() throws {
        let out = tempOutput()
        defer { try? FileManager.default.removeItem(at: out) }
        let ud = CloudInitSeed.userData(username: "nido", publicKey: validKey)
        let md = CloudInitSeed.metaData(instanceID: UUID(), hostname: try VMName("vm1"))
        try CloudInitSeed.buildISO(at: out, userData: ud, metaData: md, runner: SystemProcessRunner())
        let size = (try FileManager.default.attributesOfItem(atPath: out.path)[.size] as! NSNumber).intValue
        #expect(size > 0)
        let mode = (try FileManager.default.attributesOfItem(atPath: out.path)[.posixPermissions] as! NSNumber).intValue
        #expect(mode == 0o600)
    }
}
