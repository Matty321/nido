// SPDX-License-Identifier: Apache-2.0

/// The guest clock's NTP server on the controlled network. Debian's `systemd-timesyncd` asks the
/// Debian pool (`N.debian.pool.ntp.org`), volunteer servers whose addresses the relay would
/// open on every port; new VMs (`VMFactory`) use one operator's server instead, which is in
/// `EgressPolicy.base`. A drop-in with an empty `FallbackNTP=` also turns off the compiled-in
/// fallback servers. Only through the seed of a new VM (an existing VM's seed is never rebuilt).
public enum GuestTimeSync {
    /// The only NTP server of a new guest (also in `EgressPolicy.base`).
    public static let server = "time.cloudflare.com"

    public static let path = "/etc/systemd/timesyncd.conf.d/nido.conf"
    public static let content = """
        # Nido: the clock syncs only with the time server of the controlled network's base list.
        [Time]
        NTP=\(server)
        FallbackNTP=

        """

    /// Mode of the file.
    static let fileMode = "0644"

    /// cloud-init `bootcmd` item, once per instance: timesyncd starts before cloud-init and,
    /// without the drop-in, asks the Debian pool (refused by the relay, seen live). Stopped this
    /// early, it waits for `command`; later boots start it normally with the drop-in.
    static let holdBootCommand = "[cloud-init-per, instance, nido-timesync-hold, systemctl, stop, systemd-timesyncd.service]"

    /// Run first in `runcmd`, once the drop-in is written: starts timesyncd again (stopped by
    /// `holdBootCommand`) with only `server`. `restart`, not `try-restart`: it is stopped here.
    static let command = ["systemctl", "restart", "systemd-timesyncd.service"]

    // MARK: - chrony (Ubuntu 26.04)

    /// The guest's NTP client. Debian 13 and Ubuntu 24.04 run `systemd-timesyncd`; Ubuntu 26.04
    /// runs `chrony`, whose Ubuntu pools (NTS, `N.ntp.ubuntu.com`, `ntp-bootstrap.ubuntu.com`)
    /// are in `/etc/chrony/sources.d/ubuntu-ntp-pools.sources`, a file the package manages with
    /// ucf.
    public enum Client: Sendable, Equatable {
        case timesyncd
        case chrony

        /// File written by the seed.
        var path: String { self == .timesyncd ? GuestTimeSync.path : GuestTimeSync.chronyPath }
        var content: String { self == .timesyncd ? GuestTimeSync.content : GuestTimeSync.chronyContent }
        var holdBootCommand: String {
            self == .timesyncd ? GuestTimeSync.holdBootCommand : GuestTimeSync.chronyHoldBootCommand
        }
        var command: [String] { self == .timesyncd ? GuestTimeSync.command : GuestTimeSync.chronyCommand }
    }

    /// chrony reads every `*.sources` file of this directory.
    public static let chronyPath = "/etc/chrony/sources.d/nido.sources"
    public static let chronyContent = """
        # Nido: the clock syncs only with the time server of the controlled network's base list.
        server \(server) iburst

        """

    /// cloud-init `bootcmd` item, once per instance: chrony is stopped; the package is told not
    /// to manage the Ubuntu pools any more (its postinst then removes the file at every upgrade
    /// instead of putting it back) and the pools file goes. Constants only; a step that fails
    /// leaves the pools (refused by the relay, nothing worse).
    static let chronyHoldBootCommand =
        "[cloud-init-per, instance, nido-timesync-hold, sh, -c, 'systemctl stop chrony.service; echo \"chrony chrony/configure_ubuntu_pools_in_sourcesd boolean false\" | debconf-set-selections; rm -f /etc/chrony/sources.d/ubuntu-ntp-pools.sources; exit 0']"

    /// Run first in `runcmd`: starts chrony again with only `server`.
    static let chronyCommand = ["systemctl", "restart", "chrony.service"]
}
