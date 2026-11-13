// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Locations of Nido data on disk.
public struct NidoPaths: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// `~/Library/Application Support/Nido/VMs`.
    public static func defaultRoot() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("Nido", isDirectory: true)
            .appendingPathComponent("VMs", isDirectory: true)
    }

    /// `<root>/<name>.nidovm`.
    public func bundleURL(for name: VMName) -> URL {
        root.appendingPathComponent(name.rawValue + ".nidovm", isDirectory: true)
    }

    /// Creates the root (with intermediate directories) and enforces mode 0700 on it.
    public func ensureRoot() throws {
        try PrivateDirectory.ensure(root)
    }
}
