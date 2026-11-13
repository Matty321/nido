// SPDX-License-Identifier: Apache-2.0
import Foundation
import NidoCore

/// `nido net list|log|allow|deny|reset`: the logic, testable without ArgumentParser.
///
/// The list is the VM's `egress.json`, changed only through `EgressPolicyStore` under its lock;
/// a running VM's relay applies a change within seconds. Adding a domain (or resetting the list)
/// needs an interactive session and the owner's Touch ID or Mac password; removing does not. A
/// file that does not load is never taken for an empty list nor overwritten silently: every
/// command refuses it and names `nido net reset`.
extension CLISupport {
    /// The allowlist of `vm`, one pattern per line.
    public static func netList(vm: String, paths: NidoPaths) throws -> String {
        let (name, bundle) = try openNet(vm, paths: paths)
        let policy = try loadPolicy(bundle, name)
        var lines: [String]
        if policy.allow.isEmpty {
            lines = [L10n.string("No allowed domains for \(name.rawValue): the VM can’t reach any site.")]
        } else {
            lines = [L10n.string("Allowed domains for \(name.rawValue):")] + policy.allow.map { "  \(ConsoleSanitizer.echoable($0.description))" }
        }
        lines += controlledNote(bundle, name)
        return lines.joined(separator: "\n")
    }

    /// Adds `domain` to the list of `vm` after the owner's confirmation. Refused, before asking,
    /// for an invalid domain, a list that does not load or is full; refused without a terminal
    /// (`interactive` false) or when the authentication fails. A domain already listed is not
    /// asked for (nothing widens). A broad wildcard (`DomainPattern.isBroadWildcard`) first
    /// needs `confirm` on the warning the app shows too, before the authentication.
    public static func netAllow(
        vm: String, domain: String, paths: NidoPaths, interactive: Bool, confirm: (String) -> Bool,
        authenticator: any OwnerAuthenticator
    ) async throws -> String {
        let (name, bundle) = try openNet(vm, paths: paths)
        let pattern = try DomainPattern(domain)
        let shown = ConsoleSanitizer.echoable(pattern.description)
        let current = try loadPolicy(bundle, name)
        if current.allow.contains(pattern) { return L10n.string("\(shown) is already an allowed domain of \(name.rawValue).") }
        guard current.allow.count < EgressPolicy.maxPatterns else { throw CLIError.tooManyDomains }
        guard interactive else { throw CLIError.notInteractive }
        if pattern.isBroadWildcard {
            let suffix = ConsoleSanitizer.echoable(pattern.name)
            guard confirm(L10n.string("\(shown) covers every name under \(suffix): the sites and services of anyone with an address there, not a single site. Add it anyway? Touch ID or the Mac password comes next. [y/N] "))
            else { throw CLIError.netAllowCancelled }
        }
        guard await authenticator.authenticate(reason: L10n.string("add \(shown) to the allowed domains of the VM \(name.rawValue)")) else {
            throw CLIError.authenticationFailed
        }
        try updatePolicy(bundle, name) { policy in
            guard !policy.allow.contains(pattern) else { return }
            guard policy.allow.count < EgressPolicy.maxPatterns else { throw CLIError.tooManyDomains }
            policy.allow.append(pattern)
        }
        var lines = [L10n.string("Added \(shown) to the allowed domains of \(name.rawValue): it applies within seconds, even while the VM is running.")]
        lines += controlledNote(bundle, name)
        return lines.joined(separator: "\n")
    }

    /// Removes `domain` (the same pattern: an exact name never removes a wildcard) from the list
    /// of `vm`. No authentication: the list only narrows.
    public static func netDeny(vm: String, domain: String, paths: NidoPaths) throws -> String {
        let (name, bundle) = try openNet(vm, paths: paths)
        let pattern = try DomainPattern(domain)
        let shown = ConsoleSanitizer.echoable(pattern.description)
        var removed = false
        try updatePolicy(bundle, name) { policy in
            let before = policy.allow.count
            policy.allow.removeAll { $0 == pattern }
            removed = policy.allow.count < before
        }
        guard removed else { return L10n.string("\(shown) isn’t an allowed domain of \(name.rawValue).") }
        return L10n.string("Removed \(shown) from the allowed domains of \(name.rawValue): open connections to it are being cut.")
    }

    /// A network notice as `nido start` prints it on stderr: prefixed with "Network: ", unless the
    /// notice already names the network (the uplink loss, "Controlled network interrupted: …").
    public static func networkNoticeLine(_ line: String) -> String {
        line.hasPrefix(uplinkLostHeader) ? line : L10n.string("Network: \(line)")
    }

    /// How the uplink-loss notice starts in the UI language: its text before the reason.
    private static var uplinkLostHeader: String {
        let marker = "\u{1}"
        let message = EgressEvent.uplinkLostMessage(reason: marker)
        return message.range(of: marker).map { String(message[..<$0.lowerBound]) } ?? message
    }

    /// Writes the base list of the VM's guest over the list of `vm` (`EgressPolicy.base(for:)`
    /// for a Linux distribution, `EgressPolicy.macOSBase` for macOS), whatever the file holds
    /// (the way out of a damaged `egress.json`), after a confirmation on the terminal and the
    /// owner's authentication.
    public static func netReset(
        vm: String, paths: NidoPaths, interactive: Bool, confirm: (String) -> Bool,
        authenticator: any OwnerAuthenticator
    ) async throws -> String {
        let (name, bundle) = try openNet(vm, paths: paths)
        guard interactive else { throw CLIError.notInteractive }
        // Which list to write depends on the guest: a config that does not read is refused
        // rather than taken for a Linux VM.
        let config = try bundle.readConfig()
        let base = config.guest == .macos ? EgressPolicy.macOSBase : EgressPolicy.base(for: config.distribution)
        let count = base.allow.count
        let shown = name.rawValue
        let question = BundleLock.holder(bundle) != nil
            ? L10n.string("Rewrite \(shown)’s egress.json with the base list (\(count) domains)? The current file will be replaced. The VM is running: open connections to domains outside the base list will be cut. [y/N] ")
            : L10n.string("Rewrite \(shown)’s egress.json with the base list (\(count) domains)? The current file will be replaced. [y/N] ")
        guard confirm(question) else { throw CLIError.netResetCancelled }
        guard await authenticator.authenticate(reason: L10n.string("rewrite the list of allowed domains of the VM \(shown)")) else {
            throw CLIError.authenticationFailed
        }
        try EgressPolicyStore.replace(bundle: bundle, with: base)
        return L10n.string("Rewrote \(shown)’s egress.json with the base list (\(count) domains).")
    }

    /// The connection log of `vm`, oldest first; with `blockedOnly`, only blocks, cuts and
    /// summaries of what the relay left out. Local noise (`EgressLogEntry.isLocalNoise`) only
    /// with `includeNoise`; otherwise a last line says how many lines it hid.
    public static func netLog(
        vm: String, paths: NidoPaths, blockedOnly: Bool, includeNoise: Bool = false, timeZone: TimeZone = .current
    ) throws -> String {
        let (_, bundle) = try openNet(vm, paths: paths)
        let shown = EgressLog.readEntries(bundle: bundle).filter { !blockedOnly || $0.verdict.isBlock }
        let entries = includeNoise ? shown : shown.filter { !$0.isLocalNoise }
        let hidden = shown.count - entries.count
        let footer = hidden == 0 ? "" : "\n" + hiddenNoiseLine(hidden)
        guard !entries.isEmpty else {
            return (blockedOnly ? L10n.string("No blocks logged.") : L10n.string("No connections logged.")) + footer
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return entries.map { logLine($0, time: formatter.string(from: $0.time)) }.joined(separator: "\n") + footer
    }

    static func hiddenNoiseLine(_ count: Int) -> String {
        L10n.string("(\(count) local-noise blocks hidden: IPv6 multicast and link-local, broadcast, which never leave the VM. Use --all to show them.)")
    }

    // MARK: - Helpers

    private static func openNet(_ vm: String, paths: NidoPaths) throws -> (VMName, VMBundle) {
        let name = try VMName(vm)
        return (name, try VMBundle.open(name, paths: paths))
    }

    private static func malformed(_ bundle: VMBundle, _ name: VMName) -> CLIError {
        .malformedEgressPolicy(vm: name.rawValue, path: bundle.egressPolicyURL.path)
    }

    private static func loadPolicy(_ bundle: VMBundle, _ name: VMName) throws -> EgressPolicy {
        guard let policy = EgressPolicyStore.load(bundle: bundle) else { throw malformed(bundle, name) }
        return policy
    }

    /// `EgressPolicyStore.update`, with a file that does not load reported as such.
    private static func updatePolicy(
        _ bundle: VMBundle, _ name: VMName, _ edit: (inout EgressPolicy) throws -> Void
    ) throws {
        do {
            try EgressPolicyStore.update(bundle: bundle, edit)
        } catch NidoError.invalidEgressPolicy {
            throw malformed(bundle, name)
        }
    }

    private static func controlledNote(_ bundle: VMBundle, _ name: VMName) -> [String] {
        guard let config = try? bundle.readConfig(), config.controlledNetwork != true else { return [] }
        return [L10n.string("Note: the controlled network is off for \(name.rawValue): the list applies once you turn it on.")]
    }

    /// One log line: time, outcome, protocol, destination, then byte counts or the reason. Every
    /// text from the file is echoed without controls, bidi or separators.
    static func logLine(_ entry: EgressLogEntry, time: String) -> String {
        if entry.verdict == .suppressed {
            // A plain enumeration: each count agrees with its own noun.
            var counts = [L10n.string("\(entry.lostBlocks ?? 0) blocks"), L10n.string("\(entry.lostFlows ?? 0) flows")]
            if let noise = entry.lostNoise { counts.append(L10n.string("\(noise) local packets")) }
            return "\(time)  " + L10n.string("not logged: \(counts.joined(separator: ", ")) (relay limit)")
        }
        if entry.verdict == .uplinkLost {
            let reason = ConsoleSanitizer.echoable(UplinkLoss.text(entry.reason ?? L10n.string("unknown reason")))
            return "\(time)  " + L10n.string("controlled network interrupted: \(reason) (the VM stays offline until its next start)")
        }
        let address = [entry.ip, entry.port.map(String.init)].compactMap { $0 }.joined(separator: ":")
        let name = entry.domain.map { domain in entry.via.map { "\(domain) via \($0)" } ?? domain }
        let destination = [name, address.isEmpty ? nil : address].compactMap { $0 }.joined(separator: " ")
        let labels = logLabels
        let label: String
        let detail: String
        switch entry.verdict {
        case .allowed, .open, .cut:
            label = entry.verdict == .allowed ? labels.allowed : entry.verdict == .open ? labels.open : labels.cut
            let (sent, received) = (formatBytes(entry.bytesOut), formatBytes(entry.bytesIn))
            let flows = entry.count ?? 1
            detail = flows > 1
                ? L10n.string("\(flows) flows, sent \(sent), received \(received)")
                : L10n.string("sent \(sent), received \(received)")
        default:
            label = labels.blocked
            let repeats = entry.repeats ?? 0
            let why = reason(entry.verdict)
            detail = repeats > 0 ? L10n.string("\(why) (seen \(repeats) more times before)") : why
        }
        // As wide as the longest label in the UI language, so the protocols line up.
        let padded = label.padding(toLength: labels.width, withPad: " ", startingAt: 0)
        let shown = destination.isEmpty ? "-" : ConsoleSanitizer.echoable(destination)
        return "\(time)  \(padded)  \(entry.proto.rawValue)  \(shown)  \(detail)"
    }

    /// The outcome labels of `nido net log`, and the width they are padded to.
    private static var logLabels: (allowed: String, open: String, cut: String, blocked: String, width: Int) {
        let (allowed, open, cut, blocked) = (
            L10n.string("allowed"), L10n.string("open"), L10n.string("cut"), L10n.string("blocked"))
        return (allowed, open, cut, blocked, [allowed, open, cut, blocked].map(\.count).max() ?? 0)
    }

    private static func reason(_ verdict: EgressLogEntry.Verdict) -> String {
        switch verdict {
        case .denyUnknown: L10n.string("address never resolved for an allowed domain")
        case .denyDomain: L10n.string("domain not allowed")
        case .denyProto: L10n.string("only TCP and UDP can leave")
        case .name: L10n.string("name not allowed")
        case .invalidName: L10n.string("invalid name")
        case .aliasQueryType: L10n.string("for an alias, only A, AAAA, CNAME and HTTPS")
        case .dnsBypass: L10n.string("DNS other than Nido’s")
        case .hostSubnet: L10n.string("only DHCP, DNS and SSH can reach the Mac")
        case .broadcast: L10n.string("multicast or broadcast")
        case .ipv6: "IPv6"
        case .spoofed: L10n.string("source address not the VM’s")
        case .malformed: L10n.string("unrecognized packet")
        case .allowed, .open, .cut, .suppressed, .uplinkLost: ""
        }
    }
}
