// SPDX-License-Identifier: Apache-2.0
import Darwin
import Dispatch
import Synchronization

/// Tells when a process ends, also by SIGKILL: `nido start --parent-pid` stops its VM when the
/// process that started it (the fresh launcher of `nido mcp --fresh`) is gone. A kqueue
/// `NOTE_EXIT` watch (`DispatchSource.makeProcessSource`); a process already gone when the watch
/// starts counts as ended. `onExit` runs on `queue`, at most once, and never once `cancel()` ran.
public final class ParentExitWatch: Sendable {
    private struct State {
        var source: (any DispatchSourceProcess)?
        /// Fired or cancelled: nothing more happens.
        var done = false
    }

    private let pid: pid_t
    private let queue: DispatchQueue
    private let onExit: @Sendable () -> Void
    private let state = Mutex(State())

    public init(pid: pid_t, queue: DispatchQueue, onExit: @escaping @Sendable () -> Void) {
        self.pid = pid
        self.queue = queue
        self.onExit = onExit
    }

    deinit {
        cancel()
    }

    /// Starts watching; a second call, or one after `cancel()`, changes nothing.
    public func start() {
        // Made only when it is resumed: libdispatch traps on the release of a source never resumed.
        let made: (any DispatchSourceProcess)? = state.withLock { state in
            guard !state.done, state.source == nil else { return nil }
            let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
            source.setEventHandler { [weak self] in self?.fire() }
            state.source = source
            return source
        }
        guard let source = made else { return }
        source.resume()
        // Gone before the watch was registered: no NOTE_EXIT comes for it. Checked after
        // `resume()`, so an exit in between is seen one way or the other (`fire` runs once).
        if kill(pid, 0) == -1 && errno == ESRCH {
            queue.async { [weak self] in self?.fire() }
        }
    }

    /// Stops watching: `onExit` is not called after this.
    public func cancel() {
        let source = state.withLock { state in
            state.done = true
            defer { state.source = nil }
            return state.source
        }
        source?.cancel()
    }

    private func fire() {
        let fires = state.withLock { state in
            guard !state.done else { return false }
            state.done = true
            return true
        }
        guard fires else { return }
        cancel()
        onExit()
    }
}
