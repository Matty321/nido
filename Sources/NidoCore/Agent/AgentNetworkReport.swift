// SPDX-License-Identifier: Apache-2.0
import Foundation
import Synchronization

/// What `nido mcp` tells the model about the VM's controlled network: the blocks since the last
/// call, and the network in one line for `status`. English only, never localized.
public protocol AgentNetworkReporting: Sendable {
    /// The blocks logged since the previous call (since creation, for the first one); nil when
    /// there is nothing to report.
    func newBlocksLine() -> String?
    /// The VM's network and its allowed domains; nil when the VM's config can't be read.
    func statusLine() -> String?
}

/// Tails the VM's `egress.log` (both generations, `EgressLog.readEntries`) from the moment it is
/// created: older blocks are never reported, each new one once, also across a rotation. The model
/// sees only plain host names and counts: never addresses, ports or byte counts.
public final class AgentNetworkReport: AgentNetworkReporting {
    /// Most names listed in a line; the rest are counted.
    static let maxNames = 10
    /// Most allowed patterns listed by `statusLine`; the rest are counted.
    static let maxPatterns = 20

    /// Names macOS asks for on its own (from agent-27's live log, 2026-11-21; `arpa` covers the
    /// reverse lookups and the `_dns.resolver.arpa` resolver discovery; `origin-apple.com.akadns.net`
    /// is Apple's CDN through Akamai, not `akadns.net` as a whole): counted, never named. A
    /// name matches when it equals a suffix or ends with "." and the suffix.
    public static let backgroundSuffixes: [String] = [
        "apple.com", "cdn-apple.com", "icloud.com", "icloud-content.com", "apple-cloudkit.com", "apple.news",
        "aaplimg.com", "mzstatic.com", "apple", "arpa", "safebrowsing.googleapis.com",
        "ocsp.digicert.com", "ssl.gstatic.com", "origin-apple.com.akadns.net",
    ]

    private let bundle: VMBundle
    private let hintVM: String
    private let now: Date
    private let readEntries: @Sendable (URL) -> [EgressLogEntry]
    private let loadPolicy: @Sendable (VMBundle) -> EgressPolicy?
    private let cursor: Mutex<EgressLogCursor?>

    /// `hintVM` is the name the model is told to pass to `nido net allow`. The log is read once
    /// here, so only blocks logged after this moment are reported.
    public init(
        bundle: VMBundle, hintVM: String, now: Date = Date(),
        readEntries: @escaping @Sendable (URL) -> [EgressLogEntry] = { EgressLog.readEntries(at: $0) },
        loadPolicy: @escaping @Sendable (VMBundle) -> EgressPolicy? = { EgressPolicyStore.load(bundle: $0) }
    ) {
        self.bundle = bundle
        self.hintVM = hintVM
        self.now = now
        self.readEntries = readEntries
        self.loadPolicy = loadPolicy
        let entries = readEntries(bundle.egressLogURL)
        cursor = Mutex(EgressLogCursor.newEntries(entries, after: nil, since: .distantPast).cursor)
    }

    public func newBlocksLine() -> String? {
        // Read under the lock: a read older than the cursor would move it back.
        let fresh = cursor.withLock { cursor in
            let entries = readEntries(bundle.egressLogURL)
            let (fresh, next) = EgressLogCursor.newEntries(entries, after: cursor, since: now)
            cursor = next
            return fresh
        }
        return Self.blocksLine(fresh, hintVM: hintVM)
    }

    public func statusLine() -> String? {
        guard let config = try? bundle.readConfig() else { return nil }
        guard config.controlledNetwork == true else { return "Network: Apple's NAT, not filtered by Nido" }
        guard let policy = loadPolicy(bundle) else { return "Network: controlled; the allowed domains can't be read" }
        guard !policy.allow.isEmpty else { return "Network: controlled; no allowed domains" }
        let patterns = policy.allow.map(\.description)
        return "Network: controlled; allowed domains: " + Self.list(patterns, max: Self.maxPatterns)
    }

    /// The line for `entries`: refused names (`.name`) and names whose addresses were refused
    /// (`.denyDomain`), each once in order of first appearance, at most `maxNames`; blocks of
    /// macOS background services counted apart, and only on a line that names a domain. A name is
    /// listed only when `nido net allow` takes it as it is (`DomainPattern.exactName`); any other
    /// one (an address, `_x.example.com`) is dropped. Nil when nothing is reported.
    public static func blocksLine(_ entries: [EgressLogEntry], hintVM: String) -> String? {
        var names: [String] = []
        var background = 0
        for entry in entries where entry.verdict == .name || entry.verdict == .denyDomain {
            guard let name = entry.domain.flatMap(plainName) else { continue }
            if isBackground(name) {
                background += 1
            } else if let exact = DomainPattern.exactName(name), !names.contains(exact) {
                names.append(exact)
            }
        }
        guard !names.isEmpty else { return nil }
        var line = "Network: blocked \(list(names, max: maxNames)) (not on the allowed domains; nothing was sent to "
            + "them). If the task needs one, stop and ask the user to run: nido net allow \(hintVM) <domain>"
        if background > 0 {
            let blocks = background == 1 ? "1 block" : "\(background) blocks"
            line += ". Also \(blocks) of macOS background services (usually not needed)."
        }
        return line
    }

    /// `name` lowercased when every character is in `a-z 0-9 - _ .` and it is at most
    /// `DomainPattern.maxNameLength` long; nil for anything else (spaces, Unicode, controls).
    static func plainName(_ name: String) -> String? {
        let lower = name.lowercased()
        guard !lower.isEmpty, lower.utf8.count <= DomainPattern.maxNameLength,
              lower.utf8.allSatisfy({ byte in
                  (byte >= 0x61 && byte <= 0x7A) || (byte >= 0x30 && byte <= 0x39) || byte == 0x2D || byte == 0x5F
                      || byte == 0x2E
              })
        else { return nil }
        return lower
    }

    static func isBackground(_ name: String) -> Bool {
        backgroundSuffixes.contains { name == $0 || name.hasSuffix("." + $0) }
    }

    /// The first `max` items joined by ", ", then ", and <n> more" for the rest.
    private static func list(_ items: [String], max: Int) -> String {
        let shown = items.prefix(max).joined(separator: ", ")
        return items.count > max ? shown + ", and \(items.count - max) more" : shown
    }
}
