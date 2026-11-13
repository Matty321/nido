// SPDX-License-Identifier: Apache-2.0

/// "Richieste di sfondo · Spegni" for a Linux VM created before the seed turned them off
/// (`GuestAptSRV` and `GuestAptListChanges` in every new VM, `UbuntuQuiet` in a new Ubuntu
/// one): the same settings, written over SSH by the explicit, fixed
/// `GuestCommand.quietBackground`. Only on the user's request.
public enum GuestBackgroundRequests {
    /// Constant script run as root with `/bin/sh -c`. Idempotent: the apt files are written whole
    /// (to a name apt ignores, then renamed); masking and the two `sed` edits can run again. A
    /// step that fails on Ubuntu (a file missing from the image) does not stop the others.
    public static func applyScript(ubuntu: Bool) -> String {
        var lines = [
            "set -u", "umask 022", "mkdir -p /etc/apt/apt.conf.d",
            "cat > '\(GuestAptSRV.path).nido-new' <<'NIDO_EOF'", GuestAptSRV.content + "NIDO_EOF",
            "mv -f '\(GuestAptSRV.path).nido-new' '\(GuestAptSRV.path)' || exit 1",
            "mkdir -p /etc/apt/listchanges.conf.d",
            "cat > '\(GuestAptListChanges.path).nido-new' <<'NIDO_EOF'", GuestAptListChanges.content + "NIDO_EOF",
            "mv -f '\(GuestAptListChanges.path).nido-new' '\(GuestAptListChanges.path)' || exit 1",
        ]
        if ubuntu { lines.append(UbuntuQuiet.steps) }
        lines.append("exit 0")
        return lines.joined(separator: "\n") + "\n"
    }

    /// Whether a Linux VM may still make the background requests (a VM created before 0.7.4 that
    /// nobody turned them off in): nothing is recorded in `config.backgroundRequestsOff` and its
    /// seed does not write `GuestAptListChanges.path` (the seeds of 0.7.4 do, before the field
    /// existed). An unreadable seed says nothing: no suggestion.
    public static func mayNeedQuieting(_ config: VMConfig, seedUserData: String?) -> Bool {
        guard config.guest == .linux, config.backgroundRequestsOff == nil, let seedUserData else { return false }
        return !seedUserData.contains(GuestAptListChanges.path)
    }

    /// `mayNeedQuieting` from the bundle's `config.json` and seed. Blocking: off the main actor.
    public static func mayNeedQuieting(bundle: VMBundle) -> Bool {
        guard let config = try? bundle.readConfig(), config.guest == .linux, config.backgroundRequestsOff == nil
        else { return false }
        return mayNeedQuieting(config, seedUserData: try? CloudInitSeed.readFile("user-data", fromISO: bundle.seedURL))
    }
}
