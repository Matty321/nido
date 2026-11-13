// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Creates directories owned by the current user with mode 0700.
enum PrivateDirectory {
    /// Creates `url` and every missing ancestor with 0700 (pre-existing ancestors are left alone),
    /// verifies the directory is owned by the current user and enforces 0700 on it.
    static func ensure(_ url: URL) throws {
        let fm = FileManager.default
        var missing: [URL] = []
        var cursor = url.standardizedFileURL
        while !fm.fileExists(atPath: cursor.path) {
            missing.append(cursor)
            let parent = cursor.deletingLastPathComponent()
            if parent.path == cursor.path { break }
            cursor = parent
        }
        for dir in missing.reversed() {
            try fm.createDirectory(
                at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        }
        let attrs = try fm.attributesOfItem(atPath: url.path)
        if let owner = attrs[.ownerAccountID] as? NSNumber, owner.uint32Value != getuid() {
            throw NidoError.unsafePath(url.path)
        }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
}
