// SPDX-License-Identifier: Apache-2.0

/// apt's SRV lookups, off in every new Linux VM. Before each archive apt asks for its
/// `_http._tcp` / `_https._tcp` SRV record: refused on the controlled network (only address
/// records of the allowed names are answered), so every `apt update` left refusals in the log.
/// Seen in Debian 13 (`_https._tcp.deb.debian.org`, 2026-11-03) and Ubuntu 26.04
/// (`_http._tcp.archive.ubuntu.com`, 2026-11-09); with this file apt asks for the address only
/// (verified live in Ubuntu 26.04). A new file, not a conffile: deleting it brings the lookups back.
public enum GuestAptSRV {
    public static let path = "/etc/apt/apt.conf.d/99nido-no-srv-lookup"
    public static let content = """
        // Nido: no SRV lookups before each archive, refused on the controlled network.
        Acquire::EnableSrvRecords "false";

        """

    /// Mode of `path`.
    static let fileMode = "0644"
}

/// apt-listchanges' network changelogs, off in every new Linux VM. Debian's cloud image strips
/// the packages' changelogs, so `apt-listchanges.timer` (hourly, until its first success) runs
/// `populate_database`, which asks `apt changelog` for each one: `metadata.ftp-master.debian.org`
/// (and its SRV record), refused on the controlled network. With `no_network` the database is
/// built from the local files only (verified live in Debian 13, 2026-11-10), and the timer
/// disables itself. A new file in `listchanges.conf.d`: deleting it brings the fetches back.
public enum GuestAptListChanges {
    public static let path = "/etc/apt/listchanges.conf.d/nido-no-network.conf"
    public static let content = """
        # Nido: no changelogs fetched from the network, refused on the controlled network.
        [apt]
        no_network=true

        """

    /// Mode of `path`.
    static let fileMode = "0644"
}
