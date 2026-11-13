// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import NidoCore

private let validKey =
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOO97YvP4YWGQwUFq+UeOnyDKkD29RZ8VdmeuGgPzeS6"

/// Runs the script inside a one-time guest command (`sudo sh -c '…'`) with /bin/sh, every
/// `/etc/` path moved into a temp dir and the trailing systemctl steps left out. Returns what it
/// wrote, by guest path, with the temp dir mapped back to `/etc/`.
func filesWrittenByLegacyCommand(_ command: String) throws -> [String: String] {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("nido-tests-legacy-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: dir) }
    let prefix = "sudo sh -c '"
    #expect(command.hasPrefix(prefix) && command.hasSuffix("'"))
    #expect(command.filter { $0 == "'" }.count == 2)  // one single-quoted script
    var script = String(command.dropFirst(prefix.count).dropLast())
    guard let systemctl = script.range(of: " && systemctl daemon-reload && systemctl enable --now ") else {
        Issue.record("no systemctl steps")
        return [:]
    }
    script = String(script[..<systemctl.lowerBound]).replacingOccurrences(of: "/etc/", with: dir.path + "/etc/")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", script]
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
    var written: [String: String] = [:]
    let root = dir.appendingPathComponent("etc")
    for case let url as URL in fm.enumerator(at: root, includingPropertiesForKeys: nil)! {
        guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
        let guestPath = "/etc/" + url.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1)
        written[guestPath] = try String(contentsOf: url, encoding: .utf8)
            .replacingOccurrences(of: dir.path + "/etc/", with: "/etc/")
    }
    return written
}

@Suite struct GuestSetupTests {
    @Test func cloudInitMountsSharedFoldersWithAUnit() throws {
        let ud = CloudInitSeed.userData(username: "nido", publicKey: validKey)
        // No fstab entry (cloud-init `mounts`): a VM without shared folders has no `nido` tag,
        // and its mount unit would fail at every boot (cloud-init error, system degraded).
        #expect(!ud.contains("mounts:"))
        #expect(!ud.contains("fstab"))
        #expect(ud.contains("  - path: \(SharedFolder.unitPath)\n    permissions: \"0644\"\n    content: |\n"))
        for line in SharedFolder.unitText.split(separator: "\n") {
            #expect(ud.contains("      \(line)\n"))
        }
        #expect(SharedFolder.unitText.contains(
            #"ExecCondition=/bin/sh -c "mkdir -p /mnt/nido && { mountpoint -q /mnt/nido || mount -t virtiofs -o nosuid,nodev nido /mnt/nido; }""#))
        #expect(SharedFolder.unitText.contains("Type=oneshot\nRemainAfterExit=yes\n"))
        // systemd refuses a service without ExecStart ("bad unit file setting").
        #expect(SharedFolder.unitText.contains("\nExecStart=/bin/true\n"))
        #expect(SharedFolder.unitText.contains("WantedBy=multi-user.target"))
        #expect(ud.contains("  - [systemctl, enable, --now, nido-shares.service, nido-rosetta.service]\n"))
    }

    @Test func sharesLegacyCommandWritesTheUnitVerbatim() throws {
        let legacy = SharedFolder.legacyGuestCommand
        #expect(legacy.hasSuffix(" && systemctl daemon-reload && systemctl enable --now nido-shares.service'"))
        #expect(!legacy.contains("fstab"))
        let written = try filesWrittenByLegacyCommand(legacy)
        #expect(written == [SharedFolder.unitPath: SharedFolder.unitText + "\n"])
    }

    @Test func legacyCommandParsesInPOSIXShell() throws {
        for command in [SharedFolder.legacyGuestCommand, RosettaSupport.legacyGuestCommand] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-n", "-c", String(command.dropFirst("sudo sh -c '".count).dropLast())]
            try process.run()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0)
        }
    }
}
