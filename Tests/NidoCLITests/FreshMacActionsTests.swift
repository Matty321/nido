// SPDX-License-Identifier: Apache-2.0
import Foundation
import NidoAgentKit
import Synchronization
import Testing
@testable import NidoCLI
@testable import NidoCore

/// `FreshMacActions`, the readiness gate of `nido mcp --fresh`: a fake inner `AgentActions` whose
/// `status` probes (`send(_:timeout:)`) answer from a script, and a fake clock that only `sleep`
/// moves.
@Suite(.italian) struct FreshMacActionsTests {
    /// The inner actions: `send(_:timeout:)` is the probe and answers from `probes` (the last
    /// entry repeats); everything else is forwarded and recorded.
    final class FakeInner: AgentActions {
        enum Probe { case ok, noStatus, fails(AgentErrorCode) }

        private struct State {
            var probes: [Probe]
            var probeCount = 0
            var probeTimeouts: [Duration] = []
            var forwarded: [AgentAction] = []
            var puts: [String] = []
            var gets: [String] = []
        }

        private let state: Mutex<State>

        init(_ probes: [Probe]) { state = Mutex(State(probes: probes)) }

        var probeCount: Int { state.withLock { $0.probeCount } }
        var probeTimeouts: [Duration] { state.withLock { $0.probeTimeouts } }
        var forwarded: [AgentAction] { state.withLock { $0.forwarded } }
        var puts: [String] { state.withLock { $0.puts } }
        var gets: [String] { state.withLock { $0.gets } }

        func send(_ action: AgentAction) throws -> AgentAnswer {
            state.withLock { $0.forwarded.append(action) }
            return AgentAnswer(ok: true)
        }

        func send(_ action: AgentAction, timeout: Duration) throws -> AgentAnswer {
            let probe: Probe = state.withLock {
                #expect(action == .status)
                $0.probeTimeouts.append(timeout)
                let next = $0.probes[min($0.probeCount, $0.probes.count - 1)]
                $0.probeCount += 1
                return next
            }
            switch probe {
            case .ok:
                return AgentAnswer(ok: true, status: AgentStatus(
                    helperVersion: "1", protocolVersion: 1, screenRecording: true, accessibility: true,
                    screen: ScreenSize(width: 1, height: 1)))
            case .noStatus:
                return AgentAnswer(ok: true)
            case .fails(let code):
                throw AgentFailure(code: code, message: "not yet")
            }
        }

        func putFile(_ data: Data, to path: String) throws -> AgentAnswer {
            state.withLock { $0.puts.append(path) }
            return AgentAnswer(ok: true)
        }

        func getFile(_ path: String, maxBytes: Int) throws -> (AgentAnswer, Data?) {
            state.withLock { $0.gets.append(path) }
            return (AgentAnswer(ok: true), Data("x".utf8))
        }
    }

    /// A clock that `sleep` moves forward; `slept` adds up every sleep.
    final class FakeClock: Sendable {
        private let state: Mutex<(now: ContinuousClock.Instant, slept: Duration)>

        init(_ start: ContinuousClock.Instant) { state = Mutex((start, .zero)) }

        var now: ContinuousClock.Instant { state.withLock { $0.now } }
        var slept: Duration { state.withLock { $0.slept } }

        func sleep(_ duration: Duration) {
            state.withLock {
                $0.now += duration
                $0.slept += duration
            }
        }
    }

    /// A child that runs until `end(_:)` gives the reason it ended.
    final class ChildState: Sendable {
        private let reason = Mutex<String?>(nil)
        var value: String? { reason.withLock { $0 } }
        func end(_ text: String) { reason.withLock { $0 = text } }
    }

    private let hint = "not ready hint"
    private let start = ContinuousClock.now

    private func gate(
        _ inner: FakeInner, clock: FakeClock, child: ChildState = ChildState(), deadline: Duration = .seconds(180)
    ) -> FreshMacActions {
        FreshMacActions(
            inner: inner, deadline: start + deadline, childEnded: { child.value }, notReadyHint: hint,
            now: { clock.now }, sleep: { clock.sleep($0) })
    }

    @Test func waitsUntilStatusAnswers() throws {
        let inner = FakeInner([.fails(.notRunning), .fails(.notRunning), .ok])
        let clock = FakeClock(start)
        let actions = gate(inner, clock: clock)

        _ = try actions.send(.click(x: 1, y: 2, button: .left, count: 1))
        #expect(inner.probeCount == 3)
        #expect(inner.probeTimeouts == [.seconds(5), .seconds(5), .seconds(5)])
        #expect(clock.slept == .seconds(4))
        #expect(inner.forwarded == [.click(x: 1, y: 2, button: .left, count: 1)])

        _ = try actions.send(.screenshot(maxLongEdge: 800))
        #expect(inner.probeCount == 3)
        #expect(inner.forwarded.count == 2)
    }

    /// An answer without a status (an old owner, a `status` the guest left empty) is not ready.
    @Test func okWithoutStatusIsNotReady() throws {
        let inner = FakeInner([.noStatus, .ok])
        let actions = gate(inner, clock: FakeClock(start))
        _ = try actions.send(.click(x: 1, y: 2, button: .left, count: 1))
        #expect(inner.probeCount == 2)
    }

    @Test func failsWithTheHintPastTheDeadline() throws {
        let inner = FakeInner([.fails(.notReady)])
        let clock = FakeClock(start)
        let actions = gate(inner, clock: clock)

        #expect(throws: AgentFailure(code: .notReady, message: hint)) {
            _ = try actions.send(.click(x: 1, y: 2, button: .left, count: 1))
        }
        #expect(inner.forwarded.isEmpty)
        #expect(clock.slept >= .seconds(180))
        #expect(clock.slept < .seconds(184))
        #expect(inner.probeCount == 91)
    }

    @Test func afterTheDeadlineOneProbeThenRuns() throws {
        let inner = FakeInner([.ok])
        let clock = FakeClock(start + .seconds(500))
        let actions = gate(inner, clock: clock)

        _ = try actions.send(.click(x: 1, y: 2, button: .left, count: 1))
        #expect(inner.probeCount == 1)
        #expect(clock.slept == .zero)
        #expect(inner.forwarded.count == 1)
    }

    @Test func afterTheDeadlineOneProbeThenFails() throws {
        let inner = FakeInner([.fails(.timeout)])
        let clock = FakeClock(start + .seconds(500))
        let actions = gate(inner, clock: clock)

        #expect(throws: AgentFailure(code: .notReady, message: hint)) {
            _ = try actions.send(.status)
        }
        #expect(inner.probeCount == 1)
        #expect(clock.slept == .zero)
    }

    @Test func childEndedFailsFast() throws {
        let inner = FakeInner([.ok])
        let clock = FakeClock(start)
        let child = ChildState()
        child.end("x")
        let actions = gate(inner, clock: clock, child: child)

        #expect(throws: AgentFailure(code: .notRunning, message: "x")) {
            _ = try actions.send(.click(x: 1, y: 2, button: .left, count: 1))
        }
        #expect(throws: AgentFailure(code: .notRunning, message: "x")) {
            _ = try actions.putFile(Data(), to: "a")
        }
        #expect(inner.probeCount == 0)
        #expect(inner.forwarded.isEmpty && inner.puts.isEmpty)
    }

    @Test func childEndedFailsAlsoOnceReady() throws {
        let inner = FakeInner([.ok])
        let child = ChildState()
        let actions = gate(inner, clock: FakeClock(start), child: child)
        _ = try actions.send(.status)
        #expect(inner.forwarded == [.status])

        child.end("x")
        #expect(throws: AgentFailure(code: .notRunning, message: "x")) {
            _ = try actions.send(.status, timeout: .seconds(1))
        }
        #expect(throws: AgentFailure(code: .notRunning, message: "x")) {
            _ = try actions.getFile("a", maxBytes: 10)
        }
        #expect(inner.forwarded == [.status])
        #expect(inner.gets.isEmpty)
    }

    /// The child ending during the wait stops it at once: no wait for the deadline.
    @Test func childEndingWhileWaitingStopsTheWait() throws {
        let inner = FakeInner([.fails(.notRunning)])
        let clock = FakeClock(start)
        let child = ChildState()
        let actions = FreshMacActions(
            inner: inner, deadline: start + .seconds(180), childEnded: { child.value }, notReadyHint: hint,
            now: { clock.now },
            sleep: { duration in
                clock.sleep(duration)
                if clock.slept >= .seconds(6) { child.end("gone") }
            })

        #expect(throws: AgentFailure(code: .notRunning, message: "gone")) {
            _ = try actions.send(.click(x: 1, y: 2, button: .left, count: 1))
        }
        #expect(inner.probeCount == 3)
    }

    @Test func filesAreGatedToo() throws {
        let inner = FakeInner([.fails(.notRunning), .ok])
        let clock = FakeClock(start)
        let actions = gate(inner, clock: clock)

        _ = try actions.putFile(Data("a".utf8), to: "in.txt")
        #expect(inner.probeCount == 2)
        #expect(inner.puts == ["in.txt"])
        let (_, data) = try actions.getFile("out.txt", maxBytes: 10)
        #expect(data == Data("x".utf8))
        #expect(inner.gets == ["out.txt"])
        #expect(inner.probeCount == 2)

        let fresh = FakeInner([.fails(.notRunning), .ok])
        let other = gate(fresh, clock: FakeClock(start))
        _ = try other.getFile("out.txt", maxBytes: 10)
        #expect(fresh.probeCount == 2)
        #expect(fresh.gets == ["out.txt"])
    }

    /// `send(_:timeout:)` is forwarded with its own timeout once ready.
    @Test func timedSendIsForwarded() throws {
        let inner = FakeInner([.ok])
        let actions = gate(inner, clock: FakeClock(start))
        _ = try actions.send(.status, timeout: .seconds(9))
        #expect(inner.probeTimeouts == [.seconds(5), .seconds(9)])
    }
}
