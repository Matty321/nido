// SPDX-License-Identifier: Apache-2.0
import Testing
@testable import NidoCore

@Suite struct VMRunStateTests {
    @Test func sameStateDoesNotNotify() {
        #expect(!VMRunState.transition(from: .running, to: .running))
        #expect(!VMRunState.transition(from: .error("x"), to: .error("x")))
        #expect(!VMRunState.transition(from: .paused, to: .paused))
    }

    @Test func differentStateNotifies() {
        #expect(VMRunState.transition(from: .running, to: .pausing))
        #expect(VMRunState.transition(from: .pausing, to: .paused))
        #expect(VMRunState.transition(from: .paused, to: .resuming))
        #expect(VMRunState.transition(from: .error("x"), to: .error("y")))
    }
}

@Suite struct VMRunStateFailureTests {
    @Test func failureOnlyOverwritesOwnTransitionalState() {
        #expect(VMRunState.pausing.afterFailure(of: .pausing, message: "x") == .error("x"))
        #expect(VMRunState.resuming.afterFailure(of: .resuming, message: "x") == .error("x"))
        // The guest stopped or a stop() took over while the call was pending: keep that state.
        #expect(VMRunState.stopped.afterFailure(of: .pausing, message: "x") == .stopped)
        #expect(VMRunState.error("real").afterFailure(of: .resuming, message: "x") == .error("real"))
        #expect(VMRunState.stopping.afterFailure(of: .pausing, message: "x") == .stopping)
    }

    @Test func stopAcceptedFromTransitionalStates() {
        for s in [VMRunState.running, .starting, .paused, .pausing, .resuming] { #expect(s.acceptsStop) }
        for s in [VMRunState.stopped, .stopping, .error("x")] { #expect(!s.acceptsStop) }
    }
}
