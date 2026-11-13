// SPDX-License-Identifier: Apache-2.0
import Foundation
import Virtualization

/// Whether this Mac can give a Linux guest Rosetta (`VZLinuxRosettaDirectoryShare.availability`).
public enum RosettaState: Equatable, Sendable {
    /// Not on this Mac (e.g. no Apple silicon support).
    case unsupported
    /// Supported but not installed: `RosettaSupport.install()` asks the system to install it.
    case notInstalled
    case installed

    public init(_ availability: VZLinuxRosettaAvailability) {
        switch availability {
        case .installed: self = .installed
        case .notInstalled: self = .notInstalled
        default: self = .unsupported
        }
    }

    /// What this Mac has right now.
    public static var current: RosettaState { RosettaState(VZLinuxRosettaDirectoryShare.availability) }

    /// Why a VM cannot use Rosetta, as an error (the CLI refuses with it), nil when it can.
    public var error: NidoError? {
        switch self {
        case .installed: nil
        case .notInstalled: .rosettaNotInstalled
        case .unsupported: .rosettaUnavailable
        }
    }

    /// The same reason as a localized sentence (the app shows it), nil when Rosetta can be used.
    public var reason: String? { error.flatMap(\.errorDescription).map { $0 + "." } }
}

/// Rosetta for x86_64 Linux binaries: a second VirtioFS device (tag `rosetta`) backed by
/// `VZLinuxRosettaDirectoryShare`, mounted read-only by the guest on `/media/rosetta` and
/// registered with binfmt_misc so that the kernel hands x86_64 ELF binaries to
/// `/media/rosetta/rosetta`.
///
/// In the guest, `nido-rosetta.service` mounts the tag and then runs `systemd-binfmt` on
/// `binfmtConfigPath`. While the VM has Rosetta off the device is absent: the mount is the unit's
/// `ExecCondition`, so the unit is skipped instead of failing. Neither an fstab line nor a file in
/// `/etc/binfmt.d` is used, because both would leave a failed unit (and a "degraded" system) at
/// every boot of a VM without Rosetta: a missing VirtioFS tag fails its mount unit even with
/// `nofail`, and with the `F` flag the kernel opens the interpreter at registration, so
/// `systemd-binfmt.service` itself would fail.
public enum RosettaSupport {
    /// VirtioFS tag of the Rosetta device.
    public static let tag = "rosetta"
    /// Where the guest mounts the device.
    public static let guestMountPoint = "/media/rosetta"
    /// The translator inside the share.
    public static let interpreter = "\(guestMountPoint)/rosetta"

    /// The binfmt_misc rule (`:name:type:offset:magic:mask:interpreter:flags`). Magic and mask
    /// match an x86_64 ELF executable or shared object (ELF64, little endian, e_type 2 or 3,
    /// e_machine 0x3e), as in Apple's "Running Intel Binaries in Linux VMs with Rosetta".
    /// `F` (fix binary): the interpreter is opened once at registration, so it keeps working
    /// in other mount namespaces (containers). No `C`: setuid x86_64 binaries are not elevated.
    public static let binfmtRule =
        #":rosetta:M::\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x3e\x00"#
        + #":\xff\xff\xff\xff\xff\xfe\xfe\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff"#
        + ":\(interpreter):F"

    /// The guest file holding `binfmtRule` (admin configuration, hence /etc).
    public static let binfmtConfigPath = "/etc/nido/rosetta-binfmt.conf"
    public static let unitName = "nido-rosetta.service"
    public static let unitPath = "/etc/systemd/system/\(unitName)"

    /// Mounts the tag read-only, `nosuid,nodev` (unless already mounted), then registers the
    /// rule, after `systemd-binfmt.service` (which flushes every rule when it starts); `PartOf`
    /// registers it again whenever that service is restarted. When the mount fails (Rosetta off
    /// for the VM: no such tag) the `ExecCondition` skips the unit: no failed unit.
    ///
    /// `/usr/lib/systemd/systemd-binfmt` assumes a usr-merged guest (Debian 12 and later, the
    /// only guests Nido creates); on a non-merged one it would be `/lib/systemd/systemd-binfmt`.
    public static let unitText = """
        [Unit]
        Description=Rosetta for x86_64 binaries (Nido)
        After=local-fs.target systemd-binfmt.service
        PartOf=systemd-binfmt.service

        [Service]
        Type=oneshot
        RemainAfterExit=yes
        \(GuestSetup.mountCondition(tag: tag, mountPoint: guestMountPoint, options: "ro,nosuid,nodev"))
        ExecStart=/usr/lib/systemd/systemd-binfmt \(binfmtConfigPath)

        [Install]
        WantedBy=multi-user.target
        """

    /// What the guest needs: the rule file and the unit (cloud-init `write_files`).
    public static let guestFiles = [
        GuestFile(path: binfmtConfigPath, content: binfmtRule),
        GuestFile(path: unitPath, content: unitText),
    ]

    /// Run once in a guest created before Rosetta support (its cloud-init did not set it up).
    public static let legacyGuestCommand = GuestSetup.legacyCommand(files: guestFiles, unitName: unitName)

    /// Asks macOS to download and install Rosetta for Linux. This prompts the user through a
    /// system install: call it only from an explicit, confirmed user action.
    public static func install() async throws {
        try await VZLinuxRosettaDirectoryShare.installRosetta()
    }

    /// The Rosetta device for a VM with Rosetta on, or the reason it is left out (localized
    /// sentence for `GuestConfiguration.warnings`). Never throws: the VM starts without it.
    static func device(state: RosettaState) -> (device: VZVirtioFileSystemDeviceConfiguration?, warning: String?) {
        switch state {
        case .unsupported:
            return (nil, L10n.string("Rosetta isn’t available on this Mac: the VM starts without it."))
        case .notInstalled:
            return (nil, L10n.string(
                "Rosetta isn’t installed on this Mac: the VM starts without it. Install it with “nido rosetta install” or from the VM’s settings."))
        case .installed:
            do {
                let device = VZVirtioFileSystemDeviceConfiguration(tag: tag)
                device.share = try VZLinuxRosettaDirectoryShare()
                return (device, nil)
            } catch {
                return (nil, L10n.string("Rosetta can’t be used (\(error.localizedDescription)): the VM starts without it."))
            }
        }
    }
}
