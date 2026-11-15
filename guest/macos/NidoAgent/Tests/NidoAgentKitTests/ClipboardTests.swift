// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import NidoAgentKit

/// A pasteboard in memory: what was written, whether it is marked concealed, and a change count
/// that moves like `NSPasteboard`'s.
@MainActor
private final class FakePasteboard: GuestPasteboard {
    private(set) var changeCount = 0
    private(set) var text: String?
    private(set) var concealed = false
    private(set) var clears = 0

    func writeConcealed(_ text: String) -> Int {
        changeCount += 1
        self.text = text
        concealed = true
        return changeCount
    }

    func clearContents() {
        changeCount += 1
        text = nil
        concealed = false
        clears += 1
    }

    /// Another app copies something.
    func copyElsewhere(_ text: String) {
        changeCount += 1
        self.text = text
        concealed = false
    }
}

/// The clock: records each delayed action, runs them when the test says.
@MainActor
private final class ManualClock {
    private(set) var delays: [Int] = []
    private var actions: [@MainActor () -> Void] = []

    var schedule: ClipboardSetter.Schedule {
        { [self] seconds, action in
            delays.append(seconds)
            actions.append(action)
        }
    }

    func fire() {
        let pending = actions
        actions = []
        for action in pending { action() }
    }
}

@MainActor
@Suite struct ClipboardTests {
    @Test func writesConcealedAndClearsAfterTheDelay() async {
        let pasteboard = FakePasteboard()
        let clock = ManualClock()
        let setter = ClipboardSetter(pasteboard: pasteboard, schedule: clock.schedule)
        await setter.set("abcde-fghjk", clearAfter: 60)
        #expect(pasteboard.text == "abcde-fghjk")
        #expect(pasteboard.concealed)
        #expect(clock.delays == [60])
        #expect(pasteboard.clears == 0)
        clock.fire()
        #expect(pasteboard.text == nil)
        #expect(pasteboard.clears == 1)
    }

    /// The user (or another app) copied something else meanwhile: that is not cleared.
    @Test func keepsWhatWasCopiedAfter() async {
        let pasteboard = FakePasteboard()
        let clock = ManualClock()
        let setter = ClipboardSetter(pasteboard: pasteboard, schedule: clock.schedule)
        await setter.set("abcde-fghjk", clearAfter: 60)
        pasteboard.copyElsewhere("notes")
        clock.fire()
        #expect(pasteboard.text == "notes")
        #expect(pasteboard.clears == 0)
    }

    /// A second copy before the first one's delay: only the second one's clear acts.
    @Test func anOlderClearLeavesANewerCopy() async {
        let pasteboard = FakePasteboard()
        let clock = ManualClock()
        let setter = ClipboardSetter(pasteboard: pasteboard, schedule: clock.schedule)
        await setter.set("first", clearAfter: 60)
        await setter.set("second", clearAfter: 60)
        clock.fire()
        #expect(pasteboard.text == nil)
        #expect(pasteboard.clears == 1)
    }
}
