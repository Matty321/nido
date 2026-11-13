// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation

/// Opens the bundle files Nido writes to (`.lock`, console.log, `known_hosts`) so that a file
/// planted in their place is refused instead of written: no symlink (O_NOFOLLOW), no FIFO or
/// device (O_NONBLOCK, then a regular-file check: opening never blocks), no hard link to another
/// file (`st_nlink == 1`) and nothing owned by someone else. The descriptor is then made blocking
/// again and its mode set to 0600.
enum PrivateFile {
    /// Returns an open descriptor (close-on-exec) or throws `NidoError.unsafePath(label)` for an
    /// unsafe file; other failures are `POSIXError`s. `flags` are the access and creation flags
    /// (e.g. `O_WRONLY | O_CREAT | O_APPEND`).
    static func open(_ url: URL, flags: Int32, label: String) throws -> Int32 {
        let fd = Darwin.open(url.path, flags | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            let err = errno
            // ELOOP: a symlink. ENXIO: a FIFO without a reader (write-only, non-blocking open).
            if err == ELOOP || err == ENXIO || err == EOPNOTSUPP { throw NidoError.unsafePath(label) }
            throw POSIXError(POSIXErrorCode(rawValue: err) ?? .EIO)
        }
        do {
            try check(fd, label: label)
            let current = fcntl(fd, F_GETFL)
            guard current >= 0, fcntl(fd, F_SETFL, current & ~O_NONBLOCK) == 0, fchmod(fd, 0o600) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            return fd
        } catch {
            _ = Darwin.close(fd)
            throw error
        }
    }

    /// Replaces `url` atomically with `data`: a temporary file next to it (`.<name>.<uuid>.tmp`,
    /// created exclusively through `open`, 0600), written and synced, then renamed over `url`.
    /// `rename(2)` replaces whatever entry is at `url` (a planted symlink included) and never
    /// writes through it. On failure the temporary file is removed and `url` is unchanged.
    static func writeAtomically(_ data: Data, to url: URL) throws {
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            let fd = try open(temporary, flags: O_WRONLY | O_CREAT | O_EXCL, label: temporary.lastPathComponent)
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            try handle.write(contentsOf: data)
            guard fsync(fd) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            try handle.close()
            guard Darwin.rename(temporary.path, url.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            _ = Darwin.unlink(temporary.path)
            throw error
        }
    }

    /// Regular file, one link, owned by this user.
    static func check(_ fd: Int32, label: String) throws {
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1, info.st_uid == getuid() else {
            throw NidoError.unsafePath(label)
        }
    }
}
