// SPDX-License-Identifier: Apache-2.0
import Foundation
import NidoCore
import Synchronization
import Testing

@testable import Nido

/// Waiting for snapshot work must never spin on the main actor: when the work ends, whoever
/// waits for it (start, stop, another snapshot operation) goes on, whatever order the main actor
/// runs the pieces in. Not main-actor isolated, so the deadline below still runs when the main
/// actor is stuck (a spinning waiter would otherwise hang the whole test run).
struct SnapshotWaitTests {
    enum Waiter: CaseIterable, Sendable { case start, stop, exclusive }

    /// Every waiter, with the work and the waiter at opposite priorities, and the waiter arriving
    /// before the gate opens or a few main-actor turns after it.
    @Test(arguments: Waiter.allCases)
    func waitersGoOnWhenTheSnapshotWorkEnds(_ waiter: Waiter) async throws {
        for (workPriority, waiterPriority) in [(TaskPriority.background, TaskPriority.high), (.high, .background)] {
            for turns in 0..<6 {
                let done = Mutex(false)
                let scenario = Task(priority: .background) { @MainActor in
                    let root = try SnapshotRoot()
                    let window = VMWindowModel(
                        name: try VMName("debian-13"), paths: root.paths, factory: FakeSessionFactory())
                    let gate = Gate()
                    let work = Task(priority: workPriority) { try await window.exclusive { await gate.wait() } }
                    while !window.isSnapshotting { await Task.yield() }
                    gate.open()
                    for _ in 0..<turns { await Task.yield() }
                    let wait = Task(priority: waiterPriority) { @MainActor in
                        switch waiter {
                        case .start: await window.start()
                        case .stop: await window.stop()
                        case .exclusive: _ = try? await window.exclusive {}
                        }
                    }
                    await wait.value
                    try await work.value
                    if waiter == .start { await window.stop() }
                    done.withLock { $0 = true }
                }
                let deadline = ContinuousClock.now.advanced(by: .seconds(10))
                while !done.withLock({ $0 }), ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(10))
                }
                guard done.withLock({ $0 }) else {
                    Issue.record("\(waiter) never went on (work \(workPriority), waiter \(waiterPriority), \(turns) turns)")
                    return
                }
                try await scenario.value
            }
        }
    }
}
