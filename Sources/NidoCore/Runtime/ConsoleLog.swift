// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation
import Synchronization

/// The guest's console.log, capped so a guest printing without end cannot fill the host disk:
/// at most `cap` bytes in console.log plus one rotated generation, `console.log.1` (so at most
/// 2 × `cap` on disk). When the next write would pass the cap, console.log is renamed to
/// console.log.1 (replacing it; a symlink there is replaced, never followed) and a new
/// console.log is opened with the same rules (`PrivateFile`: regular file, one link, owned by the
/// user, 0600). Writing is best effort: a full disk or a failed reopen stops logging, never the
/// console.
final class ConsoleLog: Sendable {
    /// 16 MiB per generation.
    static let defaultCap = 16 << 20

    let url: URL
    let rotatedURL: URL
    let cap: Int

    private struct State {
        var fd: Int32
        var size: Int
    }

    private let state: Mutex<State>

    /// Opens (or creates) `url` in append mode; refuses an unsafe file (`NidoError.unsafePath`).
    init(url: URL, cap: Int = ConsoleLog.defaultCap) throws {
        precondition(cap > 0)
        self.url = url
        self.rotatedURL = url.deletingLastPathComponent()
            .appendingPathComponent(url.lastPathComponent + ".1", isDirectory: false)
        self.cap = cap
        let fd = try Self.openLog(url)
        var info = stat()
        let size = fstat(fd, &info) == 0 ? Int(info.st_size) : 0
        state = Mutex(State(fd: fd, size: size))
    }

    deinit {
        close()
    }

    /// Appends `data`, rotating first when it would not fit; a chunk larger than the cap keeps
    /// only its last `cap` bytes.
    func write(_ data: Data) {
        guard !data.isEmpty else { return }
        let bytes = data.count > cap ? data.suffix(cap) : data
        state.withLock { s in
            guard s.fd >= 0 else { return }
            if s.size + bytes.count > cap { rotate(&s) }
            guard s.fd >= 0 else { return }
            s.size += Self.writeAll(s.fd, bytes)
        }
    }

    func close() {
        state.withLock { s in
            if s.fd >= 0 { _ = Darwin.close(s.fd) }
            s.fd = -1
        }
    }

    private func rotate(_ s: inout State) {
        if s.size > cap {
            // Left over larger than the cap (written before the cap existed): emptied, so the
            // rotated generation never exceeds the cap either.
            if ftruncate(s.fd, 0) == 0 {
                s.size = 0
                return
            }
        } else if Darwin.rename(url.path, rotatedURL.path) == 0 {
            _ = Darwin.close(s.fd)
            s.fd = (try? Self.openLog(url)) ?? -1
            s.size = 0
            return
        }
        // The rename (or truncate) failed: empty the current file rather than pass the cap.
        if ftruncate(s.fd, 0) == 0 {
            s.size = 0
        } else {
            _ = Darwin.close(s.fd)
            s.fd = -1
        }
    }

    private static func openLog(_ url: URL) throws -> Int32 {
        try PrivateFile.open(url, flags: O_WRONLY | O_CREAT | O_APPEND, label: url.lastPathComponent)
    }

    /// Bytes written (stops at the first error other than EINTR).
    private static func writeAll(_ fd: Int32, _ data: Data) -> Int {
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n > 0 {
                    offset += n
                } else if n < 0, errno == EINTR {
                    continue
                } else {
                    break
                }
            }
            return offset
        }
    }
}
