// SPDX-License-Identifier: Apache-2.0
import Foundation
import Synchronization
import Testing
@testable import NidoCLI
@_spi(Testing) @testable import NidoCore

/// Stands in for Touch ID: records every reason it was asked for and answers `result`.
private final class FakeAuthenticator: OwnerAuthenticator {
    private let state = Mutex<[String]>([])
    let result: Bool

    init(result: Bool) { self.result = result }

    func authenticate(reason: String) async -> Bool {
        state.withLock { $0.append(reason) }
        return result
    }

    var reasons: [String] { state.withLock { $0 } }
}

@Suite(.italian) struct NetCommandTests {
    private struct Env {
        let tmp: URL
        let paths: NidoPaths
        let bundle: VMBundle

        init(controlled: Bool = true, guest: GuestOS = .linux) throws {
            tmp = FileManager.default.temporaryDirectory.appendingPathComponent("nido-tests-net-\(UUID().uuidString)")
            paths = NidoPaths(root: tmp.appendingPathComponent("VMs", isDirectory: true))
            try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
            var config = VMConfig(
                id: UUID(), name: try VMName("vm"), guest: guest, cpuCount: 2,
                memoryBytes: 4 << 30, diskBytes: 20 << 30, macAddress: "02:00:00:00:00:01")
            config.controlledNetwork = controlled
            bundle = try VMBundle.create(config: config, paths: paths)
        }

        var policyFile: Data? { try? Data(contentsOf: bundle.egressPolicyURL) }

        func allowList() -> [String]? { EgressPolicyStore.load(bundle: bundle)?.allow.map(\.description) }

        func setAllow(_ names: [String]) throws {
            try EgressPolicyStore.save(EgressPolicy(v: 1, allow: try names.map(DomainPattern.init)), bundle: bundle)
        }

        func allow(
            _ domain: String, interactive: Bool = true, confirm: @escaping (String) -> Bool = { _ in true },
            _ auth: FakeAuthenticator
        ) async throws -> String {
            try await CLISupport.netAllow(
                vm: "vm", domain: domain, paths: paths, interactive: interactive, confirm: confirm, authenticator: auth)
        }

        func breakPolicy() throws -> Data {
            let bad = Data("{garbage".utf8)
            try bad.write(to: bundle.egressPolicyURL)
            return bad
        }

        func cleanup() { try? FileManager.default.removeItem(at: tmp) }
    }

    // MARK: - list

    @Test func listPrintsTheAllowlist() throws {
        let env = try Env()
        defer { env.cleanup() }
        #expect(try CLISupport.netList(vm: "vm", paths: env.paths)
            == "Nessun dominio permesso per vm: la VM non raggiunge nessun sito.")
        try env.setAllow(["deb.debian.org", "*.ollama.com"])
        #expect(try CLISupport.netList(vm: "vm", paths: env.paths)
            == "Domini permessi per vm:\n  deb.debian.org\n  *.ollama.com")
    }

    @Test func listNotesAVMWithoutTheControlledNetwork() throws {
        let env = try Env(controlled: false)
        defer { env.cleanup() }
        let text = try CLISupport.netList(vm: "vm", paths: env.paths)
        #expect(text.contains("la rete controllata non è attiva per vm"))
    }

    // MARK: - allow

    @Test func allowAddsAfterTouchID() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let auth = FakeAuthenticator(result: true)
        let text = try await env.allow("Deb.Debian.org.", auth)
        #expect(text.contains("Aggiunto deb.debian.org"))
        #expect(env.allowList() == ["deb.debian.org"])
        #expect(auth.reasons == ["aggiungere deb.debian.org ai domini permessi della VM vm"])
        // Already there: nothing widens, so nothing is asked.
        let again = try await env.allow("deb.debian.org", auth)
        #expect(again.contains("già tra i domini permessi"))
        #expect(auth.reasons.count == 1)
        #expect(env.allowList() == ["deb.debian.org"])
    }

    /// A broad wildcard asks first, as in the app ("Aggiungi comunque"), then Touch ID; declined,
    /// nothing is asked nor written. A narrow name or wildcard is never asked.
    @Test func broadWildcardAsksBeforeTouchID() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let auth = FakeAuthenticator(result: true)
        var prompts: [String] = []
        await #expect(throws: CLIError.netAllowCancelled) {
            _ = try await env.allow("*.example.com", confirm: { prompts.append($0); return false }, auth)
        }
        #expect(prompts == ["*.example.com vale per ogni nome sotto example.com: siti e servizi di chiunque vi abbia un indirizzo, non di un solo sito. Aggiungerlo comunque? Dopo serve Touch ID o la password del Mac. [s/N] "])
        #expect(auth.reasons.isEmpty)
        #expect(env.policyFile == nil)
        _ = try await env.allow("*.example.com", confirm: { prompts.append($0); return true }, auth)
        #expect(prompts.count == 2)
        #expect(env.allowList() == ["*.example.com"])
        #expect(auth.reasons.count == 1)
        _ = try await env.allow("*.cdn.example.org", confirm: { prompts.append($0); return false }, auth)
        _ = try await env.allow("deb.debian.org", confirm: { prompts.append($0); return false }, auth)
        #expect(prompts.count == 2)
        #expect(CLIError.netAllowCancelled.errorDescription == "aggiunta annullata: egress.json non è cambiato")
    }

    @Test func allowIsRefusedWithoutAnInteractiveSession() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let auth = FakeAuthenticator(result: true)
        await #expect(throws: CLIError.notInteractive) { _ = try await env.allow("deb.debian.org", interactive: false, auth) }
        #expect(auth.reasons.isEmpty)
        #expect(env.policyFile == nil)
    }

    @Test func allowIsRefusedWhenAuthenticationFails() async throws {
        let env = try Env()
        defer { env.cleanup() }
        try env.setAllow(["deb.debian.org"])
        let before = env.policyFile
        let auth = FakeAuthenticator(result: false)
        await #expect(throws: CLIError.authenticationFailed) { _ = try await env.allow("example.com", auth) }
        #expect(auth.reasons.count == 1)
        #expect(env.policyFile == before)
        #expect(CLISupport.message(for: CLIError.authenticationFailed).contains("non è cambiata"))
    }

    @Test func allowRefusesAnInvalidDomainBeforeAskingAndEchoesItSafely() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let auth = FakeAuthenticator(result: true)
        do {
            _ = try await env.allow("evil\u{202E}moc.\u{1B}[31m\u{2028}1.2.3.4", auth)
            Issue.record("accepted")
        } catch {
            let message = CLISupport.message(for: error)
            #expect(!message.unicodeScalars.contains { scalar in
                [.control, .format, .lineSeparator, .paragraphSeparator].contains(scalar.properties.generalCategory)
            })
            #expect(message.contains("dominio non valido"))
        }
        #expect(auth.reasons.isEmpty)
        #expect(env.policyFile == nil)
    }

    @Test func allowRefusesBeyondTheMostDomains() async throws {
        let env = try Env()
        defer { env.cleanup() }
        try env.setAllow((0..<EgressPolicy.maxPatterns).map { "h\($0).example.com" })
        let auth = FakeAuthenticator(result: true)
        await #expect(throws: CLIError.tooManyDomains) { _ = try await env.allow("deb.debian.org", auth) }
        #expect(auth.reasons.isEmpty)
    }

    // MARK: - deny

    @Test func denyRemovesWithoutTouchID() throws {
        let env = try Env()
        defer { env.cleanup() }
        try env.setAllow(["deb.debian.org", "example.com"])
        let text = try CLISupport.netDeny(vm: "vm", domain: "example.com", paths: env.paths)
        #expect(text.contains("Tolto example.com"))
        #expect(env.allowList() == ["deb.debian.org"])
        let absent = try CLISupport.netDeny(vm: "vm", domain: "example.com", paths: env.paths)
        #expect(absent == "example.com non è tra i domini permessi di vm.")
        // An exact name does not remove a wildcard.
        try env.setAllow(["*.debian.org"])
        _ = try CLISupport.netDeny(vm: "vm", domain: "debian.org", paths: env.paths)
        #expect(env.allowList() == ["*.debian.org"])
    }

    // MARK: - Malformed egress.json

    @Test func malformedPolicyIsRefusedWithTheWayOut() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let bad = try env.breakPolicy()
        let auth = FakeAuthenticator(result: true)
        let refusal = CLIError.malformedEgressPolicy(vm: "vm", path: env.bundle.egressPolicyURL.path)
        #expect(throws: refusal) { _ = try CLISupport.netList(vm: "vm", paths: env.paths) }
        #expect(throws: refusal) { _ = try CLISupport.netDeny(vm: "vm", domain: "example.com", paths: env.paths) }
        await #expect(throws: refusal) { _ = try await env.allow("example.com", auth) }
        #expect(auth.reasons.isEmpty)
        #expect(env.policyFile == bad)
        let message = CLISupport.message(for: refusal)
        #expect(message.contains(env.bundle.egressPolicyURL.path))
        #expect(message.contains("nido net reset vm"))
    }

    @Test func malformedPathIsEchoedSafely() {
        let message = CLISupport.message(for: CLIError.malformedEgressPolicy(vm: "vm", path: "/x\u{202E}y\u{1B}]52;\u{7}/egress.json"))
        #expect(message.contains("/xy]52;/egress.json"))
    }

    // MARK: - reset

    @Test func resetWritesTheBaseListAfterConfirmationAndTouchID() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let bad = try env.breakPolicy()
        let auth = FakeAuthenticator(result: true)
        var questions: [String] = []
        // Refused without a terminal, or when the answer is no: the file is left as it is.
        await #expect(throws: CLIError.notInteractive) {
            _ = try await CLISupport.netReset(vm: "vm", paths: env.paths, interactive: false, confirm: { _ in true },
                                              authenticator: auth)
        }
        await #expect(throws: CLIError.netResetCancelled) {
            _ = try await CLISupport.netReset(vm: "vm", paths: env.paths, interactive: true, confirm: { question in
                questions.append(question)
                return false
            }, authenticator: auth)
        }
        #expect(auth.reasons.isEmpty)
        #expect(questions.count == 1 && questions[0].contains("[s/N]"))
        let refused = FakeAuthenticator(result: false)
        await #expect(throws: CLIError.authenticationFailed) {
            _ = try await CLISupport.netReset(vm: "vm", paths: env.paths, interactive: true, confirm: { _ in true },
                                              authenticator: refused)
        }
        #expect(env.policyFile == bad)
        // Confirmed and authenticated: the base list.
        let text = try await CLISupport.netReset(vm: "vm", paths: env.paths, interactive: true, confirm: { _ in true },
                                                 authenticator: auth)
        #expect(text.contains("lista di base"))
        #expect(auth.reasons == ["riscrivere la lista dei domini permessi della VM vm"])
        #expect(EgressPolicyStore.load(bundle: env.bundle) == EgressPolicy.base)
    }

    /// On a running VM, the confirmation says open connections may be cut.
    /// A macOS VM gets the macOS base list (activation, updates, time), never the Linux one.
    @Test func resetWritesTheMacOSBaseListOfAMacVM() async throws {
        let env = try Env(guest: .macos)
        defer { env.cleanup() }
        _ = try env.breakPolicy()
        var questions: [String] = []
        let text = try await CLISupport.netReset(vm: "vm", paths: env.paths, interactive: true, confirm: { question in
            questions.append(question)
            return true
        }, authenticator: FakeAuthenticator(result: true))
        #expect(EgressPolicyStore.load(bundle: env.bundle) == EgressPolicy.macOSBase)
        #expect(questions.count == 1 && questions[0].contains("lista di base"))
        #expect(!questions[0].contains("lista vuota"))
        #expect(text.contains("lista di base"))
    }

    /// `nido start` prefixes each network notice with "Rete: " once: a notice that already
    /// starts with "Rete" (the uplink loss) is printed as it is.
    @Test func networkNoticeLinesAreNotPrefixedTwice() {
        #expect(CLISupport.networkNoticeLine("bloccato example.com:443") == "Rete: bloccato example.com:443")
        let lost = EgressEvent.uplinkLostMessage(reason: "gvproxy è terminato")
        #expect(CLISupport.networkNoticeLine(lost) == lost)
        #expect(!CLISupport.networkNoticeLine(lost).contains("Rete: Rete"))
    }

    /// A config that cannot be read: refused, never taken for a Linux VM (the base list is
    /// never written over a list whose VM is unknown).
    @Test func resetRefusesAnUnreadableConfig() async throws {
        let env = try Env(guest: .macos)
        defer { env.cleanup() }
        try env.setAllow([])
        try Data("{garbage".utf8).write(to: env.bundle.configURL)
        let before = env.policyFile
        let auth = FakeAuthenticator(result: true)
        var questions: [String] = []
        await #expect(throws: (any Error).self) {
            _ = try await CLISupport.netReset(vm: "vm", paths: env.paths, interactive: true, confirm: { question in
                questions.append(question)
                return true
            }, authenticator: auth)
        }
        #expect(questions.isEmpty)
        #expect(auth.reasons.isEmpty)
        #expect(env.policyFile == before)
    }

    @Test func resetWarnsWhenTheVMRuns() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let lock = try BundleLock.acquire(env.bundle, owner: .cli)
        defer { lock.release() }
        var questions: [String] = []
        _ = try? await CLISupport.netReset(vm: "vm", paths: env.paths, interactive: true, confirm: { question in
            questions.append(question)
            return false
        }, authenticator: FakeAuthenticator(result: true))
        #expect(questions.count == 1)
        #expect(questions[0].contains("La VM è accesa"))
        #expect(questions[0].contains("interrotte"))
    }

    // MARK: - log

    @Test func logPrintsEntriesAndFiltersBlocks() throws {
        let env = try Env()
        defer { env.cleanup() }
        let log = try EgressLog(bundle: env.bundle)
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        log.append(EgressLogEntry(time: t, domain: "deb.debian.org", ip: "151.101.2.132", port: 443, proto: .tcp,
                                  bytesOut: 2048, bytesIn: 3 << 20, verdict: .allowed, count: 4))
        log.append(EgressLogEntry(time: t + 1, domain: "example.com", ip: "192.168.64.1", port: 53, proto: .udp,
                                  verdict: .name, repeats: 2))
        log.append(EgressLogEntry(time: t + 2, domain: nil, ip: "93.184.215.14", port: 443, proto: .tcp,
                                  verdict: .denyUnknown))
        log.append(EgressLogEntry(time: t + 3, domain: nil, ip: nil, port: nil, proto: .other, verdict: .suppressed,
                                  lostBlocks: 7, lostFlows: 0, lostNoise: 3))
        log.append(EgressLogEntry(time: t + 4, domain: "deb.debian.org", ip: "151.101.2.200", port: 443, proto: .tcp,
                                  bytesOut: 1024, bytesIn: 2048, verdict: .allowed, via: "debian.map.fastly.net"))
        log.close()
        let utc = try #require(TimeZone(identifier: "UTC"))
        let all = try CLISupport.netLog(vm: "vm", paths: env.paths, blockedOnly: false, timeZone: utc)
        #expect(all == """
            2027-01-15 08:00:00  permesso    tcp  deb.debian.org 151.101.2.132:443  4 flussi, inviati 2 KiB, ricevuti 3 MiB
            2027-01-15 08:00:01  bloccato    udp  example.com 192.168.64.1:53  nome non permesso (e altre 2 volte prima)
            2027-01-15 08:00:02  bloccato    tcp  93.184.215.14:443  indirizzo mai risolto per un dominio permesso
            2027-01-15 08:00:03  non registrati: 7 blocchi, 0 flussi, 3 pacchetti locali (limite del relè)
            2027-01-15 08:00:04  permesso    tcp  deb.debian.org via debian.map.fastly.net 151.101.2.200:443  inviati 1 KiB, ricevuti 2 KiB
            """)
        let blocked = try CLISupport.netLog(vm: "vm", paths: env.paths, blockedOnly: true, timeZone: utc)
        #expect(!blocked.contains("  permesso  "))
        #expect(blocked.split(separator: "\n").count == 3)
    }

    /// Counts of one agree with their noun ("1 blocco", not "1 blocchi").
    @Test func notLoggedCountsAgreeWithOne() {
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        let one = EgressLogEntry(time: t, domain: nil, ip: nil, port: nil, proto: .other, verdict: .suppressed,
                                 lostBlocks: 1, lostFlows: 1, lostNoise: 1)
        #expect(CLISupport.logLine(one, time: "T")
            == "T  non registrati: 1 blocco, 1 flusso, 1 pacchetto locale (limite del relè)")
        let many = EgressLogEntry(time: t, domain: nil, ip: nil, port: nil, proto: .other, verdict: .suppressed,
                                  lostBlocks: 2, lostFlows: 3)
        #expect(CLISupport.logLine(many, time: "T") == "T  non registrati: 2 blocchi, 3 flussi (limite del relè)")
        let repeatedOnce = EgressLogEntry(time: t, domain: "example.com", ip: "192.168.64.1", port: 53, proto: .udp,
                                          verdict: .name, repeats: 1)
        #expect(CLISupport.logLine(repeatedOnce, time: "T").hasSuffix("nome non permesso (e un'altra volta prima)"))
    }

    /// The base-list questions and result agree with a list of one domain, in every language
    /// (no base list has one domain today: the catalog's `one` cases are checked directly).
    @Test func resetTextsAgreeWithOneDomain() {
        let (vm, one, two) = ("vm", 1, 2)
        #expect(L10n.string("Rewrite \(vm)’s egress.json with the base list (\(one) domains)? The current file will be replaced. [y/N] ")
            == "Riscrivere egress.json di vm con la lista di base (1 dominio)? Il file attuale viene sostituito. [s/N] ")
        #expect(L10n.string("Rewrote \(vm)’s egress.json with the base list (\(one) domains).")
            == "egress.json di vm riscritto con la lista di base (1 dominio).")
        #expect(L10n.string("Rewrote \(vm)’s egress.json with the base list (\(two) domains).")
            == "egress.json di vm riscritto con la lista di base (2 domini).")
        let expected = [
            "en": "Rewrote vm’s egress.json with the base list (1 domain).",
            "de": "egress.json von vm mit der Basisliste neu geschrieben (1 Domain).",
            "es": "egress.json de vm reescrito con la lista básica (1 dominio).",
            "fr": "egress.json de vm réécrit avec la liste de base (1 domaine).",
        ]
        for (language, text) in expected {
            #expect(L10n.string("Rewrote \(vm)’s egress.json with the base list (\(one) domains).", language: language) == text)
        }
        #expect(L10n.string("Rewrite \(vm)’s egress.json with the base list (\(one) domains)? The current file will be replaced. The VM is running: open connections to domains outside the base list will be cut. [y/N] ", language: "en")
            .contains("(1 domain)?"))
    }

    @Test func logHidesLocalNoiseUnlessAsked() throws {
        let env = try Env()
        defer { env.cleanup() }
        let log = try EgressLog(bundle: env.bundle)
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        log.append(EgressLogEntry(time: t, domain: nil, ip: "ff02::2", port: nil, proto: .other, verdict: .ipv6))
        log.append(EgressLogEntry(time: t + 1, domain: nil, ip: "224.0.0.252", port: 5355, proto: .udp,
                                  verdict: .broadcast, repeats: 1))
        log.append(EgressLogEntry(time: t + 2, domain: "api.snapcraft.io", ip: "192.168.127.1", port: 53, proto: .udp,
                                  verdict: .name))
        // A real IPv6 destination is never noise.
        log.append(EgressLogEntry(time: t + 3, domain: nil, ip: "2001:db8::1", port: 443, proto: .tcp, verdict: .ipv6))
        log.close()
        let utc = try #require(TimeZone(identifier: "UTC"))
        let quiet = try CLISupport.netLog(vm: "vm", paths: env.paths, blockedOnly: true, timeZone: utc)
        #expect(quiet == """
            2027-01-15 08:00:02  bloccato    udp  api.snapcraft.io 192.168.127.1:53  nome non permesso
            2027-01-15 08:00:03  bloccato    tcp  2001:db8::1:443  IPv6
            (2 blocchi di rumore locale nascosti: IPv6 multicast e link-local, broadcast; non escono dalla VM. --all per vederli.)
            """)
        let all = try CLISupport.netLog(vm: "vm", paths: env.paths, blockedOnly: true, includeNoise: true, timeZone: utc)
        #expect(all.split(separator: "\n").count == 4)
        #expect(all.contains("ff02::2") && !all.contains("nascost"))
    }

    @Test func logOfOnlyNoiseSaysSo() throws {
        let env = try Env()
        defer { env.cleanup() }
        let log = try EgressLog(bundle: env.bundle)
        log.append(EgressLogEntry(time: Date(timeIntervalSince1970: 1_800_000_000), domain: nil, ip: "ff02::16",
                                  port: nil, proto: .other, verdict: .ipv6))
        log.close()
        #expect(try CLISupport.netLog(vm: "vm", paths: env.paths, blockedOnly: false) == """
            Nessuna connessione registrata.
            (1 blocco di rumore locale nascosto: IPv6 multicast e link-local, broadcast; non escono dalla VM. --all per vederli.)
            """)
    }

    @Test func logIsEmptyOrEchoedSafely() throws {
        let env = try Env()
        defer { env.cleanup() }
        #expect(try CLISupport.netLog(vm: "vm", paths: env.paths, blockedOnly: false) == "Nessuna connessione registrata.")
        #expect(try CLISupport.netLog(vm: "vm", paths: env.paths, blockedOnly: true) == "Nessun blocco registrato.")
        // A tampered line cannot reach the terminal with controls, bidi or separators.
        let line = #"{"bytesIn":0,"bytesOut":0,"domain":"evil‮moc\u001B[2J x","ip":"1.2.3.4\u0007","proto":"tcp","time":"2027-01-15T08:00:00Z","verdict":"denyDomain"}"#
        try Data((line + "\n").utf8).write(to: env.bundle.egressLogURL)
        let text = try CLISupport.netLog(vm: "vm", paths: env.paths, blockedOnly: false)
        #expect(text.contains("evilmoc[2Jx 1.2.3.4"))
        #expect(!text.unicodeScalars.contains { scalar in
            [.control, .format, .lineSeparator, .paragraphSeparator].contains(scalar.properties.generalCategory)
        })
    }
}
