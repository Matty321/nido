// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import NidoCore

private func entry(domain: String, at time: Date) -> EgressLogEntry {
    EgressLogEntry(time: time, domain: domain, ip: "151.101.2.132", port: 443, proto: .tcp, verdict: .name)
}

@Suite struct EgressLogCursorTests {
    @Test func cursorReadsOnlyNewLines() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let lines = [entry(domain: "a.org", at: t0), entry(domain: "b.org", at: t0.addingTimeInterval(1)),
                     entry(domain: "c.org", at: t0.addingTimeInterval(1))]
        // Never watched: only lines from the second of `since` on.
        var (fresh, cursor) = EgressLogCursor.newEntries(lines, after: nil, since: t0.addingTimeInterval(1))
        #expect(fresh.map(\.domain) == ["b.org", "c.org"])
        #expect(cursor == EgressLogCursor(time: t0.addingTimeInterval(1), seen: 2))
        // Same file: nothing new; one more line in the same second: just that one.
        (fresh, cursor) = EgressLogCursor.newEntries(lines, after: cursor, since: t0)
        #expect(fresh.isEmpty)
        let more = lines + [entry(domain: "d.org", at: t0.addingTimeInterval(1))]
        (fresh, cursor) = EgressLogCursor.newEntries(more, after: cursor, since: t0)
        #expect(fresh.map(\.domain) == ["d.org"])
        // A log that went back in time starts over from its end.
        (fresh, cursor) = EgressLogCursor.newEntries(
            [entry(domain: "e.org", at: t0.addingTimeInterval(-50))], after: cursor, since: t0)
        #expect(fresh.isEmpty)
        #expect(cursor?.time == t0.addingTimeInterval(-50))
    }

    /// No cursor: the second of `since` counts whole, so a block logged in that same second is
    /// not skipped.
    @Test func sameSecondBlockIsNotSkipped() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let lines = [entry(domain: "a.org", at: t0.addingTimeInterval(-1)), entry(domain: "b.org", at: t0)]
        let (fresh, _) = EgressLogCursor.newEntries(lines, after: nil, since: t0.addingTimeInterval(0.7))
        #expect(fresh.map(\.domain) == ["b.org"])
    }
}
