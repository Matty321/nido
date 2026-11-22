// SPDX-License-Identifier: Apache-2.0
import Foundation
import NidoCore

/// What `nido` refuses on this Mac before it reads or starts anything. Commands pass
/// `HostPlatform.current`; tests pass the host they want.
public enum HostChecks {
    /// macOS guests and everything about them (images, agent, MCP) need Apple silicon.
    public static func requireMacGuests(_ host: HostPlatform) throws(NidoError) {
        guard host.supportsMacGuests else { throw .needsAppleSilicon }
    }

    /// Suspending a running VM needs Apple silicon.
    public static func requireSaveRestore(_ host: HostPlatform) throws(NidoError) {
        guard host.supportsSaveRestore else { throw .suspendUnavailable }
    }

    /// Installing or turning on Rosetta needs Apple silicon.
    public static func requireRosetta(_ host: HostPlatform) throws(NidoError) {
        guard host.supportsRosetta else { throw .rosettaUnavailable }
    }

    /// `nido` under Rosetta would run as x86_64 on an Apple silicon Mac and misreport the host.
    public static func refuseTranslated(isTranslated: () -> Bool) throws(NidoError) {
        if isTranslated() { throw .translatedProcess }
    }

    /// True when this process runs translated by Rosetta (`sysctl.proc_translated` is 1).
    public static func isTranslatedProcess() -> Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("sysctl.proc_translated", &value, &size, nil, 0) == 0 else { return false }
        return value == 1
    }

    /// The hint on local images for this Mac's architecture.
    public static func localImageHint(_ host: HostPlatform) -> String {
        switch host.architecture {
        case .x86_64: L10n.string("Use an amd64 image on this Mac")
        case .arm64: L10n.string("Use an arm64 image on this Mac")
        }
    }

    /// Help of `--image-file`: the description, then the hint for this Mac.
    public static func imageFileHelp(_ host: HostPlatform = .current) -> String {
        "\(L10n.string("Local disk image, raw or qcow2 (not verified).")) \(localImageHint(host))."
    }
}
