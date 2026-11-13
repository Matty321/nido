// SPDX-License-Identifier: Apache-2.0
import Foundation

/// A snapshot of a VM: `snapshots/<id>/meta.json` next to the cloned `disk.img` and `nvram.efi`
/// and, for a snapshot taken while the VM was running, its saved state `state.vzvmsave`.
/// See `SnapshotStore` and `docs/BUNDLE-FORMAT.md`.
public struct Snapshot: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    /// Same rules as a VM name (`^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$`, no `..`), unique per VM
    /// without regard to case.
    public var name: String
    public let createdAt: Date
    /// True when the snapshot holds `state.vzvmsave` (taken while the VM was running).
    public let hasSavedState: Bool
    /// For a saved state: the hash of the machine it was saved from, with the devices actually
    /// attached (`VMSession.attachedStateHash`, ruling R-M3A-12). Otherwise `stateHash()` of the
    /// config at the time (informational).
    public let configHash: String

    public init(id: UUID, name: String, createdAt: Date, hasSavedState: Bool, configHash: String) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.hasSavedState = hasSavedState
        self.configHash = configHash
    }

    /// Largest accepted `meta.json`.
    static let maxMetaSize = 64 * 1024

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    static func decode(_ data: Data) throws -> Snapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Snapshot.self, from: data)
    }
}
