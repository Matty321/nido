// SPDX-License-Identifier: Apache-2.0
import Foundation

/// A CPU architecture a Mac (or a guest made for it) runs on.
public enum CPUArchitecture: String, Codable, Sendable, CaseIterable {
    case arm64
    case x86_64

    /// The architecture in image and release names (`arm64` / `amd64`).
    public var imageLabel: String {
        switch self {
        case .arm64: "arm64"
        case .x86_64: "amd64"
        }
    }

    /// What `uname -m` prints in a Linux guest of this architecture.
    public var unameMachine: String {
        switch self {
        case .arm64: "aarch64"
        case .x86_64: "x86_64"
        }
    }
}

/// What this Mac can do, decided by its architecture: an Intel Mac runs Linux VMs only (no macOS
/// guests, no saved machine state, no Rosetta).
public struct HostPlatform: Sendable, Equatable {
    public let architecture: CPUArchitecture

    /// macOS guests need Apple silicon.
    public var supportsMacGuests: Bool { architecture == .arm64 }
    /// Saving and restoring a running machine needs Apple silicon.
    public var supportsSaveRestore: Bool { architecture == .arm64 }
    /// Rosetta for Linux needs Apple silicon.
    public var supportsRosetta: Bool { architecture == .arm64 }

    public static let appleSilicon = HostPlatform(architecture: .arm64)
    public static let intel = HostPlatform(architecture: .x86_64)

    /// The Mac this process runs on (the compiled architecture).
    public static var current: HostPlatform { current(environment: ProcessInfo.processInfo.environment) }

    /// `current` with the environment given. In DEBUG builds only, `NIDO_FAKE_HOST=intel` makes
    /// an Apple silicon Mac behave as an Intel one (tests and manual checks); release builds
    /// ignore the variable.
    public static func current(environment: [String: String]) -> HostPlatform {
        #if DEBUG
        if environment["NIDO_FAKE_HOST"] == "intel" { return .intel }
        #endif
        #if arch(arm64)
        return .appleSilicon
        #else
        return .intel
        #endif
    }
}
