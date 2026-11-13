// SPDX-License-Identifier: Apache-2.0
import Foundation
import Synchronization

/// Merges block notices for a person (`nido start` prints them on stderr): one line per
/// destination (the domain when the relay knows it, otherwise the address) and port every
/// `window` seconds. Repeats are counted, never dropped: those inside the window, and those the
/// relay's own limiter held back (`EgressEvent.repeats`, which ride on its next report). Their
/// count is a line of its own when the window is over (`flush`, or the destination's next
/// block). Cuts and summaries of left-out reports always print, unmerged. Allowed flows are not
/// notices. Thread-safe.
public final class EgressNoticeMerger: Sendable {
    public static let window: TimeInterval = 10
    /// Most destinations tracked at once; beyond that, expired ones are flushed and, if still
    /// full, the table starts over (each destination's first line was printed already).
    static let maxKeys = 4096

    private struct Key: Hashable {
        let target: String
        let port: UInt16?
    }

    private struct Mark {
        let first: Date
        var repeats = 0
    }

    private let marks = Mutex<[Key: Mark]>([:])

    public init() {}

    /// The lines to print for `event`: the count of the destination's last window when it is
    /// over, then the event's own line unless it repeats one printed less than `window` ago.
    public func lines(for event: EgressEvent, now: Date) -> [String] {
        guard case .denied(let denial) = event.kind else { return event.blockDescription.map { [$0] } ?? [] }
        if case .cut = denial { return event.blockDescription.map { [$0] } ?? [] }
        var plain = event
        plain.repeats = 0
        guard let description = plain.blockDescription else { return [] }
        let key = Key(target: Self.target(denial, ip: event.ip), port: event.port)
        return marks.withLock { marks in
            var lines: [String] = []
            if var mark = marks[key] {
                mark.repeats += event.repeats
                guard now.timeIntervalSince(mark.first) >= Self.window else {
                    mark.repeats += 1
                    marks[key] = mark
                    return []
                }
                if let summary = Self.summary(key, mark) { lines.append(summary) }
            } else {
                if let summary = Self.summary(key, Mark(first: now, repeats: event.repeats)) { lines.append(summary) }
                if marks.count >= Self.maxKeys {
                    lines += Self.expire(&marks, now: now)
                    if marks.count >= Self.maxKeys { marks.removeAll() }
                }
            }
            marks[key] = Mark(first: now)
            lines.append(description)
            return lines
        }
    }

    /// The counts of the windows that are over (and forgets them); call it every few seconds.
    public func flush(now: Date) -> [String] {
        marks.withLock { Self.expire(&$0, now: now) }
    }

    var count: Int { marks.withLock { $0.count } }

    private static func expire(_ marks: inout [Key: Mark], now: Date) -> [String] {
        var lines: [String] = []
        for (key, mark) in marks where now.timeIntervalSince(mark.first) >= window {
            marks[key] = nil
            if let summary = summary(key, mark) { lines.append(summary) }
        }
        return lines.sorted()
    }

    private static func summary(_ key: Key, _ mark: Mark) -> String? {
        guard mark.repeats > 0 else { return nil }
        let destination = [key.target.isEmpty ? nil : key.target, key.port.map(String.init)]
            .compactMap { $0 }.joined(separator: ":")
        let (times, seconds) = (mark.repeats, String(Int(window)))
        if destination.isEmpty { return L10n.string("blocked \(times) more times in the last \(seconds) s") }
        return L10n.string("blocked \(times) more times to \(destination) in the last \(seconds) s")
    }

    private static func target(_ denial: EgressDenial, ip: String?) -> String {
        switch denial {
        case .name(let name), .verdict(.denyDomain(let name)), .cut(let name, _, _, _), .aliasQueryType(let name, _): name
        default: ip ?? ""
        }
    }
}
