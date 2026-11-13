// SPDX-License-Identifier: Apache-2.0

/// What cloud-init phase 1 sets up in a new Linux guest. Both parts are off in `empty`, which
/// produces the same user-data as Nido versions before M3c.
public struct ProvisioningProfile: Codable, Sendable, Equatable {
    /// Essential packages (`package_update: true`, never `package_upgrade`).
    public var essentialPackages: Bool
    /// Nido Guest Tools (files and `nido-guest-tools.service`).
    public var guestTools: Bool

    public init(essentialPackages: Bool, guestTools: Bool) {
        self.essentialPackages = essentialPackages
        self.guestTools = guestTools
    }

    /// Nothing installed by cloud-init.
    public static let empty = ProvisioningProfile(essentialPackages: false, guestTools: false)
    /// Essential packages and Guest Tools.
    public static let standard = ProvisioningProfile(essentialPackages: true, guestTools: true)

    /// Packages installed when `essentialPackages` is on.
    public static let packages = [
        "ca-certificates", "curl", "wget", "git", "python3", "python3-venv", "python3-pip",
        "openssh-server", "iproute2", "procps", "util-linux", "jq", "tar", "zstd",
    ]
}

/// Phase 2 as the user chose it at creation (spec C): Ollama after the first boot, with at most
/// one model. Kept in the VM's config until Nido verified it or the user gave it up, so the app
/// resumes it after a restart; never sent through cloud-init.
public struct PendingProvisioning: Codable, Sendable, Equatable {
    /// Install Ollama (always true when the value exists; kept explicit for the file's reader).
    public var ollama: Bool
    /// The model to download after Ollama, validated with `GuestCommand.validateModelName`.
    public var model: String?

    public init(ollama: Bool, model: String?) {
        self.ollama = ollama
        self.model = model
    }
}
