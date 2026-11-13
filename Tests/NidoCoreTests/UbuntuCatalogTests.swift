// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import NidoCore

/// Ubuntu Server in the catalog: images, checksums, base list, config and seed.
@Suite struct UbuntuCatalogTests {
    @Test func catalogListsDebianThenBothUbuntuLTS() throws {
        #expect(CloudImageCatalog.all.map(\.id) == ["debian-13", "ubuntu-26.04", "ubuntu-24.04"])
        for distribution in LinuxDistribution.allCases {
            #expect(distribution.image.distribution == distribution)
            #expect(CloudImageCatalog.image(id: distribution.rawValue) == distribution.image)
        }
        for image in [CloudImageCatalog.ubuntu2604, CloudImageCatalog.ubuntu2404] {
            #expect(image.checksum == .sha256)
            #expect(image.sidecarName == image.fileName + ".sha256")
            #expect(image.checksumsURL.lastPathComponent == "SHA256SUMS")
            #expect(image.url.lastPathComponent == image.fileName)
            try DownloadPolicy.validate(image.url)
            try DownloadPolicy.validate(image.checksumsURL)
            #expect(image.signature?.keys == UbuntuCloudImageKey.keys)
        }
        // Each built-in key once, the current one among them.
        let fingerprints = UbuntuCloudImageKey.keys.map(\.fingerprint)
        #expect(Set(fingerprints).count == fingerprints.count)
        #expect(fingerprints.contains(UbuntuCloudImageKey.fingerprint))
        #expect(CloudImageCatalog.debian13.signature == nil)
        #expect(CloudImageCatalog.debian13.checksum == .sha512)
        #expect(CloudImageCatalog.debian13.sidecarName == "debian-13-genericcloud-arm64.raw.sha512")
    }

    @Test func otherUbuntuHostsAreNotAllowed() {
        #expect(throws: NidoError.self) { try DownloadPolicy.validate(URL(string: "https://ubuntu.com/x.img")!) }
        #expect(throws: NidoError.self) {
            try DownloadPolicy.validate(URL(string: "http://cloud-images.ubuntu.com/x.img")!)
        }
    }

    @Test func sha256SumsParseInBinaryAndTextMode() {
        let a = String(repeating: "a", count: 64), b = String(repeating: "B", count: 64)
        let text = "\(a) *ubuntu.img\n\(b)  other.img\n\(String(repeating: "c", count: 128))  debian.raw\nbad line\n"
        #expect(Checksums.parseSums(text, algorithm: .sha256) == [
            "ubuntu.img": a, "other.img": b.lowercased(),
        ])
        #expect(Checksums.parseSums(text, algorithm: .sha512) == ["debian.raw": String(repeating: "c", count: 128)])
    }

    @Test func sha256OfAFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nido-sha256-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("abc".utf8).write(to: url)
        #expect(try Checksums.digest(of: url, algorithm: .sha256)
            == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test func ubuntuBaseListSwapsOnlyTheArchive() {
        #expect(EgressPolicy.base(for: nil) == EgressPolicy.base)
        #expect(EgressPolicy.base(for: .debian13) == EgressPolicy.base)
        #expect(EgressPolicy.base(for: .ubuntu2604) == EgressPolicy.ubuntuBase)
        #expect(EgressPolicy.base(for: .ubuntu2404) == EgressPolicy.ubuntuBase)
        let ubuntu = EgressPolicy.ubuntuBase
        #expect(ubuntu.allows("archive.ubuntu.com"))
        #expect(ubuntu.allows("security.ubuntu.com"))
        #expect(ubuntu.allows("ports.ubuntu.com"))
        #expect(!ubuntu.allows("evil.archive.ubuntu.com"))
        #expect(!ubuntu.allows("deb.debian.org"))
        #expect(!ubuntu.allows("motd.ubuntu.com"))
        #expect(ubuntu.allows(GuestTimeSync.server))
        #expect(ubuntu.allows("registry.ollama.ai"))
        #expect(EgressPolicy.base.allows("deb.debian.org"))
        #expect(!EgressPolicy.base.allows("ports.ubuntu.com"))
    }

    func config(distribution: String?) throws -> VMConfig {
        var json: [String: Any] = [
            "schemaVersion": 5, "id": UUID().uuidString, "name": "vm", "guest": "linux", "cpuCount": 2,
            "memoryBytes": 1 << 30, "diskBytes": 1 << 34, "macAddress": "02:00:00:00:00:01",
        ]
        if let distribution { json["distribution"] = distribution }
        return try VMConfig.decode(try JSONSerialization.data(withJSONObject: json))
    }

    @Test func configDistributionDecodesTolerantly() throws {
        #expect(try config(distribution: nil).distribution == nil)
        #expect(try config(distribution: nil).linuxDistribution == .debian13)
        #expect(try config(distribution: "ubuntu-26.04").distribution == .ubuntu2604)
        #expect(try config(distribution: "ubuntu-24.04").linuxDistribution == .ubuntu2404)
        // A distribution of a newer build is unknown, not a broken config.
        let future = try config(distribution: "fedora-44")
        #expect(future.distribution == nil)
        #expect(future.linuxDistribution == nil)
        // Written back unchanged: a save by this build never erases it.
        #expect(String(decoding: try future.encoded(), as: UTF8.self).contains(#""distribution" : "fedora-44""#))
        var ubuntu = try config(distribution: "ubuntu-26.04")
        #expect(try VMConfig.decode(try ubuntu.encoded()) == ubuntu)
        ubuntu.guest = .macos
        #expect(ubuntu.linuxDistribution == nil)
    }

    @Test func timeClientPerDistribution() {
        #expect(LinuxDistribution.debian13.timeClient == .timesyncd)
        #expect(LinuxDistribution.ubuntu2404.timeClient == .timesyncd)
        #expect(LinuxDistribution.ubuntu2604.timeClient == .chrony)
    }

    @Test func chronySeedPinsTheServerAndDropsTheUbuntuPools() throws {
        let key = try CloudInitSeed.validatePublicKey(
            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOO97YvP4YWGQwUFq+UeOnyDKkD29RZ8VdmeuGgPzeS6")
        let userData = CloudInitSeed.userData(
            username: "nido", publicKey: key, pinnedTimeServer: true, timeClient: .chrony)
        #expect(userData.contains("  - path: /etc/chrony/sources.d/nido.sources"))
        #expect(userData.contains(Data(GuestTimeSync.chronyContent.utf8).base64EncodedString()))
        #expect(GuestTimeSync.chronyContent.contains("server time.cloudflare.com iburst\n"))
        #expect(userData.contains("runcmd:\n  - [systemctl, restart, chrony.service]\n"))
        #expect(userData.contains("bootcmd:\n  - " + GuestTimeSync.chronyHoldBootCommand))
        #expect(GuestTimeSync.chronyHoldBootCommand.contains("configure_ubuntu_pools_in_sourcesd boolean false"))
        #expect(GuestTimeSync.chronyHoldBootCommand.contains("rm -f /etc/chrony/sources.d/ubuntu-ntp-pools.sources"))
        // The default stays the Debian one, byte for byte.
        #expect(CloudInitSeed.userData(username: "nido", publicKey: key, pinnedTimeServer: true)
            == CloudInitSeed.userData(username: "nido", publicKey: key, pinnedTimeServer: true, timeClient: .timesyncd))
    }

    /// Ubuntu's background requests are turned off once per instance, with constants only.
    @Test func ubuntuSeedTurnsOffBackgroundRequests() throws {
        let key = try CloudInitSeed.validatePublicKey(
            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOO97YvP4YWGQwUFq+UeOnyDKkD29RZ8VdmeuGgPzeS6")
        let quiet = CloudInitSeed.userData(
            username: "nido", publicKey: key, pinnedTimeServer: true, timeClient: .chrony, quietUbuntu: true, aptQuiet: true)
        #expect(quiet.contains("  - " + UbuntuQuiet.bootCommand + "\n"))
        #expect(quiet.contains("  - " + GuestTimeSync.chronyHoldBootCommand))
        #expect(quiet.contains("  - path: \(GuestAptSRV.path)\n"))
        #expect(quiet.contains(Data(GuestAptSRV.content.utf8).base64EncodedString()))
        #expect(GuestAptSRV.content.contains("Acquire::EnableSrvRecords \"false\";"))
        #expect(quiet.contains("  - path: \(GuestAptListChanges.path)\n"))
        #expect(quiet.contains(Data(GuestAptListChanges.content.utf8).base64EncodedString()))
        #expect(GuestAptListChanges.content.contains("[apt]\nno_network=true\n"))
        // apt-listchanges reads only `*.conf` in its parts directory.
        #expect(GuestAptListChanges.path.hasPrefix("/etc/apt/listchanges.conf.d/") && GuestAptListChanges.path.hasSuffix(".conf"))
        for unit in ["snapd.service", "snapd.socket", "snapd.seeded.service", "motd-news.timer",
                     "ua-timer.timer", "esm-cache.service", "apt-news.service", "pollinate.service"] {
            #expect(UbuntuQuiet.bootCommand.contains(unit), "\(unit)")
        }
        #expect(UbuntuQuiet.bootCommand.hasPrefix("[cloud-init-per, instance, nido-ubuntu-quiet, sh, -c, 'systemctl mask --now "))
        #expect(UbuntuQuiet.bootCommand.contains("s/^ENABLED=.*/ENABLED=0/\" /etc/default/motd-news"))
        #expect(UbuntuQuiet.bootCommand.contains("s/^Prompt=.*/Prompt=never/\" /etc/update-manager/release-upgrades"))
        #expect(UbuntuQuiet.bootCommand.hasSuffix("; exit 0']"))
        // Debian (and the default) never gets it.
        let debian = CloudInitSeed.userData(username: "nido", publicKey: key, pinnedTimeServer: true)
        #expect(!debian.contains("nido-ubuntu-quiet") && !debian.contains(GuestAptSRV.path))
    }
}

/// "Richieste di sfondo · Spegni" for a VM created before: the same settings as the seed.
@Suite struct GuestBackgroundRequestsTests {
    @Test func scriptMatchesTheSeed() throws {
        let debian = GuestBackgroundRequests.applyScript(ubuntu: false)
        #expect(debian.contains("cat > '\(GuestAptSRV.path).nido-new' <<'NIDO_EOF'\n" + GuestAptSRV.content + "NIDO_EOF\n"))
        #expect(debian.contains("mv -f '\(GuestAptSRV.path).nido-new' '\(GuestAptSRV.path)' || exit 1\n"))
        #expect(debian.contains("cat > '\(GuestAptListChanges.path).nido-new' <<'NIDO_EOF'\n" + GuestAptListChanges.content + "NIDO_EOF\n"))
        #expect(debian.contains("mv -f '\(GuestAptListChanges.path).nido-new' '\(GuestAptListChanges.path)' || exit 1\n"))
        #expect(!debian.contains("systemctl mask"))
        #expect(debian.hasSuffix("exit 0\n"))

        let ubuntu = GuestBackgroundRequests.applyScript(ubuntu: true)
        #expect(ubuntu.contains(UbuntuQuiet.steps + "\nexit 0\n"))
        // The boot command runs the very same steps.
        #expect(UbuntuQuiet.bootCommand.contains("'" + UbuntuQuiet.steps + "; exit 0'"))
        #expect(!UbuntuQuiet.steps.contains("'"))

        #expect(try GuestCommand.quietBackground(ubuntu: true).argv()
            == ["sudo", "-n", "/bin/sh", "-c", ubuntu])
    }

    /// Only a Linux VM created before 0.7.4 is suggested "Spegni", until it is done or declined.
    @Test func quietingIsSuggestedOnlyToOlderLinuxVMs() throws {
        var config = VMConfig(
            id: UUID(), name: try VMName("vm"), guest: .linux, cpuCount: 2,
            memoryBytes: 1 << 30, diskBytes: 1 << 34, macAddress: "02:00:00:00:00:01")
        let key = try CloudInitSeed.validatePublicKey(
            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOO97YvP4YWGQwUFq+UeOnyDKkD29RZ8VdmeuGgPzeS6")
        let before = CloudInitSeed.userData(username: "nido", publicKey: key, pinnedTimeServer: true)
        let since = CloudInitSeed.userData(username: "nido", publicKey: key, pinnedTimeServer: true, aptQuiet: true)
        #expect(GuestBackgroundRequests.mayNeedQuieting(config, seedUserData: before))
        #expect(!GuestBackgroundRequests.mayNeedQuieting(config, seedUserData: since))
        #expect(!GuestBackgroundRequests.mayNeedQuieting(config, seedUserData: nil))
        for answer in [true, false] {
            config.backgroundRequestsOff = answer
            #expect(!GuestBackgroundRequests.mayNeedQuieting(config, seedUserData: before))
        }
        config.backgroundRequestsOff = nil
        config.guest = .macos
        #expect(!GuestBackgroundRequests.mayNeedQuieting(config, seedUserData: before))

        // In config.json only once answered; kept as written.
        config.guest = .linux
        #expect(!String(decoding: try config.encoded(), as: UTF8.self).contains("backgroundRequestsOff"))
        config.backgroundRequestsOff = false
        #expect(String(decoding: try config.encoded(), as: UTF8.self).contains(#""backgroundRequestsOff" : false"#))
        #expect(try VMConfig.decode(try config.encoded()) == config)
    }
}
