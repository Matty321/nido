// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import NidoCore

private let body = "AAAAC3NzaC1lZDI1NTE5AAAAIOO97YvP4YWGQwUFq+UeOnyDKkD29RZ8VdmeuGgPzeS6"
private let validKey = "ssh-ed25519 \(body)"

private let essentialPackages = [
    "ca-certificates", "curl", "wget", "git", "python3", "python3-venv", "python3-pip",
    "openssh-server", "iproute2", "procps", "util-linux", "jq", "tar", "zstd",
]

private func yaml(_ profile: ProvisioningProfile) throws -> MiniYAML {
    try MiniYAML.parse(CloudInitSeed.userData(username: "nido", publicKey: validKey, profile: profile))
}

@Suite struct MiniYAMLTests {
    @Test func rejectsTabs() {
        #expect(throws: (any Error).self) { try MiniYAML.parse("a:\n\tb: 1\n") }
    }

    @Test func rejectsBadIndentation() {
        #expect(throws: (any Error).self) { try MiniYAML.parse("a:\n   b: 1\n") }  // odd
        #expect(throws: (any Error).self) { try MiniYAML.parse("a:\n  b: 1\n    c: 2\n") }  // too deep
        #expect(throws: (any Error).self) { try MiniYAML.parse("a: 1\n  b: 2\n") }
    }

    @Test func rejectsUnbalancedQuotesAndBrackets() {
        #expect(throws: (any Error).self) { try MiniYAML.parse("a: \"x\n") }
        #expect(throws: (any Error).self) { try MiniYAML.parse("a: 'x\n") }
        #expect(throws: (any Error).self) { try MiniYAML.parse("a: [x, y\n") }
        #expect(throws: (any Error).self) { try MiniYAML.parse("a: [x, 'y]\n") }
    }

    @Test func readsMapsListsAndBlocks() throws {
        let doc = try MiniYAML.parse(
            "a: 1\nb:\n  - x\n  - k: v\n    n: \"q\\\"z\"\n  - [p, 'q, r']\nc: |\n  l1\n    l2\n")
        #expect(doc["a"]?.text == "1")
        #expect(doc["b"]?.items?.count == 3)
        #expect(doc["b"]?.items?[1]["n"]?.text == "q\"z")
        #expect(doc["b"]?.items?[2].items?.compactMap(\.text) == ["p", "q, r"])
        #expect(doc["c"]?.text == "l1\n  l2\n")
    }
}

@Suite struct CloudInitProfileTests {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// Without a profile the user-data is the pre-M3c one plus only the `bootcmd` that
    /// regenerates missing SSH host keys at every boot (M3b).
    @Test func noProfileUserDataUnchanged() {
        #expect(CloudInitSeed.userData(username: "nido", publicKey: validKey) == userDataBeforeM3cWithHostKeys)
        #expect(
            CloudInitSeed.userData(username: "nido", publicKey: validKey, profile: .empty)
                == userDataBeforeM3cWithHostKeys)
    }

    @Test func profilePresets() {
        #expect(ProvisioningProfile.empty == ProvisioningProfile(essentialPackages: false, guestTools: false))
        #expect(ProvisioningProfile.standard == ProvisioningProfile(essentialPackages: true, guestTools: true))
    }

    @Test func standardProfileYAMLIsValid() throws {
        let text = CloudInitSeed.userData(username: "nido", publicKey: validKey, profile: .standard)
        #expect(!text.contains("\t"))
        let doc = try MiniYAML.parse(text)
        #expect(doc["disable_root"]?.text == "true")
        #expect(doc["ssh_pwauth"]?.text == "false")
        #expect(doc["users"]?.items?.first?["name"]?.text == "nido")
        #expect(doc["package_update"]?.text == "true")
        #expect(doc["packages"]?.items?.compactMap(\.text) == essentialPackages)
        let runcmd = try #require(doc["runcmd"]?.items)
        let commands = runcmd.map { $0.items?.compactMap(\.text) ?? [] }
        // Existing entries first and unchanged, then the Guest Tools unit.
        #expect(commands[0] == ["systemctl", "daemon-reload"])
        #expect(commands[1] == ["systemctl", "enable", "--now", SharedFolder.unitName, RosettaSupport.unitName])
        #expect(commands[2] == ["systemctl", "daemon-reload"])
        #expect(commands[3] == ["systemctl", "enable", "--now", "nido-guest-tools.service", "nido-ai-bridge.service"])
        // Then the panic settings: the kernel command line for the next boot, sysctl at once.
        #expect(commands[4] == ["update-grub"])
        #expect(commands[5] == ["sysctl", "--system"])
        #expect(commands.count == 6)
    }

    @Test func panicSettingsInStandardSeed() throws {
        for profile in [ProvisioningProfile.standard, ProvisioningProfile(essentialPackages: false, guestTools: true)] {
            let doc = try yaml(profile)
            let entries = try #require(doc["write_files"]?.items)
            let grub = try #require(entries.first { $0["path"]?.text == "/etc/default/grub.d/nido.cfg" })
            let sysctl = try #require(entries.first { $0["path"]?.text == "/etc/sysctl.d/90-nido.conf" })
            for entry in [grub, sysctl] {
                #expect(entry["owner"]?.text == "root:root")
                #expect(entry["permissions"]?.text == "0644")
                #expect(entry["encoding"]?.text == "b64")
            }
            let grubText = String(decoding: try #require(Data(base64Encoded: grub["content"]?.text ?? "")), as: UTF8.self)
            #expect(grubText.contains(#"GRUB_CMDLINE_LINUX_DEFAULT="$GRUB_CMDLINE_LINUX_DEFAULT console=tty0 console=hvc0""#))
            let sysctlText = String(decoding: try #require(Data(base64Encoded: sysctl["content"]?.text ?? "")), as: UTF8.self)
            let settings = sysctlText.split(separator: "\n").filter { !$0.hasPrefix("#") }
            #expect(settings == ["kernel.panic = 10", "kernel.panic_on_oops = 1"])
            let commands = try #require(doc["runcmd"]?.items).map { $0.items?.compactMap(\.text) ?? [] }
            #expect(commands.suffix(2) == [["update-grub"], ["sysctl", "--system"]])
        }
        // Without Guest Tools (and for the template clone) nothing changes the guest kernel.
        let others = [
            CloudInitSeed.userData(username: "nido", publicKey: validKey),
            CloudInitSeed.userData(
                username: "nido", publicKey: validKey,
                profile: ProvisioningProfile(essentialPackages: true, guestTools: false)),
            CloudInitSeed.userDataForTemplateClone(username: "nido", publicKey: validKey),
        ]
        for text in others {
            #expect(!text.contains("grub"))
            #expect(!text.contains("sysctl"))
        }
    }

    @Test func emptyProfileUnchanged() {
        let text = CloudInitSeed.userData(username: "nido", publicKey: validKey, profile: .empty)
        #expect(text == userDataBeforeM3cWithHostKeys)
        #expect(!text.contains("hvc0"))
        #expect(!text.contains("kernel.panic"))
        #expect(!text.contains("update-grub"))
    }

    @Test func seedEnablesBridgeUnit() throws {
        let doc = try yaml(.standard)
        let entries = try #require(doc["write_files"]?.items)
        #expect(entries.contains { $0["path"]?.text == "/etc/systemd/system/nido-ai-bridge.service" })
        #expect(entries.contains { $0["path"]?.text == "/opt/nido-guest-tools/bin/nido-ai-bridge" })
        let commands = try #require(doc["runcmd"]?.items).map { $0.items?.compactMap(\.text) ?? [] }
        #expect(commands.filter { $0.contains("nido-ai-bridge.service") }
            == [["systemctl", "enable", "--now", "nido-guest-tools.service", "nido-ai-bridge.service"]])
        // Without Guest Tools there is no bridge either.
        for profile in [ProvisioningProfile.empty, ProvisioningProfile(essentialPackages: true, guestTools: false)] {
            let text = CloudInitSeed.userData(username: "nido", publicKey: validKey, profile: profile)
            #expect(!text.contains("nido-ai-bridge"))
        }
    }

    @Test func packagesOnlyProfileHasNoGuestTools() throws {
        let doc = try yaml(ProvisioningProfile(essentialPackages: true, guestTools: false))
        #expect(doc["packages"] != nil)
        let text = CloudInitSeed.userData(
            username: "nido", publicKey: validKey,
            profile: ProvisioningProfile(essentialPackages: true, guestTools: false))
        #expect(!text.contains("nido-guest-tools"))
    }

    @Test func guestToolsOnlyProfileHasNoPackages() throws {
        let doc = try yaml(ProvisioningProfile(essentialPackages: false, guestTools: true))
        #expect(doc["packages"] == nil)
        #expect(doc["package_update"] == nil)
        #expect(doc["runcmd"]?.items?.count == 6)
    }

    @Test(arguments: [ProvisioningProfile.empty, .standard,
        ProvisioningProfile(essentialPackages: true, guestTools: false),
        ProvisioningProfile(essentialPackages: false, guestTools: true)])
    func packagesHaveNoUpgrade(_ profile: ProvisioningProfile) {
        let text = CloudInitSeed.userData(username: "nido", publicKey: validKey, profile: profile)
        #expect(!text.contains("package_upgrade"))
        #expect(!text.contains("apt:"))
    }

    @Test func guestToolsFilesAreBase64AndRoundTrip() throws {
        let doc = try yaml(.standard)
        let entries = try #require(doc["write_files"]?.items)
        for file in GuestToolsPayload.files {
            let entry = try #require(entries.first { $0["path"]?.text == file.path }, "\(file.path)")
            #expect(entry["encoding"]?.text == "b64")
            #expect(entry["owner"]?.text == "root:root")
            #expect(entry["permissions"]?.text == file.mode)
            let content = try #require(entry["content"]?.text)
            #expect(content == file.base64)
            let data = try #require(Data(base64Encoded: content))
            #expect(data == (try Data(contentsOf: source(for: file.path))))
        }
        // The existing VirtioFS units are still written, unchanged (plain literal blocks).
        #expect(entries.contains { $0["path"]?.text == "/etc/systemd/system/\(SharedFolder.unitName)" })
    }

    /// The repository file a payload path is generated from.
    private func source(for installPath: String) -> URL {
        let guest = repoRoot.appendingPathComponent("guest/linux")
        if installPath.hasPrefix("/etc/systemd/system/") {
            return guest.appendingPathComponent("systemd/" + (installPath as NSString).lastPathComponent)
        }
        return guest.appendingPathComponent(String(installPath.dropFirst("/opt/nido-guest-tools/".count)))
    }

    @Test func templateCloneSeedHasIdentityOnly() throws {
        let text = CloudInitSeed.userDataForTemplateClone(username: "nido", publicKey: validKey)
        let doc = try MiniYAML.parse(text)
        #expect(doc["users"]?.items?.first?["name"]?.text == "nido")
        #expect(text.contains("\"\(validKey)\""))
        #expect(doc["ssh_deletekeys"]?.text == "true")
        #expect(doc["ssh_pwauth"]?.text == "false")
        #expect(doc["bootcmd"]?.items?.count == 2)
        #expect(text.contains(CloudInitSeed.newMachineIDBootCommand))
        #expect(text.contains(CloudInitSeed.regenerateHostKeysBootCommand))
        #expect(doc["packages"] == nil)
        #expect(doc["package_update"] == nil)
        #expect(doc["write_files"] == nil)
        #expect(doc["runcmd"] == nil)
        #expect(!text.contains("nido-guest-tools"))
    }

    @Test func seedHasNoSecrets() {
        let texts = [
            CloudInitSeed.userData(username: "nido", publicKey: validKey, profile: .standard),
            CloudInitSeed.userData(username: "nido", publicKey: validKey),
            CloudInitSeed.userDataForTemplateClone(username: "nido", publicKey: validKey),
        ]
        for text in texts {
            #expect(!text.contains("-----BEGIN"))
            // `lock_passwd: true` and sudo's `NOPASSWD` are the only mentions: no password is set.
            let stripped = text.replacingOccurrences(of: "lock_passwd", with: "")
                .replacingOccurrences(of: "NOPASSWD", with: "")
            #expect(!stripped.lowercased().contains("passwd"))
            #expect(!text.lowercased().contains("password"))
            #expect(!text.contains("chpasswd"))
            #expect(!text.lowercased().contains("token"))
        }
        #expect(texts[0].contains("lock_passwd: true"))
    }
}

/// M3d: new VMs sync their clock only with the time server of the base list, never with the
/// Debian NTP pool (volunteer addresses the relay would open on every port).
@Suite struct GuestTimeSyncSeedTests {
    @Test func newVMsUseOnlyTheBaseListTimeServer() throws {
        #expect(GuestTimeSync.server == "time.cloudflare.com")
        #expect(EgressPolicy.base.allows(GuestTimeSync.server))
        #expect(!EgressPolicy.base.allows("0.debian.pool.ntp.org"))
        for profile in [ProvisioningProfile.empty, .standard] {
            let text = CloudInitSeed.userData(
                username: "nido", publicKey: validKey, profile: profile, pinnedTimeServer: true)
            let doc = try MiniYAML.parse(text)
            let entries = try #require(doc["write_files"]?.items)
            let file = try #require(entries.first { $0["path"]?.text == "/etc/systemd/timesyncd.conf.d/nido.conf" })
            #expect(file["owner"]?.text == "root:root")
            #expect(file["permissions"]?.text == "0644")
            #expect(file["encoding"]?.text == "b64")
            let content = String(decoding: try #require(Data(base64Encoded: file["content"]?.text ?? "")), as: UTF8.self)
            let settings = content.split(separator: "\n").filter { !$0.hasPrefix("#") }
            #expect(settings == ["[Time]", "NTP=time.cloudflare.com", "FallbackNTP="])
            let commands = try #require(doc["runcmd"]?.items).map { $0.items?.compactMap(\.text) ?? [] }
            #expect(commands.first == ["systemctl", "restart", "systemd-timesyncd.service"])
            // Held from early in the first boot until the drop-in is in place: timesyncd, started
            // before cloud-init, never asks the Debian pool (seen live: blocks before runcmd).
            let boot = try #require(doc["bootcmd"]?.items).map { $0.items?.compactMap(\.text) ?? [] }
            #expect(boot.contains(["cloud-init-per", "instance", "nido-timesync-hold",
                                   "systemctl", "stop", "systemd-timesyncd.service"]))
        }
        // Without it (and so for an existing VM's seed, never rebuilt) nothing changes.
        let plain = CloudInitSeed.userData(username: "nido", publicKey: validKey, profile: .standard)
        #expect(!plain.contains("timesyncd"))
    }
}
