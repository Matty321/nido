// SPDX-License-Identifier: Apache-2.0
import Foundation
import Synchronization

/// Which kind of process holds a bundle lock.
public enum LockOwner: String, Sendable {
    /// `nido start`: the process runs the VM (also every "cli" line of older versions).
    case cli
    /// The app.
    case app
    /// A `nido` maintenance command (snapshot, clone, share, rosetta, delete): it runs no VM and
    /// is never signalled by `nido stop` (ruling R-M3A-24).
    case cliOperation = "cli-op"
}

/// The process currently holding a bundle lock.
public struct LockHolder: Equatable, Sendable {
    public let pid: Int32
    public let owner: LockOwner

    public init(pid: Int32, owner: LockOwner) {
        self.pid = pid
        self.owner = owner
    }
}

/// Exclusive per-bundle lock based on `flock(2)` on `<bundle>/.lock`.
/// The holder writes `"<pid> <owner>\n"` in the file. The file is never deleted (avoids unlink
/// races): a leftover file with no lock held means a crashed holder, which is treated as "not running".
public final class BundleLock: Sendable {
    private let fd: Int32
    private let released = Mutex<Bool>(false)

    private init(fd: Int32) {
        self.fd = fd
    }

    deinit {
        release()
    }

    /// Takes the lock without blocking; throws `.alreadyRunning(pid:)` if another holder has it
    /// (pid -1 when the holder's PID cannot be read). A failure with `EWOULDBLOCK` is retried
    /// up to `contentionRetries` times, `contentionDelay` apart: a concurrent `holder` probe
    /// (`LOCK_SH`) is brief and must not look like a real holder. The file content cannot tell the
    /// two apart, since after a release it is empty after a clean release but keeps the PID of a
    /// crashed holder. Sleeps its thread between attempts (`usleep`): for the CLI; the app uses
    /// `acquireAsync`.
    public static func acquire(_ b: VMBundle, owner: LockOwner) throws -> BundleLock {
        let fd = try openLockFile(b)
        var attempt = 0
        while true {
            if let lock = try attemptLock(fd, owner: owner, retrying: attempt < contentionRetries) {
                return lock
            }
            attempt += 1
            usleep(contentionDelayMicroseconds)
        }
    }

    /// `acquire` for the app: the same attempts and outcomes, but the retries wait with
    /// `Task.sleep`, so the calling actor (the main actor) is never blocked. Cancelled during a
    /// wait, it gives up without the lock and throws `CancellationError`.
    public static func acquireAsync(_ b: VMBundle, owner: LockOwner) async throws -> BundleLock {
        let fd = try openLockFile(b)
        var attempt = 0
        while true {
            if let lock = try attemptLock(fd, owner: owner, retrying: attempt < contentionRetries) {
                return lock
            }
            attempt += 1
            do {
                try await Task.sleep(for: .microseconds(contentionDelayMicroseconds))
            } catch {
                _ = Darwin.close(fd)
                throw error
            }
        }
    }

    /// How often, and how far apart, a lock held by a brief `holder` probe is tried again.
    static let contentionRetries = 3
    static let contentionDelayMicroseconds: useconds_t = 20_000

    /// A symlink, FIFO, hard link or foreign file at `.lock` is refused (`.unsafePath`).
    private static func openLockFile(_ b: VMBundle) throws -> Int32 {
        try PrivateFile.open(b.lockURL, flags: O_RDWR | O_CREAT, label: ".lock")
    }

    /// One non-blocking attempt on the open `.lock`: the lock, or nil when it is busy and
    /// `retrying` (the caller waits and tries again). Any other outcome closes `fd` and throws.
    private static func attemptLock(_ fd: Int32, owner: LockOwner, retrying: Bool) throws -> BundleLock? {
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let err = errno
            if err == EWOULDBLOCK, retrying { return nil }
            let pid = err == EWOULDBLOCK ? (readHolder(fd)?.pid ?? -1) : nil
            _ = Darwin.close(fd)
            if let pid { throw NidoError.alreadyRunning(pid: pid) }
            throw POSIXError(POSIXErrorCode(rawValue: err) ?? .EIO)
        }
        let line = Array("\(getpid()) \(owner.rawValue)\n".utf8)
        // Write first, then truncate to the written length: no window with an empty file.
        let ok = line.withUnsafeBytes { pwrite(fd, $0.baseAddress, $0.count, 0) } == line.count
            && ftruncate(fd, off_t(line.count)) == 0
        guard ok else {
            let err = errno
            _ = flock(fd, LOCK_UN)
            _ = Darwin.close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: err) ?? .EIO)
        }
        return BundleLock(fd: fd)
    }

    /// The process currently holding the lock, or nil if nobody holds it. Never blocks.
    /// If the lock is held but the line cannot be read, returns pid -1 with owner `.cli`
    /// (held always means running). A line with only a PID (older format) is a `.cli` holder.
    /// Anything but a regular file at `.lock` (which `acquire` refuses) reads as not held.
    public static func holder(_ b: VMBundle) -> LockHolder? {
        // O_NONBLOCK: never hang on a FIFO planted at `.lock`.
        let fd = Darwin.open(b.lockURL.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { _ = Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        if flock(fd, LOCK_SH | LOCK_NB) == 0 {
            _ = flock(fd, LOCK_UN)
            return nil
        }
        guard errno == EWOULDBLOCK else { return nil }
        return readHolder(fd) ?? LockHolder(pid: -1, owner: .cli)
    }

    /// Releases the lock (idempotent). The lock file is left in place, emptied first (while the
    /// lock is still held): a released lock never shows a stale PID.
    public func release() {
        let alreadyReleased = released.withLock { done in
            defer { done = true }
            return done
        }
        guard !alreadyReleased else { return }
        _ = ftruncate(fd, 0)
        _ = flock(fd, LOCK_UN)
        _ = Darwin.close(fd)
    }

    private static func readHolder(_ fd: Int32) -> LockHolder? {
        var buf = [UInt8](repeating: 0, count: 32)
        let n = buf.withUnsafeMutableBytes { pread(fd, $0.baseAddress, $0.count, 0) }
        guard n > 0 else { return nil }
        let fields = String(decoding: buf[0..<n], as: UTF8.self)
            .split(whereSeparator: \.isWhitespace)
        guard let first = fields.first, let pid = Int32(first), pid > 0 else { return nil }
        let owner = fields.dropFirst().first.flatMap { LockOwner(rawValue: String($0)) } ?? .cli
        return LockHolder(pid: pid, owner: owner)
    }
}
