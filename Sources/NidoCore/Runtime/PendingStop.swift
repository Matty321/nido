// SPDX-License-Identifier: Apache-2.0
import Foundation

/// A stop asked during a window in which the machine cannot act on it yet (a saved state being
/// restored: the session is still `.stopped`). The request is kept (`isRequested`) and the caller
/// waits until the window ends (`end()`), by when the owner has carried it out.
@MainActor
public final class PendingStop {
    /// True between `begin()` and `end()`.
    public private(set) var isActive = false
    /// True once a stop was asked during the window (stays true after `end()`).
    public private(set) var isRequested = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    /// Opens the window (a fresh one: no request yet).
    public func begin() {
        isActive = true
        isRequested = false
    }

    /// Records a stop and waits for `end()`; outside a window it records nothing and returns.
    public func requestAndWait() async {
        guard isActive else { return }
        isRequested = true
        await withCheckedContinuation { waiters.append($0) }
    }

    /// Closes the window and lets every waiting request return.
    public func end() {
        isActive = false
        let pending = waiters
        waiters = []
        for waiter in pending { waiter.resume() }
    }
}
