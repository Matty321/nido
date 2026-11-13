// SPDX-License-Identifier: Apache-2.0
import Foundation
import NidoCore
import Synchronization

/// The one-line progress of `nido create` (the download, or the installation of macOS), rewritten
/// in place with `\r` (a percentage when the size is known, else the MiB received so far).
/// `finish()` ends the line with a newline once, if anything was shown: call it on every exit
/// path (`defer`), so an error message never lands on the progress line. Every write happens
/// under the lock: a report that races with `finish()` is either written before the newline or
/// dropped, never after it.
public final class ProgressLine: Sendable {
    private let write: @Sendable (String) -> Void
    private let state = Mutex((shown: false, finished: false))

    public init(write: @escaping @Sendable (String) -> Void = { FileHandle.standardError.write(Data($0.utf8)) }) {
        self.write = write
    }

    public func show(_ progress: DownloadProgress) {
        let text: String
        if let total = progress.expectedBytes, total > 0 {
            let percent = min(100, Int(progress.receivedBytes * 100 / total))
            text = L10n.string("Download: \(percent)% (\(ByteSize.format(progress.receivedBytes)) / \(ByteSize.format(total)))")
        } else {
            text = L10n.string("Download: \(Int(progress.receivedBytes >> 20)) MiB")
        }
        show(text: text)
    }

    /// The installation of macOS `version`: "Installing macOS 26.1: 42%" (`fraction` 0...1,
    /// rounded down, clamped).
    public func show(installing version: String, fraction: Double) {
        let percent = fraction.isFinite ? Int(min(1, max(0, fraction)) * 100) : 0
        show(text: L10n.string("Installing macOS \(version): \(percent)%"))
    }

    private func show(text: String) {
        state.withLock { s in
            guard !s.finished else { return }
            s.shown = true
            write("\r" + text)
        }
    }

    public func finish() {
        state.withLock { s in
            defer { s.finished = true }
            if s.shown && !s.finished { write("\n") }
        }
    }
}
