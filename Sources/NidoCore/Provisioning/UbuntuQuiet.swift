// SPDX-License-Identifier: Apache-2.0

/// Ubuntu's background requests, turned off in a new Ubuntu VM. Seen refused by the relay in a
/// 26.04 VM on 2026-11-09 (`nido net log`): `api.snapcraft.io` (snapd), `motd.ubuntu.com`
/// (motd-news, apt news), `contracts.canonical.com` (Ubuntu Pro), `changelogs.ubuntu.com` (the
/// release-upgrade check of the login message); on 2026-11-02 also `entropy.ubuntu.com`
/// (pollinate). apt's SRV lookups, in Debian too, are `GuestAptSRV`. None of them is needed by the VM, and on the controlled
/// network they only fill the log with refusals.
///
/// Only through the seed of a new VM (an existing VM's seed is never rebuilt). Everything can be
/// undone in the guest: `systemctl unmask` the units, set `ENABLED=1` and `Prompt=lts` again. Package conffiles are edited in place with `sed`, never
/// replaced, so an upgrade does not ask about them.
public enum UbuntuQuiet {
    /// Units masked (and stopped) once per instance: snapd and its seeding, motd-news, the Ubuntu
    /// Pro timers, apt news, pollinate. A unit missing from the image is masked anyway, harmless.
    /// With snapd masked, an apt package that is only a snap shim on Ubuntu (chromium, firefox)
    /// cannot install: `ProvisioningProfile.packages` must stay plain apt packages.
    static let maskedUnits = [
        "snapd.seeded.service", "snapd.service", "snapd.socket",
        "motd-news.timer", "motd-news.service",
        "ua-timer.timer", "esm-cache.service", "apt-news.service", "ubuntu-advantage.service",
        "pollinate.service",
    ]

    /// cloud-init `bootcmd` item, once per instance, early in the first boot: constants only; a
    /// step that fails leaves that request on (refused by the relay, nothing worse).
    public static let bootCommand =
        "[cloud-init-per, instance, nido-ubuntu-quiet, sh, -c, '" + steps + "; exit 0']"

    /// The shell steps of `bootCommand` and of `GuestBackgroundRequests.applyScript`: no single
    /// quote (the boot command wraps them in one).
    static let steps = "systemctl mask --now " + maskedUnits.joined(separator: " ")
        + "; sed -i \"s/^ENABLED=.*/ENABLED=0/\" /etc/default/motd-news"
        + "; sed -i \"s/^Prompt=.*/Prompt=never/\" /etc/update-manager/release-upgrades"
}
