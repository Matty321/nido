// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation
import Synchronization
import Testing
@testable import NidoCore

@Suite struct EgressPolicyTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func pattern(_ text: String) throws -> DomainPattern { try DomainPattern(text) }

    // MARK: - DomainPattern validation

    @Test func exactAndWildcardPatternsAreNormalized() throws {
        #expect(try pattern("deb.debian.org").description == "deb.debian.org")
        #expect(try pattern("Deb.Debian.ORG").description == "deb.debian.org")
        #expect(try pattern("deb.debian.org.").description == "deb.debian.org")
        #expect(try pattern("  deb.debian.org\n").description == "deb.debian.org")
        #expect(try pattern("*.Debian.org").description == "*.debian.org")
        #expect(try pattern("*.debian.org").isWildcard)
        #expect(try !pattern("debian.org").isWildcard)
    }

    @Test func unicodeNamesBecomePunycode() throws {
        #expect(try pattern("bücher.de").description == "xn--bcher-kva.de")
        #expect(try pattern("*.BÜCHER.de").description == "*.xn--bcher-kva.de")
        #expect(try pattern("xn--bcher-kva.de").description == "xn--bcher-kva.de")
        #expect(try pattern("bücher.de").matches("xn--bcher-kva.de"))
    }

    @Test(arguments: [
        "", " ", ".", "*", "*.", "*.*.org", "a.*.org", "*debian.org", "deb*.debian.org", "localhost", "*.org",
        "1.2.3.4", "1.2.3", "*.1.2.3", "10.0.0.1.", "::1", "[::1]", "fe80::1", "0x7f.0.0.1",
        "ex_ample.com", "exa mple.com", "-bad.com", "bad-.com", "a..b.com", ".debian.org", "debian.org..",
        "deb.debian.org:443", "http://deb.debian.org", "deb.debian.org/path", "user@deb.debian.org",
    ])
    func refusesInvalidPatterns(_ text: String) {
        #expect(throws: NidoError.invalidDomain(text)) { try DomainPattern(text) }
    }

    @Test func enforcesLengthLimits() throws {
        let label63 = String(repeating: "a", count: 63)
        #expect(try pattern("\(label63).com").description == "\(label63).com")
        #expect(throws: NidoError.self) { try DomainPattern("\(label63)a.com") }
        // 253 characters is the most a name may have; 254 is refused.
        let name253 = [String](repeating: String(repeating: "b", count: 49), count: 5).joined(separator: ".") + ".abc"
        #expect(name253.count == 253)
        #expect(try pattern(name253).description == name253)
        #expect(throws: NidoError.self) { try DomainPattern("c" + name253) }
        // The limit applies to the name after `*.` (which the wildcard covers too).
        #expect(try pattern("*." + name253).description == "*." + name253)
        #expect(throws: NidoError.self) { try DomainPattern("*.c" + name253) }
        #expect(throws: NidoError.self) { try DomainPattern(String(repeating: "x", count: 10_000)) }
    }

    // MARK: - Matching

    @Test func exactPatternMatchesOnlyItself() throws {
        let p = try pattern("debian.org")
        #expect(p.matches("debian.org"))
        #expect(p.matches("DEBIAN.org."))
        #expect(!p.matches("deb.debian.org"))
        #expect(!p.matches("a.b.debian.org"))
        #expect(!p.matches("evildebian.org"))
        #expect(!p.matches("debian.org.evil.com"))
        #expect(!p.matches("debian.or"))
        #expect(!p.matches(""))
        // Names from the wire are ASCII: Unicode case folding never turns one into an allowed name.
        let kde = try pattern("kde.org")
        #expect(kde.matches("KDE.org"))
        #expect(!kde.matches("\u{212A}de.org"))  // KELVIN SIGN lowercases to "k"
        #expect(!kde.matches("kde.org\u{0130}"))
        let punycode = try pattern("xn--bcher-kva.de")
        #expect(!punycode.matches("bücher.de"))
    }

    @Test func refusalNeverEchoesControlCharacters() {
        let hostile = "a\u{0}b\u{1B}[31m\r\nc\u{7F}d\u{85}.com"
        do {
            _ = try DomainPattern(hostile)
            Issue.record("accepted \(hostile)")
        } catch let NidoError.invalidDomain(echo) {
            #expect(!echo.unicodeScalars.contains { $0.properties.generalCategory == .control })
            #expect(echo.contains("[31m"))
        } catch {
            Issue.record("unexpected \(error)")
        }
        // Bidi overrides, zero-width and line/paragraph separators are dropped too.
        let bidi = "evil\u{202E}gro.\u{200B}x\u{2028}y\u{2029}z.com"
        do {
            _ = try DomainPattern(bidi)
            Issue.record("accepted \(bidi)")
        } catch let NidoError.invalidDomain(echo) {
            #expect(echo == "evilgro.xyz.com")
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test func wildcardCoversTheDomainAndItsSubdomains() throws {
        let p = try pattern("*.debian.org")
        #expect(p.matches("debian.org"))
        #expect(p.matches("deb.debian.org"))
        #expect(p.matches("a.b.debian.org"))
        #expect(p.matches("Security.Debian.Org."))
        #expect(!p.matches("evildebian.org"))
        #expect(!p.matches("debian.org.evil.com"))
        #expect(!p.matches("xdebian.org"))
        #expect(!p.matches("org"))
        #expect(!p.matches(".debian.org"))
        #expect(!p.matches("a..debian.org"))
    }

    // MARK: - EgressPolicy coding

    @Test func policyRoundTripsAsPlainStrings() throws {
        let policy = EgressPolicy(v: 1, allow: [try pattern("deb.debian.org"), try pattern("*.ollama.com")])
        let data = try JSONEncoder().encode(policy)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["v"] as? Int == 1)
        #expect(object["allow"] as? [String] == ["deb.debian.org", "*.ollama.com"])
        #expect(try JSONDecoder().decode(EgressPolicy.self, from: data) == policy)
        #expect(EgressPolicy.empty == EgressPolicy(v: 1, allow: []))
        #expect(policy.allows("registry.ollama.com"))
        #expect(!policy.allows("example.com"))
    }

    @Test func policyDecodingRefusesBadContent() {
        for json in [
            #"{"v":2,"allow":[]}"#, #"{"v":0,"allow":[]}"#, #"{"allow":[]}"#, #"{"v":1}"#,
            #"{"v":1,"allow":["1.2.3.4"]}"#, #"{"v":1,"allow":["*"]}"#, #"{"v":1,"allow":[42]}"#,
            #"{"v":1,"allow":"deb.debian.org"}"#, "[]", "garbage",
        ] {
            #expect((try? JSONDecoder().decode(EgressPolicy.self, from: Data(json.utf8))) == nil, "\(json)")
        }
    }

    // MARK: - EgressPolicyStore

    private func makeBundle() throws -> VMBundle {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nido-egress-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return VMBundle(url: dir)
    }

    private func mode(_ url: URL) throws -> Int? {
        try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
    }

    @Test func missingFileIsTheEmptyPolicy() throws {
        let bundle = try makeBundle()
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        #expect(bundle.egressPolicyURL.lastPathComponent == "egress.json")
        #expect(EgressPolicyStore.load(bundle: bundle) == EgressPolicy.empty)
    }

    @Test func saveThenLoadIsAtomicAndPrivate() throws {
        let bundle = try makeBundle()
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        let policy = EgressPolicy(v: 1, allow: [try pattern("deb.debian.org"), try pattern("*.debian.org")])
        try EgressPolicyStore.save(policy, bundle: bundle)
        #expect(try mode(bundle.egressPolicyURL) == 0o600)
        #expect(EgressPolicyStore.load(bundle: bundle) == policy)

        // Overwriting replaces the file (new inode) and leaves no temporary file behind.
        var before = stat()
        #expect(lstat(bundle.egressPolicyURL.path, &before) == 0)
        try EgressPolicyStore.save(EgressPolicy.empty, bundle: bundle)
        var after = stat()
        #expect(lstat(bundle.egressPolicyURL.path, &after) == 0)
        #expect(before.st_ino != after.st_ino)
        #expect(EgressPolicyStore.load(bundle: bundle) == EgressPolicy.empty)
        let names = try FileManager.default.contentsOfDirectory(atPath: bundle.url.path)
        #expect(names == ["egress.json"])
    }

    @Test func refusesASymlinkedFileOnLoadAndSave() throws {
        let bundle = try makeBundle()
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        let target = bundle.url.appendingPathComponent("elsewhere.json")
        try Data(#"{"v":1,"allow":["example.com"]}"#.utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: bundle.egressPolicyURL, withDestinationURL: target)
        #expect(EgressPolicyStore.load(bundle: bundle) == nil)

        // Saving replaces the link itself: the target is never written through it.
        let policy = EgressPolicy(v: 1, allow: [try pattern("deb.debian.org")])
        try EgressPolicyStore.save(policy, bundle: bundle)
        #expect(try String(contentsOf: target, encoding: .utf8) == #"{"v":1,"allow":["example.com"]}"#)
        var info = stat()
        #expect(lstat(bundle.egressPolicyURL.path, &info) == 0)
        #expect((info.st_mode & S_IFMT) == S_IFREG)
        #expect(EgressPolicyStore.load(bundle: bundle) == policy)

        // A link to a missing file is not the empty policy either.
        try FileManager.default.removeItem(at: bundle.egressPolicyURL)
        try FileManager.default.removeItem(at: target)
        try FileManager.default.createSymbolicLink(at: bundle.egressPolicyURL, withDestinationURL: target)
        #expect(EgressPolicyStore.load(bundle: bundle) == nil)
    }

    @Test func saveRefusesAnotherVersion() throws {
        let bundle = try makeBundle()
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        #expect(throws: NidoError.self) {
            try EgressPolicyStore.save(EgressPolicy(v: 2, allow: []), bundle: bundle)
        }
        #expect(!FileManager.default.fileExists(atPath: bundle.egressPolicyURL.path))
    }

    @Test func refusesAHardLink() throws {
        let bundle = try makeBundle()
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        try EgressPolicyStore.save(EgressPolicy(v: 1, allow: [try pattern("example.com")]), bundle: bundle)
        let other = bundle.url.appendingPathComponent("other")
        #expect(link(bundle.egressPolicyURL.path, other.path) == 0)
        #expect(EgressPolicyStore.load(bundle: bundle) == nil)
    }

    @Test func refusesAFIFOWithoutHanging() throws {
        let bundle = try makeBundle()
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        try makeFIFO(bundle.egressPolicyURL)
        let loaded = withinTimeout { EgressPolicyStore.load(bundle: bundle) }
        #expect(loaded == .some(nil))
    }

    @Test func refusesAHugeFile() throws {
        let bundle = try makeBundle()
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        // Valid JSON with a 10 MB string: refused by size, never parsed.
        var data = Data(#"{"v":1,"allow":["example.com"],"pad":""#.utf8)
        data.append(Data(repeating: 0x61, count: 10 * 1024 * 1024))
        data.append(Data(#""}"#.utf8))
        try data.write(to: bundle.egressPolicyURL)
        #expect(EgressPolicyStore.load(bundle: bundle) == nil)
    }

    @Test func refusesGarbageAndWrongVersion() throws {
        let bundle = try makeBundle()
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        let bad: [Data] = [
            Data("garbage".utf8),
            Data([0xFF, 0xFE, 0x00, 0x7B]),
            Data(#"{"v":2,"allow":["example.com"]}"#.utf8),
            Data(#"{"v":1,"allow":["10.0.0.1"]}"#.utf8),
            Data(String(repeating: "[", count: 100_000).utf8),
            Data(),
        ]
        for data in bad {
            try? FileManager.default.removeItem(at: bundle.egressPolicyURL)
            try data.write(to: bundle.egressPolicyURL)
            #expect(EgressPolicyStore.load(bundle: bundle) == nil)
        }
    }

    @Test func refusesTooManyPatterns() throws {
        let bundle = try makeBundle()
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        let many = (0...EgressPolicy.maxPatterns).map { "\"h\($0).example.com\"" }.joined(separator: ",")
        try Data(#"{"v":1,"allow":[\#(many)]}"#.utf8).write(to: bundle.egressPolicyURL)
        #expect(EgressPolicyStore.load(bundle: bundle) == nil)
        let tooBig = EgressPolicy(
            v: 1, allow: try (0...EgressPolicy.maxPatterns).map { try pattern("h\($0).example.com") })
        #expect(throws: NidoError.self) { try EgressPolicyStore.save(tooBig, bundle: bundle) }
    }

    @Test func updateEditsUnderTheLock() throws {
        let bundle = try makeBundle()
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        // No file: the edit starts from the empty policy.
        let first = try EgressPolicyStore.update(bundle: bundle) { $0.allow.append(try pattern("deb.debian.org")) }
        #expect(first == EgressPolicy(v: 1, allow: [try pattern("deb.debian.org")]))
        #expect(EgressPolicyStore.load(bundle: bundle) == first)
        #expect(try mode(bundle.egressPolicyURL) == 0o600)
        let second = try EgressPolicyStore.update(bundle: bundle) { $0.allow.removeAll() }
        #expect(second == EgressPolicy.empty)
        #expect(EgressPolicyStore.load(bundle: bundle) == EgressPolicy.empty)
        // An edit that throws writes nothing.
        struct Stop: Error {}
        #expect(throws: Stop.self) {
            try EgressPolicyStore.update(bundle: bundle) { policy in
                policy.allow.append(try pattern("example.com"))
                throw Stop()
            }
        }
        #expect(EgressPolicyStore.load(bundle: bundle) == EgressPolicy.empty)
        // The lock file is private and never a symlink target.
        #expect(try mode(bundle.egressLockURL) == 0o600)
    }

    @Test func updateRefusesAMalformedFile() throws {
        let bundle = try makeBundle()
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        let bad = Data(#"{"v":2,"allow":["example.com"]}"#.utf8)
        try bad.write(to: bundle.egressPolicyURL)
        #expect(throws: NidoError.self) {
            try EgressPolicyStore.update(bundle: bundle) { $0.allow = [try pattern("ollama.com")] }
        }
        #expect(try Data(contentsOf: bundle.egressPolicyURL) == bad)

        // A symlinked lock is refused too.
        try FileManager.default.removeItem(at: bundle.egressPolicyURL)
        try FileManager.default.removeItem(at: bundle.egressLockURL)
        try FileManager.default.createSymbolicLink(
            at: bundle.egressLockURL, withDestinationURL: bundle.url.appendingPathComponent("elsewhere"))
        #expect(throws: NidoError.unsafePath(bundle.egressLockURL.path)) {
            try EgressPolicyStore.update(bundle: bundle) { _ in }
        }
    }

    /// The conditional `replace` decides on the file as it is under the lock: refused, nothing
    /// is written.
    @Test func conditionalReplaceDecidesUnderTheLock() throws {
        let bundle = try makeBundle()
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        let narrow = EgressPolicy(v: 1, allow: [try pattern("deb.debian.org")])
        try EgressPolicyStore.replace(bundle: bundle, with: narrow)
        var seen: [EgressPolicy?] = []
        #expect(try !EgressPolicyStore.replace(bundle: bundle, with: .base, unless: { seen.append($0); return true }))
        #expect(seen == [narrow])
        #expect(EgressPolicyStore.load(bundle: bundle) == narrow)
        try Data("{".utf8).write(to: bundle.egressPolicyURL)
        #expect(try EgressPolicyStore.replace(bundle: bundle, with: .base, unless: { seen.append($0); return false }))
        #expect(seen.last == .some(nil))
        #expect(EgressPolicyStore.load(bundle: bundle) == .base)
    }

    /// `replace` is the way out of a malformed file (`nido net reset`): under the lock, it writes
    /// the given policy whatever is on disk, a planted symlink included, never through it.
    @Test func replaceWritesOverAMalformedFile() throws {
        let bundle = try makeBundle()
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        try Data("{garbage".utf8).write(to: bundle.egressPolicyURL)
        #expect(EgressPolicyStore.load(bundle: bundle) == nil)
        let base = EgressPolicy(v: 1, allow: [try pattern("deb.debian.org")])
        try EgressPolicyStore.replace(bundle: bundle, with: base)
        #expect(EgressPolicyStore.load(bundle: bundle) == base)
        #expect(try mode(bundle.egressPolicyURL) == 0o600)

        let target = bundle.url.appendingPathComponent("target")
        try Data("untouched".utf8).write(to: target)
        try FileManager.default.removeItem(at: bundle.egressPolicyURL)
        try FileManager.default.createSymbolicLink(at: bundle.egressPolicyURL, withDestinationURL: target)
        try EgressPolicyStore.replace(bundle: bundle, with: .empty)
        #expect(EgressPolicyStore.load(bundle: bundle) == .empty)
        #expect(try Data(contentsOf: target) == Data("untouched".utf8))
        // What `save` refuses, `replace` refuses too.
        #expect(throws: NidoError.self) { try EgressPolicyStore.replace(bundle: bundle, with: EgressPolicy(v: 2, allow: [])) }
        // The base list is a valid policy and only names exact hosts or explicit wildcards.
        #expect(EgressPolicy.base.v == EgressPolicy.currentVersion)
    }

    /// The base list verified on 2026-10-29: Debian, `ollama pull` and one time server, exact
    /// names only. No GitHub (Ollama comes from the Mac) and no NTP pool (volunteer addresses
    /// reachable on every port).
    @Test func baseListIsTheVerifiedExactNames() throws {
        #expect(EgressPolicy.base.allow.map(\.description) == [
            "deb.debian.org", "registry.ollama.ai",
            "dd20bb891979d25aebc8bec07b2b3bbc.r2.cloudflarestorage.com", "time.cloudflare.com",
        ])
        #expect(EgressPolicy.base.allow.allSatisfy { !$0.isWildcard })
        for refused in ["github.com", "release-assets.githubusercontent.com", "2.debian.pool.ntp.org",
                        "debian.pool.ntp.org", "security.debian.org", "ollama.com"] {
            #expect(!EgressPolicy.base.allows(refused), "\(refused)")
        }
        let bundle = try makeBundle()
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        try EgressPolicyStore.replace(bundle: bundle, with: .base)
        #expect(EgressPolicyStore.load(bundle: bundle) == .base)
    }

    /// The macOS base list seen on 2026-11-02 (a macOS 26.6.2 VM idle in Setup Assistant on the
    /// relay with an empty list), kept only where Apple documents the name for activation,
    /// software update or time. Exact names, never `*.apple.com`; App Store, iCloud, push and
    /// Maps stay out.
    @Test func macOSBaseHasOnlyTheVerifiedNames() throws {
        #expect(EgressPolicy.macOSBase.v == EgressPolicy.currentVersion)
        #expect(EgressPolicy.macOSBase.allow.map(\.description) == [
            "albert.apple.com", "gdmf.apple.com", "mesu.apple.com", "swscan.apple.com", "swdist.apple.com",
            "time.apple.com",
        ])
        #expect(EgressPolicy.macOSBase.allow.allSatisfy { !$0.isWildcard })
        // xp.apple.com (sends more than it gets, not needed by softwareupdate) and the download CDN
        // stay out.
        for refused in ["xp.apple.com", "updates.cdn-apple.com", "updates-http.cdn-apple.com",
                        "apple.com", "www.apple.com", "itunes.apple.com", "bag.itunes.apple.com",
                        "gateway.icloud.com", "api.apple-cloudkit.com", "push.apple.com", "init.push.apple.com",
                        "gspe1-ssl.ls.apple.com", "deb.debian.org", "registry.ollama.ai"] {
            #expect(!EgressPolicy.macOSBase.allows(refused), "\(refused)")
        }
    }

    @Test func concurrentUpdatesNeverLoseARemoval() throws {
        let bundle = try makeBundle()
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        let count = 40
        let a = try (0..<count).map { try pattern("a\($0).example.com") }
        let b = try (0..<count).map { try pattern("b\($0).example.com") }
        let keep = try pattern("keep.example.com")
        try EgressPolicyStore.save(EgressPolicy(v: 1, allow: a + b + [keep]), bundle: bundle)

        let failures = Mutex(0)
        let group = DispatchGroup()
        for list in [a, b] {
            group.enter()
            Thread {
                for p in list {
                    do {
                        try EgressPolicyStore.update(bundle: bundle) { $0.allow.removeAll { $0 == p } }
                    } catch {
                        failures.withLock { $0 += 1 }
                    }
                }
                group.leave()
            }.start()
        }
        // A third writer adds and removes its own name meanwhile.
        group.enter()
        Thread {
            for i in 0..<count {
                let p = try! DomainPattern("c\(i).example.com")
                do {
                    try EgressPolicyStore.update(bundle: bundle) { $0.allow.append(p) }
                    try EgressPolicyStore.update(bundle: bundle) { $0.allow.removeAll { $0 == p } }
                } catch {
                    failures.withLock { $0 += 1 }
                }
            }
            group.leave()
        }.start()
        #expect(group.wait(timeout: .now() + 30) == .success)
        #expect(failures.withLock { $0 } == 0)
        #expect(EgressPolicyStore.load(bundle: bundle) == EgressPolicy(v: 1, allow: [keep]))
    }

    // MARK: - EgressDecision

    @Test func unknownIPIsDenied() throws {
        let decision = EgressDecision(policy: EgressPolicy(v: 1, allow: [try pattern("deb.debian.org")]))
        #expect(
            decision.decide(dstIP: "151.101.2.132", port: 443, proto: .tcp, now: t0)
                == .denyUnknown(ip: "151.101.2.132"))
        #expect(decision.decide(dstIP: "not an ip", port: 443, proto: .tcp, now: t0) == .denyUnknown(ip: "not an ip"))
    }

    @Test func learnedAllowedIPIsAllowedUntilItExpires() throws {
        let decision = EgressDecision(policy: EgressPolicy(v: 1, allow: [try pattern("deb.debian.org")]))
        decision.learner.learn(name: "deb.debian.org", addresses: ["151.101.2.132"], ttl: 900, now: t0)
        #expect(
            decision.decide(dstIP: "151.101.2.132", port: 80, proto: .tcp, now: t0)
                == .allow(domain: "deb.debian.org"))
        #expect(
            decision.decide(dstIP: "151.101.2.132", port: 53, proto: .udp, now: t0)
                == .allow(domain: "deb.debian.org"))
        #expect(
            decision.decide(dstIP: "151.101.2.132", port: 80, proto: .tcp, now: t0 + 900)
                == .denyUnknown(ip: "151.101.2.132"))
    }

    @Test func otherProtocolsAreDeniedEvenToALearnedIP() throws {
        let decision = EgressDecision(policy: EgressPolicy(v: 1, allow: [try pattern("deb.debian.org")]))
        decision.learner.learn(name: "deb.debian.org", addresses: ["151.101.2.132"], ttl: 60, now: t0)
        for proto in [EgressProto.icmp, .other] {
            #expect(
                decision.decide(dstIP: "151.101.2.132", port: 0, proto: proto, now: t0)
                    == .denyProto(ip: "151.101.2.132", proto: proto))
            #expect(
                decision.decide(dstIP: "93.184.215.14", port: 0, proto: proto, now: t0)
                    == .denyProto(ip: "93.184.215.14", proto: proto))
        }
        #expect(EgressProto(ipProtocol: 6) == .tcp)
        #expect(EgressProto(ipProtocol: 17) == .udp)
        #expect(EgressProto(ipProtocol: 1) == .icmp)
        #expect(EgressProto(ipProtocol: 47) == .other)
    }

    @Test func aLearnedNameNoLongerAllowedIsDeniedByDomain() throws {
        // The learner is shared: an entry the policy does not allow (stale, or learned by a bug)
        // is still denied, and named.
        let decision = EgressDecision(policy: EgressPolicy(v: 1, allow: [try pattern("deb.debian.org")]))
        decision.learner.learn(name: "example.com", addresses: ["93.184.215.14"], ttl: 60, now: t0)
        #expect(decision.decide(dstIP: "93.184.215.14", port: 443, proto: .tcp, now: t0) == .denyDomain("example.com"))
    }

    @Test func learnKeepsOnlyAllowedNames() throws {
        let decision = EgressDecision(policy: EgressPolicy(v: 1, allow: [try pattern("*.debian.org")]))
        decision.learn(name: "example.com", addresses: ["93.184.215.14"], ttl: 600, now: t0)
        decision.learn(name: "Security.Debian.org.", addresses: ["151.101.66.132"], ttl: 600, now: t0)
        #expect(decision.learner.count(now: t0) == 1)
        #expect(decision.learner.domain(for: "93.184.215.14", now: t0) == nil)
        #expect(
            decision.decide(dstIP: "151.101.66.132", port: 443, proto: .tcp, now: t0)
                == .allow(domain: "security.debian.org"))
    }

    @Test func applyingANarrowerPolicyForgetsAndDenies() throws {
        let decision = EgressDecision(
            policy: EgressPolicy(v: 1, allow: [try pattern("*.debian.org"), try pattern("deb.debian.org")]))
        decision.learner.learn(name: "security.debian.org", addresses: ["151.101.66.132"], ttl: 600, now: t0)
        decision.learner.learn(name: "deb.debian.org", addresses: ["151.101.2.132"], ttl: 600, now: t0)
        #expect(decision.allows(name: "security.debian.org"))

        decision.apply(EgressPolicy(v: 1, allow: [try pattern("deb.debian.org")]))
        #expect(decision.policy.allow == [try pattern("deb.debian.org")])
        #expect(!decision.allows(name: "security.debian.org"))
        #expect(decision.learner.domain(for: "151.101.66.132", now: t0) == nil)
        #expect(
            decision.decide(dstIP: "151.101.66.132", port: 443, proto: .tcp, now: t0)
                == .denyUnknown(ip: "151.101.66.132"))
        // The exact name that stays allowed keeps its learned address.
        #expect(
            decision.decide(dstIP: "151.101.2.132", port: 443, proto: .tcp, now: t0)
                == .allow(domain: "deb.debian.org"))
    }

    @Test func sharedAddressIsAllowedUnderTheAllowedName() throws {
        // A CDN address learned for an allowed and (by a stale entry) a not-allowed name.
        let decision = EgressDecision(policy: EgressPolicy(v: 1, allow: [try pattern("deb.debian.org")]))
        decision.learner.learn(name: "example.com", addresses: ["151.101.2.132"], ttl: 600, now: t0)
        decision.learner.learn(name: "deb.debian.org", addresses: ["151.101.2.132"], ttl: 600, now: t0 + 1)
        decision.learner.learn(name: "example.com", addresses: ["151.101.2.132"], ttl: 600, now: t0 + 2)
        #expect(
            decision.decide(dstIP: "151.101.2.132", port: 443, proto: .tcp, now: t0 + 3)
                == .allow(domain: "deb.debian.org"))
    }

    /// A wildcard that opens names of everyone (two labels or fewer, a public or platform
    /// suffix, Amazon's shared space) needs a warning before it is added (app and `nido net allow`).
    @Test func broadWildcardsNeedAWarning() throws {
        for broad in ["*.example.com", "*.co.uk", "*.r2.cloudflarestorage.com", "*.s3.eu-west-1.amazonaws.com",
                      "*.github.io", "*.githubusercontent.com"] {
            #expect(try DomainPattern(broad).isBroadWildcard, "\(broad)")
        }
        for narrow in ["*.cdn.example.com", "deb.debian.org", "registry.ollama.ai", "*.mirror.example.co.uk"] {
            #expect(!(try DomainPattern(narrow).isBroadWildcard), "\(narrow)")
        }
    }
}
