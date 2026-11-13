// SPDX-License-Identifier: Apache-2.0
import Foundation
import NidoCore
import Observation

/// The guest's serial console as the window sees it: `SerialConsole` for a real VM, a fake in
/// DEBUG `-NidoFakeSessions` and in the unit tests.
protocol GuestConsole: AnyObject, Sendable {
    /// Guest → host bytes (single consumer), already coalesced into chunks.
    var output: AsyncStream<Data> { get }
    /// Host → guest bytes; returns at once.
    func send(_ data: Data)
}

extension SerialConsole: GuestConsole {}

/// The terminal of one VM session: reads the guest's output into a `TerminalBuffer` on the main
/// actor and forwards the user's keys to the guest. `SerialConsole` coalesces output to about 60
/// chunks per second, but flushes at once when a chunk is full, so each chunk is parsed in
/// slices of `sliceBytes` that give the main actor back in between. The only automatic bytes to the guest are the
/// buffer's DSR 5n/6n replies (R-M2-35), sent only while `isRunning()`.
@MainActor
@Observable
final class TerminalModel {
    private(set) var buffer = TerminalBuffer()

    @ObservationIgnored private let console: any GuestConsole
    @ObservationIgnored private var reader: Task<Void, Never>?
    @ObservationIgnored private let isRunning: () -> Bool

    init(console: any GuestConsole, isRunning: @escaping () -> Bool = { true }) {
        self.console = console
        self.isRunning = isRunning
        let stream = console.output
        reader = Task { [weak self] in
            for await chunk in stream {
                var start = chunk.startIndex
                while start < chunk.endIndex {
                    guard self != nil else { return }
                    let end = chunk.index(start, offsetBy: TerminalModel.sliceBytes, limitedBy: chunk.endIndex)
                        ?? chunk.endIndex
                    self?.feed(chunk[start..<end])
                    start = end
                    // The main actor also runs every VM, its delegate and the AI bridge: a guest's
                    // large chunk is parsed in slices, never in one turn.
                    if start < chunk.endIndex { await Task.yield() }
                }
            }
        }
    }

    /// The most guest bytes parsed in one main-actor turn.
    nonisolated static let sliceBytes = 16 * 1024

    private func feed(_ chunk: Data) {
        buffer.feed(chunk)
        let replies = buffer.takeReplies()
        // Queries made while the VM is not running are dropped, not answered later.
        guard isRunning() else { return }
        for reply in replies { console.send(reply) }
    }

    isolated deinit {
        reader?.cancel()
    }

    /// The view's grid changed size (columns × rows that fit).
    func resize(columns: Int, rows: Int) {
        buffer.resize(columns: columns, rows: rows)
    }

    func send(_ data: Data) {
        console.send(data)
    }

    /// The session is over: stop reading.
    func stop() {
        reader?.cancel()
        reader = nil
    }
}
