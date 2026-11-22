// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Where a reader (the app, `nido mcp`) stopped reading a VM's `egress.log`: the time of the last
/// line read and how many lines with exactly that time it read (the log's times are whole
/// seconds). Lines are appended in order, so the lines after the cursor are the new ones.
public struct EgressLogCursor: Codable, Equatable, Sendable {
    public var time: Date
    public var seen: Int

    public init(time: Date, seen: Int) {
        self.time = time
        self.seen = seen
    }

    /// The lines of `entries` (oldest first, as `EgressLog.readEntries`) after `cursor`, and the
    /// cursor after them. Without a cursor, only lines from the second of `since` on are new (the
    /// reader was not watching this VM before; the log's times are whole seconds, so a block of
    /// that very second is not skipped).
    public static func newEntries(
        _ entries: [EgressLogEntry], after cursor: EgressLogCursor?, since: Date
    ) -> (entries: [EgressLogEntry], cursor: EgressLogCursor?) {
        let start = cursor ?? EgressLogCursor(
            time: Date(timeIntervalSince1970: floor(since.timeIntervalSince1970)), seen: 0)
        var atStart = 0
        var fresh: [EgressLogEntry] = []
        for entry in entries {
            if entry.time < start.time { continue }
            if entry.time == start.time {
                atStart += 1
                if atStart <= start.seen { continue }
            }
            fresh.append(entry)
        }
        guard let last = entries.last else { return ([], cursor) }
        let seen = entries.reversed().prefix { $0.time == last.time }.count
        // A log that went back in time (rotation lost, clock changed) starts over from its end.
        if last.time < start.time { return ([], EgressLogCursor(time: last.time, seen: seen)) }
        return (fresh, EgressLogCursor(time: last.time, seen: seen))
    }
}
