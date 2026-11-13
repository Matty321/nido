// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation
import Synchronization
import Testing
@testable import NidoCLI
@testable import NidoCore

private let validKey =
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOO97YvP4YWGQwUFq+UeOnyDKkD29RZ8VdmeuGgPzeS6"
private let gib: UInt64 = 1 << 30

private func macConfig(_ name: String, user: String? = "mattia", version: String? = "26.1") throws -> VMConfig {
    VMConfig(
        id: UUID(), name: try VMName(name), guest: .macos, cpuCount: 4, memoryBytes: 8 * gib,
        diskBytes: 64 * gib, macAddress: "02:00:00:00:00:0a", sshUser: user, osVersion: version)
}

private func linuxConfig(_ name: String) throws -> VMConfig {
    VMConfig(
        id: UUID(), name: try VMName(name), guest: .linux, cpuCount: 2, memoryBytes: 4 * gib,
        diskBytes: 20 * gib, macAddress: "02:00:00:00:00:0b")
}

/// A temporary root with a key file and an empty "IPSW" (a ZIP header is enough for the fake loader).
private struct Env {
    let tmp: URL
    let paths: NidoPaths
    let key: URL
    let ipsw: URL

    init() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("nido-tests-create-cli-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        paths = NidoPaths(root: tmp.appendingPathComponent("VMs", isDirectory: true))
        key = tmp.appendingPathComponent("k.pub")
        try (validKey + "\n").write(to: key, atomically: true, encoding: .utf8)
        ipsw = tmp.appendingPathComponent("UniversalMac_26.1_Restore.ipsw")
        try Data([0x50, 0x4B, 0x03, 0x04] + [UInt8](repeating: 0, count: 60)).write(to: ipsw)
    }

    func cleanup() { try? FileManager.default.removeItem(at: tmp) }
}

private struct FakeLoader: MacRestoreImageLoading {
    var minimumCPUCount = 2
    var minimumMemoryBytes: UInt64 = 4 << 30

    func load(_ url: URL) async throws -> LoadedMacRestoreImage {
        // Same placeholder hardware model as the core tests (NidoCoreTests.testMacHardwareModel).
        let plist: [String: Any] = [
            "DataRepresentationVersion": 1, "MinimumSupportedOS": [13, 0, 0], "PlatformVersion": 2,
        ]
        let model = (try? PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)) ?? Data()
        return LoadedMacRestoreImage(
            buildVersion: "25B78",
            operatingSystemVersion: OperatingSystemVersion(majorVersion: 26, minorVersion: 1, patchVersion: 0),
            isSupported: true,
            configuration: .init(
                hardwareModelSupported: true, hardwareModel: model,
                minimumCPUCount: minimumCPUCount, minimumMemoryBytes: minimumMemoryBytes))
    }
}

/// Reports two progress values and "installs" nothing; or waits until cancelled.
private struct FakeOSInstaller: MacOSInstalling {
    var waitsForCancel = false

    func install(
        bundle: VMBundle, config: VMConfig, ipsw: URL, progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        progress(0.42)
        if waitsForCancel {
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(10)) }
            throw CancellationError()
        }
        progress(1)
    }
}

private final class Sink: Sendable {
    let text = Mutex("")
    func write(_ s: String) { text.withLock { $0 += s } }
}

@Suite(.italian) struct CreateCommandTests {
    // MARK: - create --ipsw

    @Test func createParsesIPSWOptions() throws {
        func parse(
            image: String? = nil, imageFile: String? = nil, sshKey: String? = "/k.pub", user: String? = "mattia",
            cpus: Int? = nil, memory: String? = nil, disk: String? = nil,
            noPackages: Bool = false, noGuestTools: Bool = false
        ) throws -> MacCreateOptions {
            try CLISupport.parseMacCreateOptions(
                name: "mac", ipsw: "/x/UniversalMac.ipsw", image: image, imageFile: imageFile, sshKey: sshKey,
                user: user, cpus: cpus, memory: memory, disk: disk,
                noPackages: noPackages, noGuestTools: noGuestTools)
        }

        let defaults = try parse()
        #expect(defaults.name.rawValue == "mac")
        #expect(defaults.ipsw.path == "/x/UniversalMac.ipsw")
        #expect(defaults.sshKeyPath.path == "/k.pub")
        #expect(defaults.user == "mattia")
        #expect(defaults.cpuCount == nil && defaults.memoryBytes == nil)
        #expect(defaults.diskBytes == 64 * gib)

        let explicit = try parse(cpus: 6, memory: "12G", disk: "100G")
        #expect(explicit.cpuCount == 6 && explicit.memoryBytes == 12 * gib && explicit.diskBytes == 100 * gib)

        // --ipsw excludes the Linux sources and options.
        #expect(throws: CLIError.ipswConflict) { _ = try parse(image: "debian-13") }
        #expect(throws: CLIError.ipswConflict) { _ = try parse(imageFile: "/d.img") }
        #expect(throws: CLIError.ipswConflict) { _ = try parse(noPackages: true) }
        #expect(throws: CLIError.ipswConflict) { _ = try parse(noGuestTools: true) }
        // --user is required and validated; so is --ssh-key.
        #expect(throws: CLIError.missingUser) { _ = try parse(user: nil) }
        #expect(throws: NidoError.invalidSSHUser("Mattia")) { _ = try parse(user: "Mattia") }
        #expect(throws: NidoError.invalidSSHUser("a b")) { _ = try parse(user: "a b") }
        #expect(throws: CLIError.missingSSHKey) { _ = try parse(sshKey: nil) }
        #expect(throws: NidoError.self) { _ = try parse(memory: "lots") }

        // --user without --ipsw: the Linux account is always `nido`.
        #expect(throws: CLIError.userRequiresIPSW) {
            _ = try CLISupport.parseCreateOptions(
                name: "deb", image: "debian-13", imageFile: nil, sshKey: "/k.pub",
                cpus: 2, memory: nil, disk: "20G", user: "mattia")
        }
        #expect(CLIError.ipswConflict.errorDescription?.contains("--ipsw") == true)
    }

    @Test func macResourcesDefaultsLimitsAndMinimums() {
        // Defaults: 4 CPU, 8 GiB.
        var r = CLISupport.macResources(
            cpuCount: nil, memoryBytes: nil, minimumCPUCount: 2, minimumMemoryBytes: 4 * gib,
            hostCores: 10, maxMemoryBytes: 64 * gib)
        #expect(r.cpuCount == 4 && r.memoryBytes == 8 * gib)
        // Reduced to the host's limits.
        r = CLISupport.macResources(
            cpuCount: nil, memoryBytes: nil, minimumCPUCount: 2, minimumMemoryBytes: 4 * gib,
            hostCores: 3, maxMemoryBytes: 6 * gib)
        #expect(r.cpuCount == 3 && r.memoryBytes == 6 * gib)
        // Raised to the image's minimums.
        r = CLISupport.macResources(
            cpuCount: nil, memoryBytes: nil, minimumCPUCount: 6, minimumMemoryBytes: 12 * gib,
            hostCores: 10, maxMemoryBytes: 64 * gib)
        #expect(r.cpuCount == 6 && r.memoryBytes == 12 * gib)
        // What the user asked is kept as is (the installer refuses it if below the minimums).
        r = CLISupport.macResources(
            cpuCount: 2, memoryBytes: 3 * gib, minimumCPUCount: 4, minimumMemoryBytes: 8 * gib,
            hostCores: 10, maxMemoryBytes: 64 * gib)
        #expect(r.cpuCount == 2 && r.memoryBytes == 3 * gib)
    }

    @Test func installProgressLine() {
        let sink = Sink()
        let line = ProgressLine(write: sink.write)
        line.show(installing: "26.1", fraction: 0.4249)
        line.show(installing: "26.1", fraction: 1.7)
        line.finish()
        #expect(sink.text.withLock { $0 } == "\rInstallazione di macOS 26.1: 42 %\rInstallazione di macOS 26.1: 100 %\n")
    }

    @Test func createMacInstallsWithProgressAndFinalMessage() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let options = try CLISupport.parseMacCreateOptions(
            name: "mac", ipsw: env.ipsw.path, image: nil, imageFile: nil, sshKey: env.key.path, user: "mattia",
            cpus: nil, memory: nil, disk: "1G", noPackages: false, noGuestTools: false)
        let installer = MacInstaller(
            paths: env.paths,
            environment: .init(
                loader: FakeLoader(), availableCapacity: { _ in UInt64.max / 2 }, installer: FakeOSInstaller()))
        let sink = Sink()
        let message = try await CLISupport.createMac(
            options, paths: env.paths, installer: installer, loader: FakeLoader(),
            line: ProgressLine(write: sink.write))
        #expect(message == "VM mac installata. Aprila in Nido per completare la configurazione iniziale di macOS e attivare l'accesso da terminale.")
        #expect(sink.text.withLock { $0 }.contains("\rInstallazione di macOS 26.1: 42 %"))
        let config = try VMBundle.open(try VMName("mac"), paths: env.paths).readConfig()
        #expect(config.guest == .macos && config.sshUser == "mattia" && config.osVersion == "26.1")
        #expect(config.cpuCount == min(4, ResourceLimits.maxCPUCount()) && config.memoryBytes == 8 * gib)
        #expect(config.sshPublicKeyPath == env.key.path)
    }

    @Test func createMacCancelledLeavesNothing() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let options = try CLISupport.parseMacCreateOptions(
            name: "mac", ipsw: env.ipsw.path, image: nil, imageFile: nil, sshKey: env.key.path, user: "mattia",
            cpus: nil, memory: nil, disk: "1G", noPackages: false, noGuestTools: false)
        let installer = MacInstaller(
            paths: env.paths,
            environment: .init(
                loader: FakeLoader(), availableCapacity: { _ in UInt64.max / 2 },
                installer: FakeOSInstaller(waitsForCancel: true)))
        let task = Task {
            try await CLISupport.createMac(
                options, paths: env.paths, installer: installer, loader: FakeLoader(), line: ProgressLine { _ in })
        }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        await #expect(throws: CLIError.installCancelled) { _ = try await task.value }
        #expect(try FileManager.default.contentsOfDirectory(atPath: env.paths.root.path).isEmpty)
        #expect(CLIError.installCancelled.errorDescription == "installazione annullata: nessuna VM è stata creata")
    }

    // MARK: - start --console

    @Test func consoleFlagRefusedForMac() throws {
        #expect(throws: CLIError.macConsoleUnavailable) {
            try CLISupport.checkConsoleFlag(true, guest: .macos)
        }
        try CLISupport.checkConsoleFlag(false, guest: .macos)
        try CLISupport.checkConsoleFlag(true, guest: .linux)
        #expect(CLIError.macConsoleUnavailable.errorDescription
            == "la console seriale non esiste per le VM macOS: usa la finestra di Nido o nido ssh")
    }

    // MARK: - ssh

    @Test func sshUsesConfiguredUser() throws {
        let kh = URL(fileURLWithPath: "/b/known_hosts")
        let mac = try macConfig("mac", user: "mattia")
        let argv = try CLISupport.sshArguments(
            config: mac, endpoint: SSHEndpoint(host: "192.168.64.9", port: 22), knownHosts: kh, extra: ["-v"], probe: { _ in .open })
        #expect(argv.suffix(2) == ["mattia@192.168.64.9", "-v"])
        #expect(argv.contains("HostKeyAlias=nido-\(mac.id.uuidString.lowercased())"))

        // Linux (and a config without sshUser): `nido`, never probed.
        let linux = try linuxConfig("deb")
        let probed = Mutex(0)
        let linuxArgv = try CLISupport.sshArguments(
            config: linux, endpoint: SSHEndpoint(host: "192.168.64.3", port: 22), knownHosts: kh, extra: [],
            probe: { _ in probed.withLock { $0 += 1 }; return .refused })
        #expect(linuxArgv.last == "nido@192.168.64.3")
        #expect(probed.withLock { $0 } == 0)
        #expect(!linuxArgv.contains("ClearAllForwardings=yes"))
        // A controlled-network VM: forwards from the user's ssh config are cleared.
        var controlled = linux
        controlled.controlledNetwork = true
        let controlledArgv = try CLISupport.sshArguments(
            config: controlled, endpoint: SSHEndpoint(host: "192.168.64.3", port: 22), knownHosts: kh, extra: [], probe: { _ in .open })
        #expect(controlledArgv.contains("ClearAllForwardings=yes"))
        #expect(controlledArgv.contains("Tunnel=no"))
        #expect(controlledArgv.contains("PermitRemoteOpen=none"))
        #expect(try CLISupport.sshArguments(
            config: try macConfig("m2", user: nil), endpoint: SSHEndpoint(host: "10.0.0.1", port: 22), knownHosts: kh, extra: [],
            probe: { _ in .open }).last == "nido@10.0.0.1")

        // A user edited by hand into something ssh would read as an option is refused.
        var bad = mac
        bad.sshUser = "-oProxyCommand=x"
        #expect(throws: NidoError.invalidSSHUser("-oProxyCommand=x")) {
            _ = try CLISupport.sshArguments(config: bad, endpoint: SSHEndpoint(host: "10.0.0.1", port: 22), knownHosts: kh, extra: [], probe: { _ in .open })
        }
    }

    /// `nido ssh` offers the key the VM was created with, not only the user's default keys.
    @Test func sshUsesRecordedKey() throws {
        let kh = URL(fileURLWithPath: "/b/known_hosts")
        let endpoint = SSHEndpoint(host: "192.168.64.3", port: 22)
        var linux = try linuxConfig("deb")
        linux.sshPublicKeyPath = "/k/nido_key.pub"

        // Private key next to the public one: that file.
        let argv = try CLISupport.sshArguments(
            config: linux, endpoint: endpoint, knownHosts: kh, extra: ["-v"], probe: { _ in .open },
            fileExists: { _ in true })
        #expect(Array(argv.prefix(5)) == ["ssh", "-i", "/k/nido_key", "-o", "IdentitiesOnly=yes"])
        #expect(argv.suffix(2) == ["nido@192.168.64.3", "-v"])

        // Only the public key (the private one in an agent): the `.pub` file.
        let agentArgv = try CLISupport.sshArguments(
            config: linux, endpoint: endpoint, knownHosts: kh, extra: [], probe: { _ in .open },
            fileExists: { $0 == "/k/nido_key.pub" })
        #expect(Array(agentArgv.prefix(3)) == ["ssh", "-i", "/k/nido_key.pub"])

        // Neither file, or no recorded key: no `-i`, ssh uses the user's keys as before.
        let missing = try CLISupport.sshArguments(
            config: linux, endpoint: endpoint, knownHosts: kh, extra: [], probe: { _ in .open }, fileExists: { _ in false })
        #expect(!missing.contains("-i") && !missing.contains("IdentitiesOnly=yes"))
        linux.sshPublicKeyPath = nil
        #expect(!(try CLISupport.sshArguments(
            config: linux, endpoint: endpoint, knownHosts: kh, extra: [], probe: { _ in .open },
            fileExists: { _ in true })).contains("-i"))

        // A path ssh would expand is refused.
        linux.sshPublicKeyPath = "/k/%u.pub"
        #expect(throws: NidoError.unsafePath("/k/%u")) {
            _ = try CLISupport.sshArguments(
                config: linux, endpoint: endpoint, knownHosts: kh, extra: [], probe: { _ in .open }, fileExists: { _ in true })
        }
    }

    /// `nido ssh` on a macOS VM that never reached its guest waits for ssh (instead of exec) and
    /// records the first success: ssh exits 255 on its own errors (refused, host key,
    /// authentication), otherwise with the remote status. The panel stops opening by itself.
    @Test func sshSuccessIsRecordedOnceForMacOS() throws {
        // Only a normal exit other than 255 (ssh's own errors) means ssh logged in.
        #expect(CLISupport.sshReachedGuest(.exited(0), extra: []))
        #expect(CLISupport.sshReachedGuest(.exited(1), extra: ["-v"]))
        #expect(!CLISupport.sshReachedGuest(.exited(255), extra: []))
        #expect(!CLISupport.sshReachedGuest(.signaled(SIGINT), extra: []))
        #expect(!CLISupport.sshReachedGuest(.signaled(SIGKILL), extra: []))
        // Options that never log in: version, config dump, queries, mux control.
        for flag in ["-V", "-G", "-Q", "-O"] {
            #expect(!CLISupport.sshReachedGuest(.exited(0), extra: [flag, "x"]), "\(flag)")
        }
        #expect(SSHExit.exited(3).exitCode == 3)
        #expect(SSHExit.signaled(SIGINT).exitCode == 128 + SIGINT)

        let mac = try macConfig("mac")
        #expect(CLISupport.watchesSSHResult(config: mac))
        var done = mac
        done.sshSucceeded = true
        #expect(!CLISupport.watchesSSHResult(config: done))
        #expect(!CLISupport.watchesSSHResult(config: try linuxConfig("deb")))

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nido-ssh-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try VMBundle.create(config: mac, paths: NidoPaths(root: root))
        CLISupport.recordSSHResult(bundle: bundle, exit: .exited(255), extra: [])
        CLISupport.recordSSHResult(bundle: bundle, exit: .signaled(SIGTERM), extra: [])
        CLISupport.recordSSHResult(bundle: bundle, exit: .exited(0), extra: ["-G"])
        #expect(try bundle.readConfig().sshSucceeded == nil)
        CLISupport.recordSSHResult(bundle: bundle, exit: .exited(0), extra: [])
        #expect(try bundle.readConfig().sshSucceeded == true)
    }

    @Test func sshRefusedExplainsRemoteLogin() throws {
        let kh = URL(fileURLWithPath: "/b/known_hosts")
        let mac = try macConfig("mac")
        let asked = Mutex<[String]>([])
        #expect(throws: CLIError.remoteLoginOff) {
            _ = try CLISupport.sshArguments(
                config: mac, endpoint: SSHEndpoint(host: "192.168.64.9", port: 22), knownHosts: kh, extra: [],
                probe: { endpoint in asked.withLock { $0.append(endpoint.host) }; return .refused })
        }
        #expect(asked.withLock { $0 } == ["192.168.64.9"])
        #expect(CLIError.remoteLoginOff.errorDescription
            == "attiva Login remoto nel guest: apri la VM in Nido, pannello Accesso da terminale")
        // Not answering (timeout, no route) is left to ssh and its own message.
        _ = try CLISupport.sshArguments(
            config: mac, endpoint: SSHEndpoint(host: "192.168.64.9", port: 22), knownHosts: kh, extra: [], probe: { _ in .noAnswer })
    }

    @Test func portProbeTellsRefusedFromOpen() throws {
        // A loopback port just released: nothing listens there, the kernel refuses the connection.
        func boundSocket(listening: Bool) throws -> (fd: Int32, port: UInt16) {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            try #require(fd >= 0)
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            addr.sin_port = 0
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let bound = withUnsafeMutablePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { p in
                    bind(fd, p, len) == 0 && getsockname(fd, p, &len) == 0
                }
            }
            try #require(bound)
            if listening { try #require(listen(fd, 1) == 0) }
            return (fd, UInt16(bigEndian: addr.sin_port))
        }
        let released = try boundSocket(listening: false)
        close(released.fd)
        #expect(PortProbe.tcp(host: "127.0.0.1", port: released.port, timeout: .seconds(2)) == .refused)
        let open = try boundSocket(listening: true)
        defer { close(open.fd) }
        #expect(PortProbe.tcp(host: "127.0.0.1", port: open.port, timeout: .seconds(2)) == .open)
        #expect(PortProbe.tcp(host: "not-an-ip", port: 22, timeout: .seconds(2)) == .noAnswer)
    }

    /// On the controlled network the Mac connects to gvproxy's forward on 127.0.0.1, which always
    /// accepts: a guest without Remote Login shows up as a connection closed before the SSH banner.
    @Test func controlledProbeWaitsForTheSSHBanner() throws {
        /// A loopback listener that, for each connection, sends `reply` (nil: nothing) and closes.
        final class OneShotServer: @unchecked Sendable {
            let fd: Int32
            let port: UInt16
            init(reply: String?) throws {
                let listener = socket(AF_INET, SOCK_STREAM, 0)
                fd = listener
                try #require(listener >= 0)
                var addr = sockaddr_in()
                addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                addr.sin_family = sa_family_t(AF_INET)
                addr.sin_addr.s_addr = inet_addr("127.0.0.1")
                var len = socklen_t(MemoryLayout<sockaddr_in>.size)
                let bound = withUnsafeMutablePointer(to: &addr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { p in
                        bind(listener, p, len) == 0 && getsockname(listener, p, &len) == 0
                    }
                }
                try #require(bound && listen(listener, 4) == 0)
                port = UInt16(bigEndian: addr.sin_port)
                Thread {
                    while true {
                        let client = accept(listener, nil, nil)
                        guard client >= 0 else { return }
                        if let reply { _ = reply.withCString { write(client, $0, strlen($0)) } }
                        close(client)
                    }
                }.start()
            }
            deinit { shutdown(fd, SHUT_RDWR); close(fd) }
        }

        let closes = try OneShotServer(reply: nil)
        let banner = try OneShotServer(reply: "SSH-2.0-x\r\n")
        let endpoint = { (server: OneShotServer) in SSHEndpoint(host: "127.0.0.1", port: server.port) }

        #expect(PortProbe.tcp(host: "127.0.0.1", port: closes.port, timeout: .seconds(2), awaitingBanner: true) == .refused)
        #expect(PortProbe.tcp(host: "127.0.0.1", port: banner.port, timeout: .seconds(2), awaitingBanner: true) == .open)
        // The probe `nido ssh` uses: controlled network waits for the banner, NAT only connects.
        #expect(CLISupport.remoteLoginProbe(controlledNetwork: true)(endpoint(closes)) == .refused)
        #expect(CLISupport.remoteLoginProbe(controlledNetwork: true)(endpoint(banner)) == .open)
        #expect(CLISupport.remoteLoginProbe(controlledNetwork: false)(endpoint(closes)) == .open)
        #expect(CLISupport.remoteLoginProbe(controlledNetwork: false)(endpoint(banner)) == .open)
    }

    // MARK: - rosetta, template, list

    @Test func rosettaRefusedForMac() throws {
        let env = try Env()
        defer { env.cleanup() }
        let bundle = try VMBundle.create(config: try macConfig("mac"), paths: env.paths)
        for enabled in [true, false] {
            for state in [RosettaState.installed, .notInstalled] {
                #expect(throws: CLIError.rosettaNotForMac) {
                    _ = try CLISupport.setRosetta(vm: "mac", enabled: enabled, paths: env.paths, state: state)
                }
            }
        }
        #expect(try bundle.readConfig().rosetta == false)
        #expect(CLIError.rosettaNotForMac.errorDescription
            == "Rosetta per Linux non riguarda le VM macOS: in macOS si installa dentro la VM")
    }

    @Test func templateSaveRefusedForMac() throws {
        let env = try Env()
        defer { env.cleanup() }
        let bundle = try VMBundle.create(config: try macConfig("mac"), paths: env.paths)
        #expect(throws: NidoError.macTemplatesUnavailable) {
            _ = try CLISupport.saveTemplate(vm: "mac", paths: env.paths)
        }
        #expect(try bundle.readConfig().isTemplate == false)
        #expect(CLISupport.message(for: NidoError.macTemplatesUnavailable)
            == "i modelli di VM macOS non sono ancora disponibili")
    }

    @Test func listShowsSystem() throws {
        let env = try Env()
        defer { env.cleanup() }
        _ = try VMBundle.create(config: try linuxConfig("deb"), paths: env.paths)
        _ = try VMBundle.create(config: try macConfig("mac", version: "26.1"), paths: env.paths)
        _ = try VMBundle.create(config: try macConfig("vecchia", version: nil), paths: env.paths)
        let rows = try CLISupport.listVMs(paths: env.paths)
        #expect(rows.map(\.system) == ["Debian 13", "macOS 26.1", "macOS"])
        let lines = CLISupport.formatList(rows).split(separator: "\n").map(String.init)
        #expect(lines[0].split(separator: " ", omittingEmptySubsequences: true)
            == ["NOME", "STATO", "SISTEMA", "CPU", "MEMORIA"])
        #expect(lines[2].contains("macOS 26.1"))
    }
}
