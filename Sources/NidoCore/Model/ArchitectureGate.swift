// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Refuses a VM made for another architecture than this Mac's, before anything of its bundle is
/// touched: an arm64 VM never boots on Intel, an x86_64 VM never boots on Apple silicon, and a
/// macOS guest needs a host that supports Mac guests.
public enum ArchitectureGate {
    /// Throws `.wrongArchitecture` when `config` cannot run on `host`.
    public static func check(_ config: VMConfig, host: HostPlatform) throws(NidoError) {
        if config.guest == .macos, !host.supportsMacGuests {
            throw .wrongArchitecture(name: config.name.rawValue, made: .arm64)
        }
        guard config.architecture == host.architecture else {
            throw .wrongArchitecture(name: config.name.rawValue, made: config.architecture)
        }
    }
}
