// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import NidoCore

@Suite(.italian) struct GuestToolsInstallerTests {
    private func installer(_ runner: ProcessRunner) -> GuestToolsInstaller {
        GuestToolsInstaller(runner: runner, timeout: .seconds(30), resolveSSH: { _ in SSHEndpoint(host: "192.168.64.9", port: 22) })
    }

    /// Minimal ustar reader: [(name, mode, uid, gid, type, content)].
    private func entries(_ tar: Data) -> [(name: String, mode: String, uid: String, type: UInt8, content: Data)] {
        var out: [(String, String, String, UInt8, Data)] = []
        var offset = 0
        let bytes = [UInt8](tar)
        func field(_ start: Int, _ length: Int) -> String {
            String(decoding: bytes[start..<start + length].prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        while offset + 512 <= bytes.count, bytes[offset] != 0 {
            let size = Int(field(offset + 124, 11), radix: 8)!
            // Checksum must verify.
            var sum = 0
            for i in 0..<512 { sum += (148..<156).contains(i) ? 32 : Int(bytes[offset + i]) }
            #expect(sum == Int(field(offset + 148, 6), radix: 8))
            out.append((field(offset, 100), field(offset + 100, 7), field(offset + 108, 7), bytes[offset + 156],
                        Data(bytes[(offset + 512)..<(offset + 512 + size)])))
            offset += 512 + (size + 511) / 512 * 512
        }
        return out
    }

    @Test func archiveCarriesEveryPayloadFileAndOnlyRegularFiles() throws {
        let archive = try GuestToolsInstaller.archive(files: GuestToolsPayload.files.map { ($0.path, $0.mode, $0.base64) })
        let items = entries(archive)
        #expect(items.count == GuestToolsPayload.files.count + 2)
        // The list of what this version installs, for the next upgrade to remove what it drops.
        let manifest = try #require(items.first { $0.name == "MANIFEST" })
        #expect(String(decoding: manifest.content, as: UTF8.self)
            == GuestToolsPayload.files.map { $0.path + "\n" }.joined())
        #expect(items.allSatisfy { $0.type == UInt8(ascii: "0") && $0.uid == "0000000" })
        #expect(items.allSatisfy { !$0.name.hasPrefix("/") && !$0.name.contains("..") })
        for (index, file) in GuestToolsPayload.files.enumerated() {
            let item = try #require(items.first { $0.name == "files/\(index)" })
            #expect(item.content == Data(base64Encoded: file.base64))
        }
        #expect(archive.count % 512 == 0)
    }

    /// The manual installer (S08 "Copia i comandi"): one paste in the guest, the same archive and
    /// bootstrap as the SSH install, gzip-compressed so it fits the console's 32 KiB paste; the
    /// archive comes back byte for byte through base64 and gunzip.
    @Test func manualInstallCommandCarriesTheSameArchive() throws {
        let command = try GuestToolsInstaller.manualInstallCommand()
        #expect(command.utf8.count < GuestToolsInstaller.manualCommandLimit)
        let lines = command.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines.first == "base64 -d <<'NIDO_GUEST_TOOLS' | gunzip | sudo /bin/sh -c "
            + GuestCommand.shellQuote(GuestToolsInstaller.bootstrapScript))
        let end = try #require(lines.lastIndex(of: "NIDO_GUEST_TOOLS"))
        #expect(lines[1..<end].allSatisfy { $0.count <= 76 })
        let gz = try #require(Data(base64Encoded: lines[1..<end].joined()))
        let result = try SystemProcessRunner().run(
            executable: URL(fileURLWithPath: "/usr/bin/gunzip"), arguments: ["-c"],
            stdin: gz, timeout: 10, maxOutput: 8 << 20)
        #expect(result.status == 0)
        let archive = try GuestToolsInstaller.archive(files: GuestToolsPayload.files.map { ($0.path, $0.mode, $0.base64) })
        #expect(result.stdout == archive)
    }

    @Test func archiveIsAcceptedByBsdtar() throws {
        let archive = try GuestToolsInstaller.archive(files: GuestToolsPayload.files.map { ($0.path, $0.mode, $0.base64) })
        let result = try SystemProcessRunner().run(
            executable: URL(fileURLWithPath: "/usr/bin/tar"), arguments: ["-t", "-f", "-"],
            stdin: archive, timeout: 10, maxOutput: 1 << 20)
        #expect(result.status == 0)
        let listing = String(decoding: result.stdout, as: UTF8.self)
        #expect(listing.contains("install.sh"))
        #expect(listing.contains("files/\(GuestToolsPayload.files.count - 1)"))
    }

    @Test func scriptIsValidShellAndCoversAllFilesAndUnits() throws {
        let files = GuestToolsPayload.files.map { ($0.path, $0.mode, $0.base64) }
        let script = try GuestToolsInstaller.installScript(files: files)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nido-sh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("install.sh")
        try Data(script.utf8).write(to: file)
        let check = try SystemProcessRunner().run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-n", file.path])
        #expect(check.status == 0)
        for f in GuestToolsPayload.files {
            #expect(script.contains("dest='\(f.path)'"))
            #expect(script.contains("-m \(f.mode)"))
        }
        let units = GuestToolsPayload.files.filter { $0.path.hasPrefix("/etc/systemd/system/") && $0.path.hasSuffix(".service") }
        #expect(!units.isEmpty)
        for u in units { #expect(script.contains("systemctl enable '\(u.path.split(separator: "/").last!)'")) }
        #expect(script.contains("ID=debian") == false)  // compared through $ID, not hard-coded text
        #expect(script.contains("debian|ubuntu) ;; *) echo NIDO_RESULT=unsupported"))
        #expect(!script.contains("/home/nido"))
    }

    /// An upgrade removes what the previous version installed and this one no longer carries
    /// (its MANIFEST), a unit first disabled; nothing outside Nido's own paths is ever removed,
    /// whatever the old manifest says.
    @Test func upgradeRemovesFilesTheNewPayloadNoLongerHas() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("nido-prune-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let opt = root.appendingPathComponent("opt/nido-guest-tools")
        let units = root.appendingPathComponent("etc/systemd/system")
        let bin = root.appendingPathComponent("bin")
        let here = root.appendingPathComponent("here")
        for dir in [opt.appendingPathComponent("bin"), units, bin, here] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        func touch(_ url: URL) throws { try Data("x".utf8).write(to: url) }
        let kept = opt.appendingPathComponent("bin/nido-guest-tools")
        let dropped = opt.appendingPathComponent("bin/nido-old-helper")
        let droppedUnit = units.appendingPathComponent("nido-old.service")
        let foreign = root.appendingPathComponent("passwd")
        let foreignUnit = units.appendingPathComponent("sshd.service")
        // A directory link inside Nido's folder pointing outside it: never followed.
        let outside = root.appendingPathComponent("outside")
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        let victim = outside.appendingPathComponent("victim")
        try fm.createSymbolicLink(at: opt.appendingPathComponent("linkdir"), withDestinationURL: outside)
        for file in [kept, dropped, droppedUnit, foreign, foreignUnit, victim] { try touch(file) }
        let oldManifest = opt.appendingPathComponent("MANIFEST")
        try ([kept, dropped, droppedUnit, foreign, foreignUnit].map(\.path)
            + [opt.path + "/../../passwd", opt.path + "/linkdir/victim"])
            .joined(separator: "\n").appending("\n").write(to: oldManifest, atomically: true, encoding: .utf8)
        try (kept.path + "\n").write(to: here.appendingPathComponent("MANIFEST"), atomically: true, encoding: .utf8)
        // systemctl records what it is asked.
        let log = root.appendingPathComponent("systemctl.log")
        try "#!/bin/sh\necho \"$*\" >> '\(log.path)'\n".write(
            to: bin.appendingPathComponent("systemctl"), atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.appendingPathComponent("systemctl").path)

        let lines = ["here='\(here.path)'", "changed=0", "units_changed=0"]
            + GuestToolsInstaller.pruneLines(optRoot: opt.path, unitDir: units.path)
            + ["echo \"changed=$changed units=$units_changed\""]
        let script = root.appendingPathComponent("prune.sh")
        try lines.joined(separator: "\n").appending("\n").write(to: script, atomically: true, encoding: .utf8)
        let run = try SystemProcessRunner().run(
            executable: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["PATH=\(bin.path):/usr/bin:/bin", "/bin/sh", script.path])
        #expect(run.status == 0, "\(String(decoding: run.stderr, as: UTF8.self))")
        #expect(String(decoding: run.stdout, as: UTF8.self).contains("changed=1 units=1"))
        #expect(fm.fileExists(atPath: kept.path))
        #expect(!fm.fileExists(atPath: dropped.path))
        #expect(!fm.fileExists(atPath: droppedUnit.path))
        #expect(fm.fileExists(atPath: foreign.path))
        #expect(fm.fileExists(atPath: foreignUnit.path))
        #expect(fm.fileExists(atPath: victim.path))
        #expect(try String(contentsOf: log, encoding: .utf8) == "disable --now nido-old.service\n")

        // A payload without its MANIFEST (never sent today) removes nothing.
        try touch(dropped)
        try fm.removeItem(at: here.appendingPathComponent("MANIFEST"))
        let again = try SystemProcessRunner().run(
            executable: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["PATH=\(bin.path):/usr/bin:/bin", "/bin/sh", script.path])
        #expect(again.status == 0)
        #expect(fm.fileExists(atPath: dropped.path))
        #expect(fm.fileExists(atPath: kept.path))
    }

    @Test func extraUnitInThePayloadIsEnabledWithoutCodeChanges() throws {
        let files = [
            (path: "/etc/systemd/system/nido-ai-bridge.service", mode: "0644", base64: "eA=="),
            (path: "/opt/nido-guest-tools/bin/x", mode: "0755", base64: "eA=="),
        ]
        let script = try GuestToolsInstaller.installScript(files: files)
        #expect(script.contains("systemctl enable 'nido-ai-bridge.service'"))
        #expect(script.contains("install -D -o root -g root -m 0755"))
    }

    @Test func unsafePayloadPathsAreRefused() {
        for path in ["relative/x", "/opt/../etc/passwd", "/opt/a b", "/opt/a;b", "/opt/$(x)", "//x"] {
            #expect(throws: GuestToolsInstallError.invalidPayload(path)) {
                _ = try GuestToolsInstaller.installScript(files: [(path, "0644", "eA==")])
            }
        }
        #expect(throws: GuestToolsInstallError.invalidPayload("0999")) {
            _ = try GuestToolsInstaller.installScript(files: [("/opt/x", "0999", "eA==")])
        }
    }

    @Test func installerIsIdempotent() async throws {
        let fx = try GuestFixture(); defer { fx.cleanup() }
        let responses = Responses(["NIDO_RESULT=installed\n", "NIDO_RESULT=unchanged\n"])
        let runner = ScriptedRunner { _ in result(0, out: responses.next()) }
        let installer = installer(runner)
        #expect(try await installer.install(on: fx.bundle) == .installed)
        #expect(try fx.bundle.readConfig().guestToolsVersion == GuestToolsPayload.version)
        let configBefore = try Data(contentsOf: fx.bundle.configURL)
        #expect(try await installer.install(on: fx.bundle) == .unchanged)
        #expect(try Data(contentsOf: fx.bundle.configURL) == configBefore)
        // Both runs sent the same archive, over stdin, to the same fixed command.
        let calls = runner.calls
        #expect(calls.count == 2)
        #expect(calls[0].stdin == calls[1].stdin && calls[0].stdin != nil)
        #expect(calls[0].arguments.last == calls[1].arguments.last)
        let remote = try #require(calls[0].arguments.last)
        #expect(remote.hasPrefix("'sudo' '-n' '/bin/sh' '-c' '"))
    }

    /// The app changes the config while the VM runs (live shared folders): an install that takes
    /// minutes must not write its old snapshot back.
    @Test func configChangedDuringInstallIsKept() async throws {
        let fx = try GuestFixture(); defer { fx.cleanup() }
        let bundle = fx.bundle
        let runner = ScriptedRunner { _ in
            _ = try? bundle.updateConfig { $0.clipboardSharing = true; $0.cpuCount = 5 }
            return result(0, out: "NIDO_RESULT=installed\n")
        }
        #expect(try await installer(runner).install(on: bundle) == .installed)
        let after = try bundle.readConfig()
        #expect(after.guestToolsVersion == GuestToolsPayload.version)
        #expect(after.clipboardSharing == true && after.cpuCount == 5)
    }

    @Test func bootstrapSweepsOnlyOldStagingDirectories() {
        #expect(GuestToolsInstaller.bootstrapScript.contains("-name 'nido-gt.*' -type d -user root -mmin +10"))
    }

    @Test func nonDebianRefused() async throws {
        let fx = try GuestFixture(); defer { fx.cleanup() }
        let runner = ScriptedRunner { _ in result(0, out: "NIDO_RESULT=unsupported\n") }
        await #expect(throws: GuestToolsInstallError.unsupportedDistribution) {
            _ = try await installer(runner).install(on: fx.bundle)
        }
        #expect(try fx.bundle.readConfig().guestToolsVersion == nil)
        #expect(GuestToolsInstallError.unsupportedDistribution.errorDescription
            == "distribuzione non supportata: installa a mano, vedi README")
    }

    @Test func unexpectedAnswerIsAnErrorAndRecordsNothing() async throws {
        let fx = try GuestFixture(); defer { fx.cleanup() }
        let runner = ScriptedRunner { _ in result(0, out: "hello\n") }
        await #expect(throws: GuestToolsInstallError.unexpectedOutput) {
            _ = try await installer(runner).install(on: fx.bundle)
        }
        #expect(try fx.bundle.readConfig().guestToolsVersion == nil)
    }
}

private final class Responses: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String]
    init(_ items: [String]) { self.items = items }
    func next() -> String { lock.withLock { items.isEmpty ? "" : items.removeFirst() } }
}
