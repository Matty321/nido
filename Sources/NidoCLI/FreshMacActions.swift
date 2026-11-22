// SPDX-License-Identifier: Apache-2.0
import Foundation
import NidoAgentKit
import NidoCore
import Synchronization

/// The readiness gate of `nido mcp --fresh`: the MCP server answers `initialize` at once, while
/// the copy still boots, and each tool call waits here until Nido Agent in the copy answers
/// `status`, at most until `deadline` (`FreshMac.readinessLimit` after the child's launch). Once
/// the copy is ready it never probes again and forwards every call to `inner`. A child that has
/// ended fails every call at once, also after readiness.
public final class FreshMacActions: AgentActions {
    private let inner: any AgentActions
    private let deadline: ContinuousClock.Instant
    private let childEnded: @Sendable () -> String?
    private let notReadyHint: String
    private let poll: Duration
    private let probeTimeout: Duration
    private let now: @Sendable () -> ContinuousClock.Instant
    private let sleep: @Sendable (Duration) -> Void
    /// True once a probe got Nido Agent's status.
    private let ready = Mutex(false)

    /// `childEnded` is nil while the child runs, otherwise why it ended (the `notRunning` message);
    /// `notReadyHint` is the `notReady` message past the deadline.
    public init(
        inner: any AgentActions, deadline: ContinuousClock.Instant, childEnded: @escaping @Sendable () -> String?,
        notReadyHint: String, poll: Duration = .seconds(2), probeTimeout: Duration = .seconds(5),
        now: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
        sleep: @escaping @Sendable (Duration) -> Void = { duration in
            let parts = duration.components
            Thread.sleep(forTimeInterval: TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18)
        }
    ) {
        self.inner = inner
        self.deadline = deadline
        self.childEnded = childEnded
        self.notReadyHint = notReadyHint
        self.poll = poll
        self.probeTimeout = probeTimeout
        self.now = now
        self.sleep = sleep
    }

    public func send(_ action: AgentAction) throws -> AgentAnswer {
        try waitUntilReady()
        return try inner.send(action)
    }

    public func send(_ action: AgentAction, timeout: Duration) throws -> AgentAnswer {
        try waitUntilReady()
        return try inner.send(action, timeout: timeout)
    }

    public func putFile(_ data: Data, to path: String) throws -> AgentAnswer {
        try waitUntilReady()
        return try inner.putFile(data, to: path)
    }

    public func getFile(_ path: String, maxBytes: Int) throws -> (AgentAnswer, Data?) {
        try waitUntilReady()
        return try inner.getFile(path, maxBytes: maxBytes)
    }

    /// Returns once Nido Agent answers `status`: probes every `poll` until `deadline`, then
    /// throws `notReady` after one more probe. Throws `notRunning` as soon as the child has ended.
    private func waitUntilReady() throws {
        while true {
            if let reason = childEnded() { throw AgentFailure(code: .notRunning, message: reason) }
            if ready.withLock({ $0 }) { return }
            if probe() {
                ready.withLock { $0 = true }
                return
            }
            guard now() < deadline else { throw AgentFailure(code: .notReady, message: notReadyHint) }
            sleep(poll)
        }
    }

    /// True when Nido Agent answered `status` with its status; any error is "not yet".
    private func probe() -> Bool {
        guard let answer = try? inner.send(.status, timeout: probeTimeout) else { return false }
        return answer.ok && answer.status != nil
    }
}
