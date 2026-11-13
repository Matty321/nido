// SPDX-License-Identifier: Apache-2.0
import Foundation
import NidoCore
import Synchronization
import Testing

@testable import Nido

/// Stands in for Touch ID: answers as told and counts the prompts. Never a real prompt.
final class FakeAuthenticator: OwnerAuthenticator {
    private let state: Mutex<(answer: Bool, reasons: [String])>
    init(answer: Bool) { state = Mutex((answer, [])) }
    func authenticate(reason: String) async -> Bool {
        state.withLock {
            $0.reasons.append(reason)
            return $0.answer
        }
    }
    var reasons: [String] { state.withLock { $0.reasons } }
    func answer(_ value: Bool) { state.withLock { $0.answer = value } }
}

/// Keeps the notices in memory.
@MainActor
final class FakePoster: EgressNotificationPosting {
    var allowed: Bool
    private(set) var posted: [EgressBlockNotice] = []
    init(allowed: Bool) { self.allowed = allowed }
    func authorize() async -> Bool { allowed }
    func post(_ notice: EgressBlockNotice) { posted.append(notice) }
}

private func entry(
    _ verdict: EgressLogEntry.Verdict, domain: String? = nil, ip: String? = "151.101.2.132", port: UInt16? = 443,
    proto: EgressProto = .tcp, at time: Date = Date(timeIntervalSince1970: 1_800_000_000), repeats: Int? = nil,
    via: String? = nil, lostBlocks: Int? = nil
) -> EgressLogEntry {
    EgressLogEntry(time: time, domain: domain, ip: ip, port: port, proto: proto, verdict: verdict,
                   lostBlocks: lostBlocks, repeats: repeats, via: via)
}

/// A throwaway root with one Linux VM.
private struct Fixture {
    let root: URL
    let paths: NidoPaths
    let bundle: VMBundle
    let name: VMName

    init(guest: GuestOS = .linux, controlled: Bool = true) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nido-egress-app-\(UUID().uuidString)", isDirectory: true)
        paths = NidoPaths(root: root)
        try paths.ensureRoot()
        name = try VMName(guest == .linux ? "agenti" : "macos-agenti")
        var config = VMConfig(
            id: UUID(), name: name, guest: guest, cpuCount: 2, memoryBytes: 4 << 30, diskBytes: 16 << 30,
            macAddress: "52:54:00:12:34:58", sshUser: guest == .macos ? "nido" : nil,
            osVersion: guest == .macos ? "26.6" : nil, controlledNetwork: controlled)
        config.controlledNetwork = controlled
        bundle = try VMBundle.create(config: config, paths: paths)
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }

    func writePolicy(_ names: [String]) throws {
        try EgressPolicyStore.replace(
            bundle: bundle, with: EgressPolicy(v: EgressPolicy.currentVersion, allow: try names.map(DomainPattern.init)))
    }

    var policy: EgressPolicy? { EgressPolicyStore.load(bundle: bundle) }
    var policyBytes: Data? { try? Data(contentsOf: bundle.egressPolicyURL) }
}

@Suite struct EgressNoticeTextTests {
    @Test func consentiOnlyForANamedDomain() {
        #expect(EgressNoticeText.allowDomain(for: entry(.name, domain: "example.com", ip: nil, port: 53)) == "example.com")
        #expect(EgressNoticeText.allowDomain(for: entry(.denyDomain, domain: "tracker.example.net")) == "tracker.example.net")
        // The alias the guest asked with another type: its own name.
        #expect(EgressNoticeText.allowDomain(for: entry(
            .aliasQueryType, domain: "deb.debian.org", via: "debian.map.fastly.net")) == "debian.map.fastly.net")
        // A bare address, a name with underscores, a cut, anything without a name: never.
        #expect(EgressNoticeText.allowDomain(for: entry(.denyUnknown)) == nil)
        #expect(EgressNoticeText.allowDomain(for: entry(.name, domain: "_https._tcp.deb.debian.org", port: 53)) == nil)
        #expect(EgressNoticeText.allowDomain(for: entry(.cut, domain: "deb.debian.org")) == nil)
        #expect(EgressNoticeText.allowDomain(for: entry(.ipv6, ip: nil, port: nil)) == nil)
        // A hostile name from a tampered log: never offered, never shown with its controls.
        let hostile = entry(.name, domain: "evil\u{202E}moc.example.com\u{2028}x", port: 53)
        #expect(EgressNoticeText.allowDomain(for: hostile) == nil)
        let shown = EgressNoticeText.destination(hostile)
        #expect(!shown.unicodeScalars.contains { $0.value == 0x202E || $0.value == 0x2028 })
    }

    @Test func noticeSaysVMDestinationAndExactDomain() throws {
        let notice = try #require(EgressNoticeText.notice(
            for: entry(.name, domain: "example.com", ip: nil, port: 53, proto: .udp, repeats: 2), vm: "agenti"))
        #expect(notice.title == "agenti: connessione bloccata")
        #expect(notice.count == 3)
        #expect(notice.body
            == "example.com:53 (3 volte): nome non permesso. Consenti aggiunge esattamente example.com ai domini permessi.")
        let ip = try #require(EgressNoticeText.notice(for: entry(.denyUnknown), vm: "agenti"))
        #expect(ip.body == "151.101.2.132:443: indirizzo mai risolto per un dominio permesso.")
        #expect(ip.allowDomain == nil)
        // Cuts and allowed lines are not notices; a summary of lost blocks is.
        #expect(EgressNoticeText.notice(for: entry(.cut, domain: "x.org"), vm: "agenti") == nil)
        #expect(EgressNoticeText.notice(for: entry(.allowed, domain: "x.org"), vm: "agenti") == nil)
        let summary = try #require(EgressNoticeText.summaryNotice(
            for: entry(.suppressed, ip: nil, port: nil, lostBlocks: 80), vm: "agenti"))
        #expect(summary.count == 80)
        #expect(EgressNoticeText.summaryNotice(for: entry(.suppressed, ip: nil, port: nil, lostBlocks: 0), vm: "agenti") == nil)
    }

    @Test func cursorReadsOnlyNewLines() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let lines = [entry(.name, domain: "a.org", at: t0), entry(.name, domain: "b.org", at: t0.addingTimeInterval(1)),
                     entry(.name, domain: "c.org", at: t0.addingTimeInterval(1))]
        // Never watched: only lines from the second of `since` on.
        var (fresh, cursor) = EgressLogCursor.newEntries(lines, after: nil, since: t0.addingTimeInterval(1))
        #expect(fresh.map(\.domain) == ["b.org", "c.org"])
        #expect(cursor == EgressLogCursor(time: t0.addingTimeInterval(1), seen: 2))
        // Same file: nothing new; one more line in the same second: just that one.
        (fresh, cursor) = EgressLogCursor.newEntries(lines, after: cursor, since: t0)
        #expect(fresh.isEmpty)
        let more = lines + [entry(.name, domain: "d.org", at: t0.addingTimeInterval(1))]
        (fresh, cursor) = EgressLogCursor.newEntries(more, after: cursor, since: t0)
        #expect(fresh.map(\.domain) == ["d.org"])
        // A log that went back in time starts over from its end.
        (fresh, cursor) = EgressLogCursor.newEntries([entry(.name, at: t0.addingTimeInterval(-50))], after: cursor, since: t0)
        #expect(fresh.isEmpty)
        #expect(cursor?.time == t0.addingTimeInterval(-50))
    }

    /// Repeats inside the window are counted and posted when it is over: the posted counts add
    /// up to every block; many destinations at once become one summary for the rest.
    @Test func batcherMergesWithoutLosingBlocks() {
        var batcher = EgressNoticeBatcher()
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let a = EgressNoticeText.notice(for: entry(.name, domain: "a.org", port: 53), vm: "vm")!
        var posted = batcher.add([a, a, a], now: t0)
        #expect(posted.map(\.count) == [3])
        posted = batcher.add([a, a], now: t0.addingTimeInterval(4))
        #expect(posted.isEmpty)
        #expect(batcher.flush(now: t0.addingTimeInterval(5)).isEmpty)
        let later = batcher.flush(now: t0.addingTimeInterval(10))
        #expect(later.map(\.count) == [2])
        #expect(batcher.flush(now: t0.addingTimeInterval(30)).isEmpty)

        let many = (0..<9).map { EgressNoticeText.notice(for: entry(.name, domain: "d\($0).org", port: 53), vm: "vm")! }
        posted = batcher.add(many, now: t0.addingTimeInterval(100))
        #expect(posted.count == EgressNoticeBatcher.maxPerBatch)
        #expect(posted.last?.destination == "altre 6 destinazioni")
        #expect(posted.reduce(0) { $0 + $1.count } == 9)
    }

    /// Boot noise (ruling): blocks without a domain towards multicast, broadcast or link-local
    /// are logged, never notified nor counted. Everything else with a block is.
    @Test func bootNoiseIsNotNotified() {
        let quiet: [EgressLogEntry] = [
            entry(.broadcast, ip: "255.255.255.255", port: 67, proto: .udp),
            entry(.broadcast, ip: nil, port: nil),
            entry(.ipv6, ip: nil, port: nil, proto: .other),
            entry(.ipv6, ip: "ff02::2", port: nil, proto: .other),
            entry(.ipv6, ip: "FF05::1:3", port: 547, proto: .udp),
            entry(.ipv6, ip: "fe80::1", port: 546, proto: .udp),
            entry(.ipv6, ip: "febf::1", port: 546, proto: .udp),
            entry(.malformed, ip: nil, port: nil, proto: .other),
            // macOS at boot: the link-local IPv4 broadcast (never routed off the link).
            entry(.hostSubnet, ip: "169.254.255.255", port: nil, proto: .other),
        ]
        for line in quiet {
            #expect(!EgressNoticeText.isNotified(line), "\(line)")
            #expect(EgressNoticeText.notice(for: line, vm: "vm") == nil)
        }
        let loud: [EgressLogEntry] = [
            entry(.ipv6, ip: "2001:db8::1", port: 443),
            entry(.ipv6, ip: "fec0::1", port: 443),
            entry(.malformed, ip: "203.0.113.4", port: 80),
            entry(.denyUnknown),
            entry(.name, domain: "example.com", ip: nil, port: 53),
            entry(.broadcast, domain: "printer.example.com", ip: "255.255.255.255", port: 5353),
            entry(.ipv6, domain: "example.com", ip: "ff02::fb", port: 5353),
            entry(.hostSubnet, ip: "192.168.64.1", port: 22),
            entry(.hostSubnet, ip: "169.255.0.1", port: nil, proto: .other),
            // Link-local unicast is a real destination (e.g. a cloud metadata address).
            entry(.denyUnknown, ip: "169.254.1.2", port: 80),
            entry(.denyUnknown, ip: "169.254.169.254", port: 80),
            entry(.hostSubnet, ip: "169.254.169.254", port: 80),
            // Near misses of the link-local broadcast: only 169.254.255.255 is quiet.
            entry(.hostSubnet, ip: "169.254.255.254", port: nil, proto: .other),
            entry(.hostSubnet, ip: "169.254.255.25", port: nil, proto: .other),
            entry(.hostSubnet, domain: "printer.local.example.com", ip: "169.254.1.2", port: 631),
        ]
        for line in loud { #expect(EgressNoticeText.isNotified(line), "\(line)") }
        for verdict in [EgressLogEntry.Verdict.cut, .suppressed, .allowed, .open] {
            #expect(!EgressNoticeText.isNotified(entry(verdict, domain: "x.org")))
        }
    }

    /// The domain of a notification action is checked again when the action arrives: only an
    /// exact name that survives the echo strip unchanged.
    @Test func actionDomainIsCheckedAgain() {
        #expect(EgressMonitor.actionDomain("example.com") == "example.com")
        #expect(EgressMonitor.actionDomain("*.example.com") == nil)
        #expect(EgressMonitor.actionDomain("Example.COM") == nil)
        #expect(EgressMonitor.actionDomain("exa\u{200B}mple.com") == nil)
        #expect(EgressMonitor.actionDomain("1.2.3.4") == nil)
        #expect(EgressMonitor.actionDomain(42) == nil)
        #expect(EgressMonitor.actionDomain(nil) == nil)
    }

    /// No cursor: the second of `since` counts whole, so a block logged in that same second is
    /// not skipped.
    @Test func sameSecondBlockIsNotSkipped() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let lines = [entry(.name, domain: "a.org", at: t0.addingTimeInterval(-1)), entry(.name, domain: "b.org", at: t0)]
        let (fresh, _) = EgressLogCursor.newEntries(lines, after: nil, since: t0.addingTimeInterval(0.7))
        #expect(fresh.map(\.domain) == ["b.org"])
    }

    /// Overflow of a batch: the counts posted add up to the blocks, never more (no block counted
    /// twice), never fewer.
    @Test func overflowNeverOvercounts() {
        var batcher = EgressNoticeBatcher()
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        func n(_ i: Int) -> EgressBlockNotice { EgressNoticeText.notice(for: entry(.name, domain: "d\(i).org", port: 53), vm: "vm")! }
        var total = 0
        var posted = 0
        // d0…d3 posted, then repeats of them inside their window, then a big batch with them.
        let first = batcher.add((0..<3).map(n), now: t0)
        total += 3; posted += first.reduce(0) { $0 + $1.count }
        _ = batcher.add([n(0), n(1)], now: t0.addingTimeInterval(2))
        total += 2
        let big = (0..<8).map(n)
        let second = batcher.add(big, now: t0.addingTimeInterval(20))
        total += 8; posted += second.reduce(0) { $0 + $1.count }
        posted += batcher.flush(now: t0.addingTimeInterval(500)).reduce(0) { $0 + $1.count }
        #expect(posted == total)
    }

    /// Too many destinations: past the key cap, pending counts are posted and the marks evicted
    /// (none stranded: a later block of an evicted key is posted at once).
    @Test func keyCapEvictsWithoutStranding() {
        var batcher = EgressNoticeBatcher()
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        func n(_ i: Int, vm: String) -> EgressBlockNotice {
            EgressNoticeText.notice(for: entry(.name, domain: "d\(i).org", port: 53), vm: vm)!
        }
        var total = 0
        var posted = 0
        let a = n(0, vm: "a")
        posted += batcher.add([a], now: t0).reduce(0) { $0 + $1.count }
        posted += batcher.add([a], now: t0.addingTimeInterval(1)).reduce(0) { $0 + $1.count }
        total += 2
        // Many VMs, one destination each, fill the table.
        for i in 0...EgressNoticeBatcher.maxKeys {
            posted += batcher.add([n(i, vm: "vm\(i)")], now: t0.addingTimeInterval(2)).reduce(0) { $0 + $1.count }
            total += 1
        }
        #expect(batcher.markCount <= EgressNoticeBatcher.maxKeys)
        let again = batcher.add([a], now: t0.addingTimeInterval(3))
        total += 1
        posted += again.reduce(0) { $0 + $1.count }
        #expect(again.map(\.key) == ["a|d0.org:53"])
        posted += batcher.flush(now: t0.addingTimeInterval(500)).reduce(0) { $0 + $1.count }
        #expect(posted == total)
    }

    /// Per VM: after 10 distinct destinations in 60 s, only the merged "altre" notice is posted
    /// for the rest of the window, with every block counted.
    @Test func perVMCapMergesTheRest() {
        var batcher = EgressNoticeBatcher()
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        func n(_ i: Int) -> EgressBlockNotice { EgressNoticeText.notice(for: entry(.name, domain: "d\(i).org", port: 53), vm: "vm")! }
        var notices: [EgressBlockNotice] = []
        for i in 0..<15 { notices += batcher.add([n(i)], now: t0.addingTimeInterval(Double(i))) }
        // A destination already merged comes back in the same window: still 4 distinct.
        notices += batcher.add([n(13)], now: t0.addingTimeInterval(15))
        let individual = notices.filter { $0.key != "vm|altre" }
        #expect(Set(individual.map(\.key)).count == EgressNoticeBatcher.maxDestinationsPerVM)
        notices += batcher.flush(now: t0.addingTimeInterval(30))
        let others = notices.filter { $0.key == "vm|altre" }
        #expect(others.reduce(0) { $0 + $1.count } == 6)
        // The first is posted at once (one destination), the next four held over several
        // batches, one of them twice: the text counts distinct destinations.
        #expect(others.map(\.destination) == ["un'altra destinazione", "altre 4 destinazioni"])
        // A new window: individual notices again.
        let later = batcher.add([n(20)], now: t0.addingTimeInterval(100))
        #expect(later.map(\.key) == ["vm|d20.org:53"])
    }

    /// The app asks with the same check as `nido net allow` (cases in `EgressPolicyTests`).
    @Test func broadWildcardsNeedAWarning() throws {
        #expect(EgressPolicyEdits.isBroadWildcard(try DomainPattern("*.example.com")))
        #expect(!EgressPolicyEdits.isBroadWildcard(try DomainPattern("*.cdn.example.com")))
    }
}

@Suite struct EgressPolicyEditsTests {
    @Test func addingAsksFirstAndWritesNothingWhenRefused() async throws {
        let fx = try Fixture(); defer { fx.cleanup() }
        try fx.writePolicy(["deb.debian.org"])
        let before = fx.policyBytes
        let refusing = FakeAuthenticator(answer: false)
        #expect(await EgressPolicyEdits.allow("example.com", vm: "agenti", bundle: fx.bundle, authenticator: refusing)
            == .cancelled)
        #expect(refusing.reasons == ["aggiungere example.com ai domini permessi della VM agenti"])
        #expect(fx.policyBytes == before)

        let owner = FakeAuthenticator(answer: true)
        #expect(await EgressPolicyEdits.allow(" Example.COM. ", vm: "agenti", bundle: fx.bundle, authenticator: owner)
            == .added("example.com"))
        #expect(fx.policy?.allow.map(\.description) == ["deb.debian.org", "example.com"])
        // Already there, invalid: no prompt.
        #expect(await EgressPolicyEdits.allow("example.com", vm: "agenti", bundle: fx.bundle, authenticator: owner)
            == .alreadyListed("example.com"))
        if case .invalid = await EgressPolicyEdits.allow("1.2.3.4", vm: "agenti", bundle: fx.bundle, authenticator: owner) {
        } else {
            Issue.record("an address is not a domain")
        }
        #expect(owner.reasons.count == 1)
        // Removing asks nothing.
        try await EgressPolicyEdits.remove(try DomainPattern("example.com"), bundle: fx.bundle)
        #expect(fx.policy?.allow.map(\.description) == ["deb.debian.org"])
        #expect(owner.reasons.count == 1)
    }

    /// A damaged `egress.json` is never taken for an empty list: adding refuses it without asking;
    /// resetting to the base list asks (nobody knows what the relay keeps) and then rewrites it.
    @Test func malformedListNeedsAConfirmedReset() async throws {
        let fx = try Fixture(); defer { fx.cleanup() }
        try Data("{garbage".utf8).write(to: fx.bundle.egressPolicyURL)
        let owner = FakeAuthenticator(answer: false)
        #expect(await EgressPolicyEdits.allow("example.com", vm: "agenti", bundle: fx.bundle, authenticator: owner)
            == .malformed)
        #expect(owner.reasons.isEmpty)
        #expect(EgressPolicyEdits.resetWidens(nil))
        #expect(await EgressPolicyEdits.resetToBase(vm: "agenti", bundle: fx.bundle, authenticator: owner) == .cancelled)
        #expect(fx.policyBytes == Data("{garbage".utf8))
        owner.answer(true)
        #expect(await EgressPolicyEdits.resetToBase(vm: "agenti", bundle: fx.bundle, authenticator: owner) == .reset)
        #expect(fx.policy == .base)
        #expect(owner.reasons.count == 2)

        // A list that already holds the base one: the reset narrows, no prompt.
        try fx.writePolicy(EgressPolicy.base.allow.map(\.description) + ["example.com"])
        #expect(await EgressPolicyEdits.resetToBase(vm: "agenti", bundle: fx.bundle, authenticator: owner) == .reset)
        #expect(owner.reasons.count == 2)
        #expect(fx.policy == .base)
    }
}

@Suite struct EgressResetRaceTests {
    /// "Widens" is decided again under the lock: the list changed to a narrower one between the
    /// check and the write, so the reset asks the owner first (refused: nothing written).
    @Test func resetDecidesUnderTheLock() async throws {
        let fx = try Fixture(); defer { fx.cleanup() }
        try fx.writePolicy(EgressPolicy.base.allow.map(\.description) + ["example.com"])
        let narrow: @Sendable () -> Void = { _ = try? fx.writePolicy(["deb.debian.org"]) }
        let refusing = FakeAuthenticator(answer: false)
        #expect(await EgressPolicyEdits.resetToBase(vm: "agenti", bundle: fx.bundle, authenticator: refusing,
                                                    beforeWrite: narrow) == .cancelled)
        #expect(refusing.reasons.count == 1)
        #expect(fx.policy?.allow.map(\.description) == ["deb.debian.org"])

        try fx.writePolicy(EgressPolicy.base.allow.map(\.description) + ["example.com"])
        let owner = FakeAuthenticator(answer: true)
        #expect(await EgressPolicyEdits.resetToBase(vm: "agenti", bundle: fx.bundle, authenticator: owner,
                                                    beforeWrite: narrow) == .reset)
        #expect(owner.reasons.count == 1)
        #expect(fx.policy == .base)
    }
}

@MainActor
@Suite struct EgressMonitorTests {
    private func defaults() -> UserDefaults {
        let suite = "nido-egress-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    /// Blocks written by any process (here directly in the log, as the relay of `nido start`
    /// does) are notified with VM, destination and port; the next launch catches up on what was
    /// written while the app was closed.
    @Test func notifiesNewBlocksAndCatchesUpAfterARestart() async throws {
        let fx = try Fixture(); defer { fx.cleanup() }
        let log = try EgressLog(bundle: fx.bundle)
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        log.append(entry(.name, domain: "old.example.com", ip: nil, port: 53, at: t0.addingTimeInterval(-60)))
        let store = defaults()
        let poster = FakePoster(allowed: false)
        let monitor = EgressMonitor(paths: fx.paths, poster: poster, authenticator: FakeAuthenticator(answer: false),
                                    defaults: store)
        // First look at this root: what was there before is not notified.
        await monitor.poll(now: t0)
        #expect(poster.posted.isEmpty)

        log.append(entry(.name, domain: "example.com", ip: nil, port: 53, proto: .udp, at: t0.addingTimeInterval(1)))
        log.append(entry(.denyUnknown, at: t0.addingTimeInterval(1)))
        log.append(entry(.allowed, domain: "deb.debian.org", at: t0.addingTimeInterval(1)))
        await monitor.poll(now: t0.addingTimeInterval(2))
        #expect(poster.posted.map(\.body) == [
            "example.com:53: nome non permesso. Consenti aggiunge esattamente example.com ai domini permessi.",
            "151.101.2.132:443: indirizzo mai risolto per un dominio permesso.",
        ])
        #expect(poster.posted.map(\.vm) == ["agenti", "agenti"])
        #expect(monitor.unseenBlocks["agenti"] == 2)
        monitor.markSeen("agenti")
        #expect(monitor.unseenBlocks["agenti"] == nil)

        // The app is closed; `nido start` keeps logging; the next launch notifies those blocks.
        log.append(entry(.name, domain: "later.example.com", ip: nil, port: 53, at: t0.addingTimeInterval(30)))
        let poster2 = FakePoster(allowed: true)
        let relaunched = EgressMonitor(paths: fx.paths, poster: poster2, authenticator: FakeAuthenticator(answer: false),
                                       defaults: store)
        await relaunched.poll(now: t0.addingTimeInterval(40))
        #expect(poster2.posted.map(\.allowDomain) == ["later.example.com"])
    }

    /// gvproxy died with the VM running: one notice at once, with the reason, not counted as a
    /// block, and never merged with blocks.
    @Test func uplinkLossIsNotifiedAtOnce() async throws {
        let fx = try Fixture(); defer { fx.cleanup() }
        let log = try EgressLog(bundle: fx.bundle)
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let poster = FakePoster(allowed: false)
        let monitor = EgressMonitor(paths: fx.paths, poster: poster, authenticator: FakeAuthenticator(answer: false),
                                    defaults: defaults())
        await monitor.poll(now: t0)
        for _ in 0..<12 {
            log.append(entry(.denyUnknown, ip: "10.9.\(Int.random(in: 0...255)).1", at: t0.addingTimeInterval(1)))
        }
        log.append(EgressLogEntry(
            time: t0.addingTimeInterval(1), domain: nil, ip: nil, port: nil, proto: .other, verdict: .uplinkLost,
            reason: "gvproxy è stato chiuso dal segnale 9"))
        await monitor.poll(now: t0.addingTimeInterval(2))
        let lost = try #require(poster.posted.first { $0.subject == "rete controllata interrotta" })
        #expect(lost.title == "agenti: rete controllata interrotta")
        #expect(lost.body == "Rete controllata interrotta: gvproxy è stato chiuso dal segnale 9. "
            + "La VM resta senza rete fino al prossimo avvio.")
        #expect(lost.allowDomain == nil)
        #expect(!EgressNoticeText.isNotified(EgressLogEntry(
            time: t0, domain: nil, ip: nil, port: nil, proto: .other, verdict: .uplinkLost, reason: "x")))
    }

    /// egress.log keeps a stable code for the loss of the uplink (`UplinkLoss`, language-neutral);
    /// the notification and the log row say it in words, in the UI language. A line an older
    /// version wrote holds Italian free text: shown as it is.
    @Test func uplinkLossCodeShowsInWords() throws {
        func lost(_ reason: String?) -> EgressLogEntry {
            EgressLogEntry(time: Date(timeIntervalSince1970: 1_800_000_000), domain: nil, ip: nil, port: nil,
                           proto: .other, verdict: .uplinkLost, reason: reason)
        }
        let notice = try #require(EgressNoticeText.uplinkLostNotice(for: lost(UplinkLoss.signal(9)), vm: "agenti"))
        #expect(notice.reason == "gvproxy è stato chiuso dal segnale 9")
        #expect(notice.title == "agenti: rete controllata interrotta")
        #expect(notice.body == "Rete controllata interrotta: gvproxy è stato chiuso dal segnale 9. "
            + "La VM resta senza rete fino al prossimo avvio.")
        #expect(EgressNoticeText.uplinkLostReason(lost(UplinkLoss.socketClosed)) == "il socket di gvproxy si è chiuso")
        #expect(EgressNoticeText.uplinkLostReason(lost("gvproxy è uscito con codice 1")) == "gvproxy è uscito con codice 1")
        #expect(EgressNoticeText.uplinkLostReason(lost(nil)) == "motivo sconosciuto")
        let row = NetworkLogModel.row(lost(UplinkLoss.exit(2)), id: "x", time: "t")
        #expect(row.detail == "Rete controllata interrotta: gvproxy si è chiuso (codice 2). "
            + "La VM resta senza rete fino al prossimo avvio.")
        #expect(row.outcome == "interrotta")
    }

    /// Boot noise is in the log but neither notified nor counted.
    @Test func bootNoiseIsNotCounted() async throws {
        let fx = try Fixture(); defer { fx.cleanup() }
        let log = try EgressLog(bundle: fx.bundle)
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let poster = FakePoster(allowed: false)
        let monitor = EgressMonitor(paths: fx.paths, poster: poster, authenticator: FakeAuthenticator(answer: false),
                                    defaults: defaults())
        await monitor.poll(now: t0)
        log.append(entry(.ipv6, ip: "ff02::2", port: nil, proto: .other, at: t0.addingTimeInterval(1)))
        log.append(entry(.broadcast, ip: "255.255.255.255", port: 67, proto: .udp, at: t0.addingTimeInterval(1)))
        log.append(entry(.malformed, ip: nil, port: nil, proto: .other, at: t0.addingTimeInterval(1)))
        await monitor.poll(now: t0.addingTimeInterval(2))
        #expect(poster.posted.isEmpty)
        #expect(monitor.unseenBlocks["agenti"] == nil)
        log.append(entry(.denyUnknown, at: t0.addingTimeInterval(3)))
        await monitor.poll(now: t0.addingTimeInterval(4))
        #expect(poster.posted.count == 1)
        #expect(monitor.unseenBlocks["agenti"] == 1)
    }

    /// egress.log that the relay cannot open (here a planted symlink): one notice, not one per
    /// poll; again once the log was usable and broke anew.
    @Test func unopenableLogIsNotifiedOnce() async throws {
        let fx = try Fixture(); defer { fx.cleanup() }
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let poster = FakePoster(allowed: true)
        let monitor = EgressMonitor(paths: fx.paths, poster: poster, authenticator: FakeAuthenticator(answer: false),
                                    defaults: defaults())
        await monitor.poll(now: t0)
        #expect(poster.posted.isEmpty)
        try FileManager.default.createSymbolicLink(
            at: fx.bundle.egressLogURL, withDestinationURL: fx.root.appendingPathComponent("elsewhere"))
        await monitor.poll(now: t0.addingTimeInterval(2))
        await monitor.poll(now: t0.addingTimeInterval(4))
        #expect(poster.posted.count == 1)
        let notice = try #require(poster.posted.first)
        #expect(notice.title == "agenti: registro di rete non disponibile")
        #expect(notice.body == "egress.log: i blocchi restano attivi ma non vengono registrati né notificati.")
        #expect(notice.allowDomain == nil)
        #expect(monitor.unseenBlocks["agenti"] == nil)

        try FileManager.default.removeItem(at: fx.bundle.egressLogURL)
        _ = try EgressLog(bundle: fx.bundle)
        await monitor.poll(now: t0.addingTimeInterval(6))
        try FileManager.default.removeItem(at: fx.bundle.egressLogURL)
        try FileManager.default.createSymbolicLink(
            at: fx.bundle.egressLogURL, withDestinationURL: fx.root.appendingPathComponent("elsewhere"))
        await monitor.poll(now: t0.addingTimeInterval(8))
        #expect(poster.posted.count == 2)
    }

    /// "Consenti" from a notification: Touch ID first; refused, nothing is written; the outcome
    /// is a notice of its own.
    @Test func consentiFromANotification() async throws {
        let fx = try Fixture(); defer { fx.cleanup() }
        try fx.writePolicy(["deb.debian.org"])
        let poster = FakePoster(allowed: true)
        let owner = FakeAuthenticator(answer: false)
        let monitor = EgressMonitor(paths: fx.paths, poster: poster, authenticator: owner, defaults: defaults())
        #expect(await monitor.allow("example.com", vm: "agenti") == .cancelled)
        #expect(fx.policy?.allow.count == 1)
        owner.answer(true)
        #expect(await monitor.allow("example.com", vm: "agenti") == .added("example.com"))
        #expect(fx.policy?.allow.map(\.description) == ["deb.debian.org", "example.com"])
        #expect(poster.posted.last?.reason
            == "example.com aggiunto ai domini permessi di agenti: vale entro pochi secondi, anche a VM accesa")
    }

    @Test func openLogAsksTheWindow() throws {
        let fx = try Fixture(); defer { fx.cleanup() }
        let monitor = EgressMonitor(paths: fx.paths, poster: FakePoster(allowed: true),
                                    authenticator: FakeAuthenticator(answer: false), defaults: defaults())
        var opened: [String] = []
        monitor.openWindow = { opened.append($0.rawValue) }
        monitor.openLog("agenti")
        monitor.openLog("agenti")
        #expect(opened == ["agenti", "agenti"])
        #expect(monitor.logRequest == EgressMonitor.LogRequest(vm: "agenti", serial: 2))
    }
}

@MainActor
@Suite struct NetworkSettingsModelTests {
    /// The relay no longer depends on the Mac's IP forwarding (gvproxy): the confirmation of
    /// "Attiva" never mentions it, on Linux or macOS.
    @Test func enablingNeverMentionsTheMacForwarding() throws {
        for guest in [GuestOS.linux, .macos] {
            let fx = try Fixture(guest: guest, controlled: false); defer { fx.cleanup() }
            let model = NetworkSettingsModel(bundle: fx.bundle, config: try fx.bundle.readConfig(),
                                             authenticator: FakeAuthenticator(answer: true), isRunning: { false })
            model.requestToggle(true)
            #expect(model.toggleSheet.action == "Attiva")
            #expect(!model.toggleSheet.message.contains("inoltro IP"))
            #expect(!model.toggleSheet.message.contains("net.inet.ip.forwarding"))
        }
    }

    @Test func enablingOnAStoppedVMWritesTheBaseList() async throws {
        let fx = try Fixture(controlled: false); defer { fx.cleanup() }
        let owner = FakeAuthenticator(answer: false)
        final class Running { var value = true }
        let running = Running()
        let model = NetworkSettingsModel(bundle: fx.bundle, config: try fx.bundle.readConfig(), authenticator: owner,
                                         isRunning: { running.value })
        #expect(model.isLocked)
        model.requestToggle(true)
        #expect(model.pendingToggle == nil)
        running.value = false
        model.requestToggle(true)
        #expect(model.pendingToggle == true)
        #expect(model.toggleSheet.message.contains("lista di base"))
        #expect(model.toggleSheet.message.contains("senza rete"))
        #expect(model.toggleSheet.message.contains("Ollama"))
        await model.confirmToggle()
        #expect(try fx.bundle.readConfig().controlledNetwork == true)
        #expect(fx.policy == .base)
        #expect(owner.reasons.isEmpty)
        #expect(model.patterns == EgressPolicy.base.allow)

        // Off widens (Apple's NAT): the owner confirms; refused, nothing changes.
        model.requestToggle(false)
        await model.confirmToggle()
        #expect(try fx.bundle.readConfig().controlledNetwork == true)
        #expect(model.messageIsError)
        owner.answer(true)
        model.requestToggle(false)
        await model.confirmToggle()
        #expect(try fx.bundle.readConfig().controlledNetwork == false)
        #expect(owner.reasons.count == 2)
        // The list stays for later.
        #expect(fx.policy == .base)
    }

    /// The base list cannot be written: said inline; the VM stays fail closed (controlled, no list).
    @Test func seedFailureIsSaid() async throws {
        let fx = try Fixture(controlled: false); defer { fx.cleanup() }
        try FileManager.default.createDirectory(at: fx.bundle.egressLockURL, withIntermediateDirectories: false)
        let model = NetworkSettingsModel(bundle: fx.bundle, config: try fx.bundle.readConfig(),
                                         authenticator: FakeAuthenticator(answer: false), isRunning: { false })
        model.requestToggle(true)
        await model.confirmToggle()
        #expect(try fx.bundle.readConfig().controlledNetwork == true)
        #expect(model.messageIsError)
        #expect(model.message?.hasPrefix("Rete controllata attiva, ma la lista di base non è stata scritta") == true)
        #expect(!FileManager.default.fileExists(atPath: fx.bundle.egressPolicyURL.path))
    }

    /// macOS VMs have the controlled network too. Turning it on writes the macOS base list when
    /// the VM has no list (never the Linux one); "Ripristina lista di base" writes it too, also
    /// over a damaged list.
    @Test func macOSTurnsOnWithItsBaseList() async throws {
        let fx = try Fixture(guest: .macos, controlled: false); defer { fx.cleanup() }
        let owner = FakeAuthenticator(answer: true)
        let model = NetworkSettingsModel(bundle: fx.bundle, config: try fx.bundle.readConfig(),
                                         authenticator: owner, isRunning: { false })
        let first = try #require(EgressPolicy.macOSBase.allow.first).description
        #expect(!model.isLocked)
        model.requestToggle(true)
        #expect(model.pendingToggle == true)
        #expect(model.toggleSheet.message.contains("lista di base per macOS"))
        #expect(model.toggleSheet.message.contains(first))
        #expect(!model.toggleSheet.message.contains("Ollama"))
        #expect(!model.toggleSheet.message.contains("deb.debian.org"))
        await model.confirmToggle()
        #expect(try fx.bundle.readConfig().controlledNetwork == true)
        #expect(fx.policy == EgressPolicy.macOSBase)
        #expect(model.patterns == EgressPolicy.macOSBase.allow)
        #expect(owner.reasons.isEmpty)
        #expect(model.resetLabel == "Ripristina lista di base…")
        #expect(model.resetMessage.contains(first))
        #expect(!model.resetMessage.contains("deb.debian.org"))

        // A damaged list: the macOS base list, never the Linux one.
        try Data("garbage".utf8).write(to: fx.bundle.egressPolicyURL)
        await model.load()
        #expect(model.isMalformed)
        model.requestReset()
        await model.confirmReset()
        #expect(fx.policy == EgressPolicy.macOSBase)
        #expect(!model.isMalformed)
    }

    /// A macOS VM that already has an empty list (made before the macOS base list) keeps it
    /// when the controlled network is turned on.
    @Test func macOSKeepsAnExistingEmptyList() async throws {
        let fx = try Fixture(guest: .macos, controlled: false); defer { fx.cleanup() }
        try fx.writePolicy([])
        let model = NetworkSettingsModel(bundle: fx.bundle, config: try fx.bundle.readConfig(),
                                         authenticator: FakeAuthenticator(answer: true), isRunning: { false })
        model.requestToggle(true)
        await model.confirmToggle()
        #expect(try fx.bundle.readConfig().controlledNetwork == true)
        #expect(fx.policy == .empty)
    }

    @Test func linuxResetLabelIsTheBaseList() throws {
        let fx = try Fixture(); defer { fx.cleanup() }
        let model = NetworkSettingsModel(bundle: fx.bundle, config: try fx.bundle.readConfig(),
                                         authenticator: FakeAuthenticator(answer: true), isRunning: { false })
        #expect(model.resetLabel == "Ripristina lista di base…")
        #expect(model.resetMessage.contains("deb.debian.org"))
    }

    @Test func broadWildcardNeedsTwoConfirmations() async throws {
        let fx = try Fixture(); defer { fx.cleanup() }
        try fx.writePolicy(["deb.debian.org"])
        let owner = FakeAuthenticator(answer: true)
        let model = NetworkSettingsModel(bundle: fx.bundle, config: try fx.bundle.readConfig(), authenticator: owner,
                                         isRunning: { true })
        await model.load()
        model.newDomain = "*.co.uk"
        await model.addDomain()
        #expect(model.pendingBroad?.description == "*.co.uk")
        #expect(owner.reasons.isEmpty)
        model.cancelBroad()
        #expect(fx.policy?.allow.count == 1)
        await model.addDomain()
        await model.confirmBroad()
        #expect(owner.reasons == ["aggiungere *.co.uk ai domini permessi della VM agenti"])
        #expect(fx.policy?.allow.map(\.description) == ["deb.debian.org", "*.co.uk"])
        #expect(model.newDomain.isEmpty)

        // A plain name: no warning, straight to Touch ID; removing asks nothing.
        model.newDomain = "registry.ollama.ai"
        await model.addDomain()
        #expect(model.pendingBroad == nil)
        #expect(owner.reasons.count == 2)
        await model.remove(try DomainPattern("*.co.uk"))
        #expect(owner.reasons.count == 2)
        #expect(model.patterns.map(\.description) == ["deb.debian.org", "registry.ollama.ai"])
    }

    @Test func cancelledTouchIDWritesNothing() async throws {
        let fx = try Fixture(); defer { fx.cleanup() }
        try fx.writePolicy(["deb.debian.org"])
        let before = fx.policyBytes
        let model = NetworkSettingsModel(bundle: fx.bundle, config: try fx.bundle.readConfig(),
                                         authenticator: FakeAuthenticator(answer: false), isRunning: { false })
        model.newDomain = "example.com"
        await model.addDomain()
        #expect(fx.policyBytes == before)
        #expect(model.messageIsError)
        #expect(model.message == "Nessun dominio aggiunto: conferma annullata o non riuscita.")
        #expect(model.newDomain == "example.com")
    }

    @Test func malformedListShowsTheWayOut() async throws {
        let fx = try Fixture(); defer { fx.cleanup() }
        try Data("[]".utf8).write(to: fx.bundle.egressPolicyURL)
        let owner = FakeAuthenticator(answer: true)
        let model = NetworkSettingsModel(bundle: fx.bundle, config: try fx.bundle.readConfig(), authenticator: owner,
                                         isRunning: { false })
        await model.load()
        #expect(model.isMalformed)
        #expect(model.malformedHint.contains("nido net reset agenti"))
        #expect(model.resetMessage.contains("Touch ID"))
        model.requestReset()
        await model.confirmReset()
        #expect(owner.reasons.count == 1)
        #expect(fx.policy == .base)
        #expect(!model.isMalformed)
    }
}

@MainActor
@Suite struct NetworkLogModelTests {
    @Test func rowsNewestFirstWithConsentiOnNamedBlocks() async throws {
        let fx = try Fixture(); defer { fx.cleanup() }
        try fx.writePolicy(["deb.debian.org"])
        let log = try EgressLog(bundle: fx.bundle)
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        log.append(entry(.allowed, domain: "deb.debian.org", at: t0))
        log.append(entry(.name, domain: "example.com", ip: nil, port: 53, proto: .udp, at: t0.addingTimeInterval(1)))
        log.append(entry(.denyUnknown, at: t0.addingTimeInterval(2)))
        let owner = FakeAuthenticator(answer: true)
        let model = NetworkLogModel(name: fx.name, paths: fx.paths, authenticator: owner, timeZone: TimeZone(identifier: "UTC")!)
        await model.refresh()
        #expect(model.network == .controlled(domains: 1))
        #expect(model.rows.map(\.destination) == ["151.101.2.132:443", "example.com:53"])
        #expect(model.rows.map(\.allowDomain) == [nil, "example.com"])
        // Day, month and time as the locale writes them (it_IT: "15/01, 08:00:02").
        #expect(model.rows.first?.time == "15/01, 08:00:02")
        model.blockedOnly = false
        #expect(model.rows.count == 3)
        #expect(model.rows.last?.outcome == "permesso")

        await model.allow("example.com")
        #expect(owner.reasons.count == 1)
        #expect(fx.policy?.allow.map(\.description) == ["deb.debian.org", "example.com"])
        #expect(model.network == .controlled(domains: 2))
        #expect(model.messageIsError == false)
    }

    /// Local noise (IPv6 multicast, broadcast) is not a row: it stays in egress.log only.
    @Test func localNoiseIsNotARow() async throws {
        let fx = try Fixture(); defer { fx.cleanup() }
        try fx.writePolicy(["deb.debian.org"])
        let log = try EgressLog(bundle: fx.bundle)
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        log.append(entry(.ipv6, ip: "ff02::2", port: nil, proto: .other, at: t0))
        log.append(entry(.broadcast, ip: "224.0.0.252", port: 5355, proto: .udp, at: t0.addingTimeInterval(1)))
        log.append(entry(.name, domain: "api.snapcraft.io", ip: nil, port: 53, proto: .udp, at: t0.addingTimeInterval(2)))
        let model = NetworkLogModel(name: fx.name, paths: fx.paths, authenticator: FakeAuthenticator(answer: true),
                                    timeZone: TimeZone(identifier: "UTC")!)
        await model.refresh()
        #expect(model.rows.map(\.destination) == ["api.snapcraft.io:53"])
        // Hidden, not silent: the line under the log counts them and says how to see them.
        #expect(model.hiddenNoise == 2)
        #expect(model.hiddenNoiseText == "2 blocchi di rumore locale nascosti: IPv6 multicast e link-local, broadcast. Non escono dalla VM; per vederli: nido net log \(fx.name.rawValue) --all.")
        model.blockedOnly = false
        #expect(model.rows.count == 1)
        #expect(model.hiddenNoise == 2)

        // One line: singular. None: no line.
        let single = NetworkLogModel(name: fx.name, paths: fx.paths, authenticator: FakeAuthenticator(answer: true),
                                     readEntries: { _ in [entry(.ipv6, ip: "ff02::2", port: nil, proto: .other, at: t0)] })
        await single.refresh()
        #expect(single.rows.isEmpty)
        #expect(single.hiddenNoiseText?.hasPrefix("1 blocco di rumore locale nascosto: ") == true)
        let clean = NetworkLogModel(name: fx.name, paths: fx.paths, authenticator: FakeAuthenticator(answer: true),
                                    readEntries: { _ in [entry(.denyUnknown, at: t0)] })
        await clean.refresh()
        #expect(clean.hiddenNoise == 0 && clean.hiddenNoiseText == nil)
    }

    /// gvproxy gone while the VM runs: the header says the network is interrupted and how to get
    /// it back, not "Rete controllata" with a green dot (seen live).
    @Test func lostGvproxyShowsAnInterruptedNetwork() async throws {
        let fx = try Fixture(); defer { fx.cleanup() }
        try fx.writePolicy(["deb.debian.org"])
        let model = NetworkLogModel(name: fx.name, paths: fx.paths, authenticator: FakeAuthenticator(answer: true),
                                    networkLost: { _ in true })
        await model.refresh()
        #expect(model.network == .interrupted(domains: 1))
        #expect(model.networkSummary.contains("Arresta e avvia di nuovo la VM"))
    }

    /// A row keeps its id when new lines arrive and the oldest go with a rotation; identical
    /// lines still get ids of their own.
    @Test func rowIDsComeFromContentAndSurviveRotation() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let a = entry(.denyUnknown, at: t0)
        let b = entry(.name, domain: "example.com", ip: nil, port: 53, proto: .udp, at: t0.addingTimeInterval(1))
        let c = entry(.denyUnknown, at: t0.addingTimeInterval(2))
        let d = entry(.denyUnknown, at: t0.addingTimeInterval(3))
        let before = NetworkLogModel.rowIDs([a, b, c, c])
        let after = NetworkLogModel.rowIDs([b, c, c, d])
        #expect(Array(before[1...]) == Array(after[..<3]))
        #expect(Set(before).count == 4)
        #expect(before[2] != before[3])
    }

    /// A read that ends after a newer one started is dropped: the older log never comes back.
    @Test func staleRefreshIsDropped() async throws {
        let fx = try Fixture(); defer { fx.cleanup() }
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let stale = [entry(.denyUnknown, at: t0)]
        let fresh = [entry(.denyUnknown, at: t0), entry(.name, domain: "example.com", ip: nil, port: 53, at: t0 + 1)]
        let reads = ReadGate()
        let model = NetworkLogModel(
            name: fx.name, paths: fx.paths, authenticator: FakeAuthenticator(answer: false),
            readEntries: { _ in reads.next() ? fresh : stale })
        let first = Task { await model.refresh() }
        // The first read has started and is held.
        await Task.detached { reads.waitFirstEntered() }.value
        await model.refresh()
        #expect(model.rows.count == 2)
        reads.releaseFirst()
        await first.value
        #expect(model.rows.count == 2)
    }

    @Test func natAndMalformedAreSaid() async throws {
        let fx = try Fixture(controlled: false); defer { fx.cleanup() }
        let model = NetworkLogModel(name: fx.name, paths: fx.paths, authenticator: FakeAuthenticator(answer: false))
        await model.refresh()
        #expect(model.network == .nat)
        #expect(model.rows.isEmpty)
        try fx.bundle.updateConfig { $0.controlledNetwork = true }
        try Data("{".utf8).write(to: fx.bundle.egressPolicyURL)
        await model.refresh()
        #expect(model.network == .malformed)
        #expect(model.networkSummary.contains("nido net reset agenti"))
    }
}

/// The first read is held until released (no wall-clock wait); later reads return at once.
private final class ReadGate: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private let entered = DispatchSemaphore(value: 0)
    private let released = DispatchSemaphore(value: 0)

    /// False for the first read (after it is released), true for every later one.
    func next() -> Bool {
        lock.lock()
        count += 1
        let first = count == 1
        lock.unlock()
        guard first else { return true }
        entered.signal()
        _ = released.wait(timeout: .now() + 30)
        return false
    }

    func waitFirstEntered() { _ = entered.wait(timeout: .now() + 30) }
    func releaseFirst() { released.signal() }
}
