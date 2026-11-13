// SPDX-License-Identifier: Apache-2.0

/// Kernel settings that make a guest crash visible and recoverable (guests panicked silently when
/// macOS lost their memory pages under host memory overcommit): kernel messages also on the
/// virtio console (`hvc0`, recorded in the bundle's `console.log`; without it a panic only
/// reaches `tty0`, which a VM without a display never shows), and a reboot 10 s after a panic,
/// an oops counting as a panic, instead of a dead guest spinning its vCPUs on the Mac.
///
/// New VMs with the Guest Tools get both files from the seed; an existing VM only through the
/// explicit, fixed `GuestCommand.applyPanicSettings`. The command line takes effect from the
/// next boot (after `update-grub`), the sysctl values at once.
public enum GuestPanicSettings {
    /// Sourced by `grub-mkconfig` after `/etc/default/grub`: appends to the existing value, so
    /// whatever the image sets is kept. `console=hvc0` comes last: it becomes `/dev/console`.
    public static let grubPath = "/etc/default/grub.d/nido.cfg"
    public static let grubContent = """
        # Nido: kernel messages and panics also on the virtio console (console.log of the VM).
        GRUB_CMDLINE_LINUX_DEFAULT="$GRUB_CMDLINE_LINUX_DEFAULT console=tty0 console=hvc0"

        """

    public static let sysctlPath = "/etc/sysctl.d/90-nido.conf"
    public static let sysctlContent = """
        # Nido: reboot 10 seconds after a kernel panic; an oops is a panic.
        kernel.panic = 10
        kernel.panic_on_oops = 1

        """

    /// Mode of both files.
    static let fileMode = "0644"

    /// The files, as `(path, content)`.
    static var files: [(path: String, content: String)] {
        [(grubPath, grubContent), (sysctlPath, sysctlContent)]
    }

    /// Commands run after the files are written: the boot loader's configuration (the command
    /// line), then the sysctl values.
    static let commands = [["update-grub"], ["sysctl", "--system"]]

    /// Constant script of `GuestCommand.applyPanicSettings`, run as root with `/bin/sh -c`.
    /// Idempotent: each file is written whole (to a temporary name `grub-mkconfig` and `sysctl`
    /// ignore, then renamed), never appended to.
    public static let applyScript: String = {
        var lines = ["set -eu", "umask 022", "mkdir -p /etc/default/grub.d /etc/sysctl.d"]
        for (path, content) in files {
            lines += [
                "cat > '\(path).nido-new' <<'NIDO_EOF'", content + "NIDO_EOF",
                "mv -f '\(path).nido-new' '\(path)'",
            ]
        }
        lines += ["update-grub", "sysctl --system >/dev/null"]
        return lines.joined(separator: "\n") + "\n"
    }()
}
