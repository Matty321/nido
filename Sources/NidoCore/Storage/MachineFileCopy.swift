// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation

/// Copies the files a VM is built from (disk, NVRAM) for snapshots, restores and clones:
/// flush, then `clonefile(2)` (copy-on-write on APFS), a sparse copy only on a volume that
/// cannot clone. Shared by `SnapshotStore` and `VMCloner`.
enum MachineFileCopy {
    /// Flushes `source` (a private regular file) to its file, then clones it to the new path
    /// `dest` (never overwritten, never through a symlink), falling back to a sparse copy only on
    /// a volume that cannot clone (or always with `forceCopy`, for tests); then 0600 and flushed.
    ///
    /// The `fsync` makes sure what Virtualization.framework has already written to the disk image
    /// is in the file before the clone. Writes a paused guest has issued that the framework
    /// still holds internally are not covered (no API flushes them); the guest sees the same
    /// disk after a restore of a saved state, which includes its own page cache.
    static func flushAndClone(_ source: URL, to dest: URL, forceCopy: Bool) throws {
        try verifyPrivateFile(source)
        let fd = Darwin.open(source.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw posixError() }
        let synced = fsync(fd) == 0
        let syncError = errno
        _ = Darwin.close(fd)
        guard synced else { throw POSIXError(POSIXErrorCode(rawValue: syncError) ?? .EIO) }
        if forceCopy || clonefile(source.path, dest.path, UInt32(CLONE_NOFOLLOW)) != 0 {
            let err = forceCopy ? ENOTSUP : errno
            guard err == ENOTSUP || err == EXDEV else { throw POSIXError(POSIXErrorCode(rawValue: err) ?? .EIO) }
            let flags = COPYFILE_DATA | COPYFILE_DATA_SPARSE | COPYFILE_EXCL | COPYFILE_NOFOLLOW
            guard copyfile(source.path, dest.path, nil, copyfile_flags_t(flags)) == 0 else {
                let copyError = errno
                try? FileManager.default.removeItem(at: dest)
                throw POSIXError(POSIXErrorCode(rawValue: copyError) ?? .EIO)
            }
        }
        try protect(dest)
    }

    /// Checks `url` with `PrivateFile` (regular, one link, this user), sets 0600 and flushes it.
    static func protect(_ url: URL) throws {
        let fd = try PrivateFile.open(url, flags: O_RDONLY, label: url.lastPathComponent)
        defer { _ = Darwin.close(fd) }
        guard fsync(fd) == 0 else { throw posixError() }
    }

    /// A regular file of this user with a single link, else `.unsafePath`.
    static func verifyPrivateFile(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
            info.st_uid == getuid(), info.st_nlink == 1
        else { throw NidoError.unsafePath(url.path) }
    }

    /// Bytes allocated to `url` (`st_blocks`): what a sparse copy of it takes.
    static func allocatedSize(_ url: URL) throws -> UInt64 {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw posixError() }
        return UInt64(max(0, info.st_blocks)) * 512
    }

    /// Writes `data` to the new file `url` (0600, exclusive, `PrivateFile`) and flushes it.
    static func writeNewFile(_ url: URL, data: Data) throws {
        let fd = try PrivateFile.open(url, flags: O_WRONLY | O_CREAT | O_EXCL, label: url.lastPathComponent)
        defer { _ = Darwin.close(fd) }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let n = Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw posixError()
                }
                offset += n
            }
        }
        guard fsync(fd) == 0 else { throw posixError() }
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
