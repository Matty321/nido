// SPDX-License-Identifier: Apache-2.0
import Foundation
import NidoCore

/// Validated arguments of `nido create`.
public struct CreateOptions: Sendable, Equatable {
    public enum ImageSource: Sendable, Equatable {
        case catalog(CloudImage)
        case file(URL)
    }

    public var name: VMName
    public var image: ImageSource
    public var sshKeyPath: URL
    public var cpuCount: Int
    public var memoryBytes: UInt64
    public var diskBytes: UInt64
    public var profile: ProvisioningProfile
}

/// Validated arguments of `nido create --ipsw`. CPU and memory are nil when not given: their
/// defaults depend on the image (`CLISupport.macResources`).
public struct MacCreateOptions: Sendable, Equatable {
    public var name: VMName
    /// The restore image: only read.
    public var ipsw: URL
    public var sshKeyPath: URL
    /// The account the user will create in Setup Assistant (`VMConfig.validateSSHUser`).
    public var user: String
    public var cpuCount: Int?
    public var memoryBytes: UInt64?
    public var diskBytes: UInt64
}

/// One row of `nido list`.
public struct VMListing: Sendable, Equatable {
    public var name: String
    public var state: String
    /// The guest system: "Debian 13", "macOS 26.1" ("macOS" without a recorded version), "?".
    public var system: String
    public var cpus: String
    public var memory: String

    public init(name: String, state: String, system: String, cpus: String, memory: String) {
        self.name = name
        self.state = state
        self.system = system
        self.cpus = cpus
        self.memory = memory
    }
}
