// SPDX-License-Identifier: Apache-2.0
import Dispatch
import Foundation
import NidoCore
import Synchronization

/// `nido start --console`: copies the guest's console output, sanitised (`ConsoleSanitizer`: no
/// escape sequence reaches the terminal), to stdout.
///
/// The writes are blocking and run on a private dispatch queue, never on a Swift concurrency
/// thread: a stdout that does not drain (a pipe nobody reads, a terminal stopped with Ctrl-S)
/// stalls only that queue. `finish(within:)` bounds the wait at the end, so the CLI releases the
/// bundle lock and exits shortly after the VM stopped whatever stdout does.
public final class ConsoleMirror: Sendable {
    /// How long `nido start` waits for the mirror after the VM stopped.
    public static let finishTimeout = Duration.seconds(2)

    private let task: Task<Void, Never>

    /// Starts copying `output` with `write` (default: stdout) until the stream ends.
    public init(
        output: AsyncStream<Data>,
        write: @escaping @Sendable (Data) -> Void = { try? FileHandle.standardOutput.write(contentsOf: $0) }
    ) {
        let queue = DispatchQueue(label: "io.gitlab.pichierri.Nido.console-mirror")
        task = Task.detached {
            var sanitizer = ConsoleSanitizer()
            for await chunk in output {
                let clean = sanitizer.sanitize(chunk)
                guard !clean.isEmpty else { continue }
                // One write at a time, in order; a blocked write suspends this task only.
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    queue.async {
                        write(clean)
                        continuation.resume()
                    }
                }
            }
        }
    }

    /// Waits until everything read so far is written (the stream must have ended), at most
    /// `timeout`. True when the mirror finished; false when stdout is still blocked (what is left
    /// is dropped: the process is about to exit).
    public func finish(within timeout: Duration) async -> Bool {
        await finish(within: timeout, sleep: { try? await Task.sleep(for: $0) })
    }

    /// `finish` with the timer's sleep injectable (tests check it is cancelled).
    func finish(within timeout: Duration, sleep: @escaping @Sendable (Duration) async -> Void) async -> Bool {
        let task = self.task
        let outcome = Mutex<CheckedContinuation<Bool, Never>?>(nil)
        @Sendable func answer(_ value: Bool) {
            outcome.withLock { continuation in
                continuation?.resume(returning: value)
                continuation = nil
            }
        }
        return await withCheckedContinuation { continuation in
            outcome.withLock { $0 = continuation }
            let timer = Task.detached {
                await sleep(timeout)
                answer(false)
            }
            Task.detached {
                await task.value
                answer(true)
                // The answer is given: the timer has nothing left to do.
                timer.cancel()
            }
        }
    }
}
