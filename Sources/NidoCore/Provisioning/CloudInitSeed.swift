// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Builds the key-only cloud-init NoCloud seed (`cidata` ISO) for a guest.
public enum CloudInitSeed {
    private static let allowedTypes: Set<String> = [
        "ssh-ed25519", "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521", "ssh-rsa",
    ]

    /// Validates a single-line OpenSSH public key and returns `"<type> <body>"` (comment dropped).
    public static func validatePublicKey(_ s: String) throws(NidoError) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.utf8.contains(0x0A), !trimmed.utf8.contains(0x0D) else { throw .invalidPublicKey }
        let fields = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard fields.count >= 2 else { throw .invalidPublicKey }
        let type = fields[0]
        let body = fields[1]
        guard allowedTypes.contains(type), !body.isEmpty else { throw .invalidPublicKey }

        // Standard base64: A-Za-z0-9+/ with at most two trailing '=' padding characters.
        var stripped = Substring(body)
        var padding = 0
        while stripped.last == "=" { stripped = stripped.dropLast(); padding += 1 }
        guard padding <= 2, !stripped.isEmpty,
            stripped.utf8.allSatisfy({
                ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) || ($0 >= 0x30 && $0 <= 0x39)
                    || $0 == 0x2B || $0 == 0x2F
            }),
            let blob = Data(base64Encoded: body)
        else { throw .invalidPublicKey }

        // The blob must start with the SSH wire-format string naming the same key type.
        var expected = Data()
        let typeBytes = Array(type.utf8)
        withUnsafeBytes(of: UInt32(typeBytes.count).bigEndian) { expected.append(contentsOf: $0) }
        expected.append(contentsOf: typeBytes)
        guard blob.count > expected.count, blob.prefix(expected.count) == expected else {
            throw .invalidPublicKey
        }
        return "\(type) \(body)"
    }

    /// cloud-init `user-data`: key-only login, no password anywhere.
    /// `publicKey` must come from `validatePublicKey`. `write_files` installs the guest units of
    /// the VirtioFS devices (`nido-shares.service` for `/mnt/nido`, `nido-rosetta.service` and its
    /// binfmt rule for Rosetta) and `runcmd` enables and starts them. Each unit mounts its tag and
    /// is skipped when the VM runs without that device (see `GuestSetup`): no fstab entry, so a
    /// VM without shared folders or Rosetta boots with no failed unit.
    ///
    /// `profile` adds phase 1 of the provisioning: the essential packages (`package_update: true`,
    /// never `package_upgrade`) and the Nido Guest Tools (`write_files` entries in base64 and a
    /// `runcmd` that enables `nido-guest-tools.service` and the AI bridge shim
    /// `nido-ai-bridge.service` after the existing entries). With the Guest Tools also come the
    /// `GuestPanicSettings` (kernel messages on `hvc0` from the second boot, reboot after a
    /// panic), applied by `update-grub` and `sysctl --system` at the end of `runcmd`. With
    /// `.empty` the output is the one of Nido versions before M3c plus only the `bootcmd` of
    /// `regenerateHostKeysBootCommand` (M3b; the seed of an existing VM is never rebuilt).
    ///
    /// `pinnedTimeServer` (new VMs, M3d) writes `GuestTimeSync`'s timesyncd drop-in (base64,
    /// `root:root`, `0644`): timesyncd is stopped early in the first boot (`bootcmd`, once per
    /// instance) and restarted first in `runcmd`, so it never asks the Debian pool. With
    /// `timeClient: .chrony` (Ubuntu 26.04), the same with chrony's `nido.sources`, and the
    /// Ubuntu pools removed (`GuestTimeSync.chronyHoldBootCommand`).
    public static func userData(
        username: String, publicKey: String, profile: ProvisioningProfile = .empty,
        pinnedTimeServer: Bool = false, timeClient: GuestTimeSync.Client = .timesyncd,
        quietUbuntu: Bool = false, aptQuiet: Bool = false
    ) -> String {
        let packages =
            profile.essentialPackages
            ? "package_update: true\npackages:\n"
                + ProvisioningProfile.packages.map { "  - \($0)" }.joined(separator: "\n") + "\n"
            : ""
        var files = GuestSetup.writeFiles(SharedFolder.guestFiles + RosettaSupport.guestFiles)
        var commands = [
            "  - [systemctl, daemon-reload]",
            "  - [systemctl, enable, --now, \(SharedFolder.unitName), \(RosettaSupport.unitName)]",
        ]
        if pinnedTimeServer {
            files += "\n  - path: \(timeClient.path)\n    owner: root:root\n"
                + "    permissions: \"\(GuestTimeSync.fileMode)\"\n    encoding: b64\n"
                + "    content: \"\(Data(timeClient.content.utf8).base64EncodedString())\""
            commands.insert("  - [" + timeClient.command.joined(separator: ", ") + "]", at: 0)
        }
        if aptQuiet {
            // apt's SRV lookups and apt-listchanges' network changelogs (`GuestAptSRV`,
            // `GuestAptListChanges`): both only refusals on the controlled network.
            for (path, mode, content) in [
                (GuestAptSRV.path, GuestAptSRV.fileMode, GuestAptSRV.content),
                (GuestAptListChanges.path, GuestAptListChanges.fileMode, GuestAptListChanges.content),
            ] {
                files += "\n  - path: \(path)\n    owner: root:root\n"
                    + "    permissions: \"\(mode)\"\n    encoding: b64\n"
                    + "    content: \"\(Data(content.utf8).base64EncodedString())\""
            }
        }
        if profile.guestTools {
            files += "\n" + guestToolsWriteFiles() + "\n" + panicSettingsWriteFiles()
            commands += [
                "  - [systemctl, daemon-reload]",
                "  - [systemctl, enable, --now, \(guestToolsUnitName), \(aiBridgeUnitName)]",
            ]
            commands += GuestPanicSettings.commands.map { "  - [" + $0.joined(separator: ", ") + "]" }
        }
        let document = withBootCommand(
            regenerateHostKeysBootCommand,
            identity(username: username, publicKey: publicKey) + packages
                + "write_files:\n\(files)\nruncmd:\n" + commands.joined(separator: "\n") + "\n")
        let timed = pinnedTimeServer ? withBootCommand(timeClient.holdBootCommand, document) : document
        return quietUbuntu ? withBootCommand(UbuntuQuiet.bootCommand, timed) : timed
    }

    /// Name of the Guest Tools unit.
    static let guestToolsUnitName = "nido-guest-tools.service"
    /// Name of the AI bridge shim's unit (loopback 127.0.0.1:11435 to the Mac over vsock 7701).
    static let aiBridgeUnitName = "nido-ai-bridge.service"

    /// `#cloud-config` header, SSH policy and the user with its key (no trailing blank line).
    private static func identity(username: String, publicKey: String) -> String {
        precondition(
            username.range(of: #"^[a-z_][a-z0-9_-]{0,31}$"#, options: .regularExpression) != nil,
            "invalid guest username")
        return """
            #cloud-config
            disable_root: true
            ssh_pwauth: false
            users:
              - name: \(username)
                lock_passwd: true
                shell: /bin/bash
                sudo: "ALL=(ALL) NOPASSWD:ALL"
                ssh_authorized_keys:
                  - "\(publicKey)"

            """
    }

    /// `write_files` entries of the Guest Tools payload: base64 content, `root:root`, the modes of
    /// the payload.
    private static func guestToolsWriteFiles() -> String {
        GuestToolsPayload.files.map { file in
            "  - path: \(file.path)\n    owner: root:root\n    permissions: \"\(file.mode)\"\n"
                + "    encoding: b64\n    content: \"\(file.base64)\""
        }.joined(separator: "\n")
    }

    /// `write_files` entries of `GuestPanicSettings` (base64, `root:root`, `0644`).
    private static func panicSettingsWriteFiles() -> String {
        GuestPanicSettings.files.map { file in
            "  - path: \(file.path)\n    owner: root:root\n    permissions: \"\(GuestPanicSettings.fileMode)\"\n"
                + "    encoding: b64\n    content: \"\(Data(file.content.utf8).base64EncodedString())\""
        }.joined(separator: "\n")
    }

    /// `user-data` of a clone of a template: identity only (the user and its key, SSH host keys
    /// regenerated, a new `/etc/machine-id`). No packages and no Guest Tools: the template's disk
    /// already has what its own first boot installed.
    public static func userDataForTemplateClone(username: String, publicKey: String) -> String {
        userDataForClone(identity(username: username, publicKey: publicKey))
    }

    /// cloud-init `meta-data` with a DNS-safe hostname.
    public static func metaData(instanceID: UUID, hostname: VMName) -> String {
        let host = hostname.rawValue.lowercased()
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: ".", with: "-")
        return "instance-id: \(instanceID.uuidString.lowercased())\nlocal-hostname: \(host)\n"
    }

    /// cloud-init `network-config` (v2): DHCP on the NIC with `macAddress`, using the MAC as the
    /// DHCP client identifier. Without it Debian's systemd-networkd sends a DUID (RFC 4361), so
    /// the macOS lease (`hw_address=ff,…`) cannot be found by MAC.
    public static func networkConfig(macAddress: String) throws(NidoError) -> String {
        let mac = macAddress.lowercased()
        guard mac.range(of: #"^[0-9a-f]{2}(:[0-9a-f]{2}){5}$"#, options: .regularExpression) != nil else {
            throw .invalidResources(L10n.string("invalid MAC address"))
        }
        return """
            version: 2
            ethernets:
              primary:
                match:
                  macaddress: "\(mac)"
                dhcp4: true
                dhcp-identifier: mac

            """
    }

    /// Builds the `cidata` ISO at `output` (which must not exist) using `/usr/bin/hdiutil`.
    /// `network-config` is included only when `networkConfig` is not `nil`.
    public static func buildISO(
        at output: URL, userData: String, metaData: String, networkConfig: String? = nil,
        runner: ProcessRunner
    ) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: output.path) { throw NidoError.alreadyExists(output.path) }

        let dir = fm.temporaryDirectory.appendingPathComponent("nido-seed-\(UUID().uuidString)")
        try PrivateDirectory.ensure(dir)
        defer { try? fm.removeItem(at: dir) }

        var files = [("user-data", userData), ("meta-data", metaData)]
        if let networkConfig { files.append(("network-config", networkConfig)) }
        for (name, text) in files {
            let file = dir.appendingPathComponent(name)
            guard fm.createFile(atPath: file.path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600])
            else { throw NidoError.unsafePath(file.path) }
        }

        let hdiutil = URL(fileURLWithPath: "/usr/bin/hdiutil")
        let result = try runner.run(
            executable: hdiutil,
            arguments: [
                "makehybrid", "-iso", "-joliet", "-default-volume-name", "cidata",
                "-o", output.path, dir.path,
            ])
        guard result.status == 0 else {
            throw NidoError.processFailed(executable: hdiutil.path, status: result.status)
        }
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
    }

    // MARK: - Clones

    /// cloud-init `bootcmd` item of a clone (ruling R-M3A-18): once per instance, early in the
    /// first boot of the clone, a new `/etc/machine-id` (cloud-init keeps the source's, so journald,
    /// D-Bus and DHCP/IPv6 setups keyed on it would see two identical machines). Constants only.
    /// The D-Bus link to it is put back and journald restarted, so the journal of this first boot
    /// is under the new id (seen on Debian 13: otherwise `journalctl -b` finds no journal files
    /// until the next boot). Only a failed `systemd-machine-id-setup` fails the step, which
    /// `cloud-init-per` then retries at the next boot; once it succeeded it never runs again.
    public static let newMachineIDBootCommand =
        "[cloud-init-per, instance, nido-machine-id, sh, -c, 'rm -f /etc/machine-id /var/lib/dbus/machine-id && systemd-machine-id-setup || exit 1; [ ! -d /var/lib/dbus ] || ln -sf /etc/machine-id /var/lib/dbus/machine-id; systemctl restart systemd-journald; exit 0']"

    /// cloud-init `bootcmd` item of every new Linux VM and every clone (M3b): at every boot
    /// (no `cloud-init-per`), `ssh-keygen -A` creates the SSH host keys that are missing and never
    /// replaces one that exists. A first boot cut short after cloud-init removed the image's keys
    /// and before it wrote new ones (the app quit, the Mac lost power) would otherwise leave sshd
    /// without keys for good, since cloud-init does not run its per-instance `ssh` module again.
    /// `bootcmd` runs in cloud-init's network stage, ordered before `sshd.service`, and before
    /// cloud-init's own `ssh` module (which still replaces the keys on a first boot, as
    /// `ssh_deletekeys` asks). Constants only; a guest without `ssh-keygen` skips it.
    public static let regenerateHostKeysBootCommand =
        "[sh, -c, 'command -v ssh-keygen >/dev/null 2>&1 || exit 0; ssh-keygen -A']"

    /// The source's `user-data` with `regenerateHostKeysBootCommand` and `newMachineIDBootCommand`
    /// added (the machine-id first): each is left out when the user-data already has it (a clone
    /// of a clone: the per-instance guard runs the machine-id one again for the new instance
    /// anyway); put first in an existing top-level `bootcmd:` list, else appended as a new
    /// `bootcmd:` key; and `ssh_deletekeys: true` (the clone gets its own SSH host keys).
    public static func userDataForClone(_ userData: String) -> String {
        withDeletedHostKeys(
            withBootCommand(newMachineIDBootCommand, withBootCommand(regenerateHostKeysBootCommand, userData)))
    }

    /// `ssh_deletekeys: true` at the top level (an existing setting is replaced): cloud-init
    /// removes the host keys copied from the source before generating the clone's own. It is
    /// cloud-init's default; written explicitly so no source user-data can turn it off.
    static func withDeletedHostKeys(_ userData: String) -> String {
        var lines = userData.components(separatedBy: "\n")
        if let index = lines.firstIndex(where: { $0.hasPrefix("ssh_deletekeys:") }) {
            lines[index] = "ssh_deletekeys: true"
            return lines.joined(separator: "\n")
        }
        let separator = userData.isEmpty || userData.hasSuffix("\n") ? "" : "\n"
        return userData + separator + "ssh_deletekeys: true\n"
    }

    /// `userData` with the constant `command` first in its top-level `bootcmd:` list (a new list
    /// at the end when it has none); unchanged when it has `command` already.
    private static func withBootCommand(_ command: String, _ userData: String) -> String {
        guard !userData.contains(command) else { return userData }
        var lines = userData.components(separatedBy: "\n")
        if let index = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "bootcmd:" && !$0.hasPrefix(" ") }) {
            var indent = "  "
            if index + 1 < lines.count {
                let next = lines[index + 1]
                let leading = String(next.prefix(while: { $0 == " " }))
                if !leading.isEmpty, next.dropFirst(leading.count).hasPrefix("- ") { indent = leading }
            }
            lines.insert(indent + "- " + command, at: index + 1)
            return lines.joined(separator: "\n")
        }
        let separator = userData.isEmpty || userData.hasSuffix("\n") ? "" : "\n"
        return userData + separator + "bootcmd:\n  - " + command + "\n"
    }

    // MARK: - Reading a seed back

    /// Largest `seed.iso` read back (the ones `hdiutil` builds are under 1 MiB).
    static let maxSeedSize = 16 << 20
    /// Largest file read from a seed. The user-data of a VM with the Guest Tools embeds their
    /// files in base64 (well over 64 KiB since M3c): cloning such a VM reads it back whole.
    static let maxSeedFileSize = 4 << 20

    /// The text of the file `name` (`user-data`, `meta-data`, `network-config`) at the root of a
    /// seed ISO built by `buildISO`: read without following a symlink, from a regular file of at
    /// most `maxSeedSize` bytes, through the ISO 9660 primary volume descriptor (names compared
    /// ignoring case, without the `;1` version). Anything else is `.seedUnreadable(<path>)`.
    public static func readFile(_ name: String, fromISO iso: URL) throws -> String {
        let unreadable = NidoError.seedUnreadable(iso.path)
        let fd = Darwin.open(iso.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw unreadable }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size <= maxSeedSize,
            let data = try? handle.read(upToCount: maxSeedSize + 1), data.count <= maxSeedSize,
            let content = ISO9660.rootFile(named: name, in: [UInt8](data), maxSize: maxSeedFileSize),
            let text = String(bytes: content, encoding: .utf8)
        else { throw unreadable }
        return text
    }
}

/// Just enough ISO 9660 to find a file in the root directory of a small image.
enum ISO9660 {
    static let sectorSize = 2048

    /// The bytes of the regular file `name` in the root directory, nil when the image is not ISO
    /// 9660, has no such file or the file is larger than `maxSize`.
    static func rootFile(named name: String, in bytes: [UInt8], maxSize: Int) -> ArraySlice<UInt8>? {
        guard let root = rootDirectory(bytes) else { return nil }
        let wanted = name.uppercased()
        var offset = root.start
        let end = root.start + root.size
        while offset < end {
            let length = Int(bytes[offset])
            if length == 0 {
                // Records never cross a sector: the rest of this one is padding.
                offset = (offset / sectorSize + 1) * sectorSize
                continue
            }
            guard length >= 34, offset + length <= end else { return nil }
            let nameLength = Int(bytes[offset + 32])
            let flags = bytes[offset + 25]
            guard 33 + nameLength <= length else { return nil }
            var entry = String(decoding: bytes[(offset + 33)..<(offset + 33 + nameLength)], as: UTF8.self)
            if let semicolon = entry.firstIndex(of: ";") { entry = String(entry[..<semicolon]) }
            if entry.hasSuffix(".") { entry.removeLast() }
            entry = entry.uppercased()
            if flags & 0x02 == 0, entry == wanted || entry == wanted.replacingOccurrences(of: "-", with: "_") {
                guard let extent = le32(bytes, offset + 2), let size = le32(bytes, offset + 10),
                    size <= maxSize
                else { return nil }
                let start = extent * sectorSize
                guard start <= bytes.count, size <= bytes.count - start else { return nil }
                return bytes[start..<(start + size)]
            }
            offset += length
        }
        return nil
    }

    /// Byte range of the root directory, from the primary volume descriptor (type 1, `CD001`).
    private static func rootDirectory(_ bytes: [UInt8]) -> (start: Int, size: Int)? {
        var sector = 16
        while (sector + 1) * sectorSize <= bytes.count {
            let base = sector * sectorSize
            guard Array(bytes[(base + 1)..<(base + 6)]) == Array("CD001".utf8) else { return nil }
            let type = bytes[base]
            if type == 255 { return nil }
            if type == 1 {
                let record = base + 156
                guard let extent = le32(bytes, record + 2), let size = le32(bytes, record + 10)
                else { return nil }
                let start = extent * sectorSize
                guard start <= bytes.count, size <= bytes.count - start else { return nil }
                return (start, size)
            }
            sector += 1
        }
        return nil
    }

    /// Little-endian 32-bit field (ISO 9660 stores both orders; the first is little-endian).
    private static func le32(_ bytes: [UInt8], _ offset: Int) -> Int? {
        guard offset >= 0, offset + 4 <= bytes.count else { return nil }
        return Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 | Int(bytes[offset + 2]) << 16
            | Int(bytes[offset + 3]) << 24
    }
}
