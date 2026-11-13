// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation

/// One entry of a VM's egress allowlist: an exact host name (`deb.debian.org`, which covers only
/// itself) or `*.suffix` (`*.debian.org`, which covers `debian.org` and every name under it).
///
/// Always valid once built: lowercase ASCII (a Unicode name is converted to its IDNA "xn--"
/// form), no trailing dot, letters/digits/hyphens in labels of 1–63 characters, at most 253
/// characters in all, at least two labels (so neither `localhost` nor `*.com`), and never an
/// IP literal (the last label is never all digits). Coded as its plain string.
public struct DomainPattern: Codable, Hashable, Sendable, CustomStringConvertible {
    /// The suffix for a wildcard, the name itself otherwise (no `*.`).
    public let name: String
    public let isWildcard: Bool

    /// Longest accepted name (RFC 1035, without the trailing dot).
    public static let maxNameLength = 253
    /// Longest accepted label.
    public static let maxLabelLength = 63
    /// Input longer than this is refused before any conversion.
    static let maxInputLength = 1024

    /// Parses and normalizes `text` (surrounding whitespace and one trailing dot are dropped);
    /// throws `NidoError.invalidDomain` otherwise.
    public init(_ text: String) throws {
        let refusal = NidoError.invalidDomain(Self.echo(text))
        guard text.utf8.count <= Self.maxInputLength else { throw refusal }
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let wildcard = body.hasPrefix("*.")
        if wildcard { body.removeFirst(2) }
        if body.hasSuffix(".") { body.removeLast() }
        guard let ascii = Self.asciiName(body), Self.isValidName(ascii) else { throw refusal }
        name = ascii
        isWildcard = wildcard
    }

    public var description: String { isWildcard ? "*." + name : name }

    /// True when `queried` (a DNS name, any case, with or without the trailing dot) is covered.
    /// A name that is not a well-formed host name never matches.
    public func matches(_ queried: String) -> Bool {
        guard let candidate = Self.normalizedQueryName(queried) else { return false }
        if candidate == name { return true }
        return isWildcard && candidate.hasSuffix("." + name)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(try container.decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }

    // MARK: - Names

    /// `queried` lowercased without its trailing dot, when it is a well-formed name (labels of
    /// 1–63 letters/digits/hyphens/underscores, at most 253 characters); nil otherwise. Names
    /// seen in DNS traffic may hold underscores (`_dmarc`), which no pattern does.
    ///
    /// Names from the wire are ASCII (punycode for Unicode names): any byte >= 0x80 is refused
    /// before lowercasing, and only `A`–`Z` are lowered, so Unicode case folding (the KELVIN SIGN
    /// U+212A lowers to `k`) can never turn a name into an allowed one.
    static func normalizedQueryName(_ queried: String) -> String? {
        guard queried.utf8.count <= maxNameLength + 1, queried.utf8.allSatisfy({ $0 < 0x80 }) else { return nil }
        var candidate = asciiLowercased(queried)
        if candidate.hasSuffix(".") { candidate.removeLast() }
        guard !candidate.isEmpty, candidate.utf8.count <= maxNameLength else { return nil }
        for label in candidate.utf8.split(separator: UInt8(ascii: "."), omittingEmptySubsequences: false) {
            guard !label.isEmpty, label.count <= maxLabelLength,
                label.allSatisfy({ isLDH($0) || $0 == UInt8(ascii: "_") })
            else { return nil }
        }
        return candidate
    }

    /// The lowercase ASCII form of `body`: unchanged when it is ASCII (only letters, digits,
    /// hyphens and dots are kept for checking), IDNA-converted by Foundation when it holds
    /// Unicode letters. Nil when it holds anything else.
    private static func asciiName(_ body: String) -> String? {
        guard !body.isEmpty else { return nil }
        if body.utf8.allSatisfy({ $0 < 0x80 }) {
            let lower = asciiLowercased(body)
            return lower.utf8.allSatisfy({ isLDH($0) || $0 == UInt8(ascii: ".") }) ? lower : nil
        }
        // Unicode: the ASCII part must already be name characters, so the URL parser below sees
        // a bare host and nothing it could read as a port, user, path or IP address.
        // The result is checked again like any ASCII name.
        guard body.unicodeScalars.allSatisfy({ $0.value >= 0x80 || isLDH(UInt8($0.value)) || $0 == "." }) else {
            return nil
        }
        var components = URLComponents()
        components.scheme = "http"
        components.host = body
        guard let host = components.encodedHost, host.utf8.allSatisfy({ $0 < 0x80 }) else { return nil }
        return host.lowercased()
    }

    /// Two or more LDH labels (no leading or trailing hyphen) and a last label that is not all
    /// digits (no IPv4 literal in any of its spellings).
    private static func isValidName(_ ascii: String) -> Bool {
        guard ascii.utf8.count <= maxNameLength else { return false }
        let labels = ascii.utf8.split(separator: UInt8(ascii: "."), omittingEmptySubsequences: false)
        guard labels.count >= 2 else { return false }
        for label in labels {
            guard !label.isEmpty, label.count <= maxLabelLength, label.allSatisfy(isLDH),
                label.first != UInt8(ascii: "-"), label.last != UInt8(ascii: "-")
            else { return false }
        }
        guard let last = labels.last, !last.allSatisfy({ (0x30...0x39).contains($0) }) else { return false }
        // `0x7f` style labels would make a hexadecimal IPv4 spelling: refuse a last label that
        // starts with a digit too (no top-level domain does).
        return !(0x30...0x39).contains(last.first ?? 0)
    }

    /// `text` with only `A`–`Z` lowered (every other byte unchanged).
    static func asciiLowercased(_ text: String) -> String {
        String(decoding: text.utf8.map { (0x41...0x5A).contains($0) ? $0 | 0x20 : $0 }, as: UTF8.self)
    }

    /// `text` as echoed in a refusal: control, format (bidi, zero-width) and line/paragraph
    /// separator characters dropped (`ConsoleSanitizer.echoable`), at most 80 characters.
    private static func echo(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: text.unicodeScalars.lazy.filter(ConsoleSanitizer.isEchoable).prefix(81))
        let clean = String(scalars)
        return clean.count > 80 ? String(clean.prefix(80)) + "…" : clean
    }

    private static func isLDH(_ byte: UInt8) -> Bool {
        (0x61...0x7A).contains(byte) || (0x30...0x39).contains(byte) || byte == UInt8(ascii: "-")
            || (0x41...0x5A).contains(byte)
    }
}

/// A VM's egress allowlist, stored in its bundle as `egress.json` (`EgressPolicyStore`):
/// `{"v":1,"allow":["deb.debian.org","*.debian.org"]}`. Decoding refuses any other `v`, an invalid
/// pattern, or more than `maxPatterns` entries, so a damaged file never reads as a wider list.
public struct EgressPolicy: Codable, Equatable, Sendable {
    /// Format version; always `currentVersion` (1).
    public var v: Int
    public var allow: [DomainPattern]

    public static let currentVersion = 1
    /// Most patterns a policy may hold.
    public static let maxPatterns = 512
    /// The policy of a VM without `egress.json`: nothing is allowed.
    public static let empty = EgressPolicy(v: currentVersion, allow: [])
    /// The list a new VM starts from (`VMFactory`), and what `nido net reset` writes: Debian
    /// packages and updates, `ollama pull` and one time server, nothing else. Exact names only.
    /// CDN names reached through a CNAME of these (`debian.map.fastlydns.net`) need no entry: the
    /// relay follows the chain.
    ///
    /// Verified on 2026-10-29 in throwaway Debian 13 VMs on the relay, starting from
    /// `deb.debian.org` alone and adding only what the log showed refused:
    /// - `deb.debian.org`: cloud-init's first-boot packages, `apt-get update` and `install`,
    ///   security updates too (the image's mirror lists point both archives there);
    /// - `registry.ollama.ai`, `dd20bb891979d25aebc8bec07b2b3bbc.r2.cloudflarestorage.com`:
    ///   `ollama pull` (manifest, then the blobs' redirect to Ollama's R2 bucket). The R2 host is
    ///   Ollama's bucket: if Ollama moves its blobs, `ollama pull` fails until this list (or the
    ///   VM's, with `nido net allow`) names the new host. Accepted;
    /// - `time.cloudflare.com`: the guest's only NTP server (`GuestTimeSync`, set by the seed).
    /// Left out on purpose:
    /// - GitHub: Nido downloads the pinned Ollama archive on the Mac and sends it over SSH
    ///   (`OllamaArchiveStore`, `AIRuntime.install`); the guest never asks for it;
    /// - the Debian NTP pool: volunteer addresses the relay would open on every port;
    /// - `ollama.com`: asked by the Ollama service at start, not needed.
    public static let base = exact(["deb.debian.org"] + sharedBase)

    /// The base list of a new Ubuntu VM: as `base`, with the Ubuntu archive instead of Debian's.
    /// Verified on 2026-11-02 in a throwaway Ubuntu 26.04 VM on the relay: its arm64 cloud image's
    /// `ubuntu.sources` points to `archive.ubuntu.com` and `security.ubuntu.com` (with only
    /// `ports.ubuntu.com` cloud-init's first-boot packages were not found); `ports.ubuntu.com`
    /// is the arm64 archive of the releases before. Exact names only. Left out on purpose: the
    /// Ubuntu NTP pools (the seed pins `GuestTimeSync.server`), `motd.ubuntu.com`,
    /// `api.snapcraft.io`, `changelogs.ubuntu.com`, `entropy.ubuntu.com` (pollinate) and
    /// `contracts.canonical.com` (Ubuntu Pro), asked in the background and not needed (seen
    /// refused in the 26.04 and 24.04 VMs). A new Ubuntu VM turns them off (`UbuntuQuiet`); in one
    /// created before they show up in the log and can be allowed from there.
    public static let ubuntuBase = exact(
        ["archive.ubuntu.com", "security.ubuntu.com", "ports.ubuntu.com"] + sharedBase)

    /// The base list of a new macOS VM (`MacInstaller`), and what `nido net reset` writes for
    /// one: device activation, software update and the clock, nothing else. Exact names only.
    ///
    /// Seen on 2026-11-02 in a throwaway macOS 26.6.2 VM on the relay (gvproxy), idle in Setup
    /// Assistant with an empty list; a name is here only when it was refused in that log and
    /// Apple documents it for activation, software update or time ("Use Apple products on
    /// enterprise networks"):
    /// - `albert.apple.com`: device activation (allowed, Setup Assistant's activation request
    ///   went through, about 10 KiB each way);
    /// - `gdmf.apple.com`, `mesu.apple.com`: the software update catalogs;
    /// - `swscan.apple.com`, `swdist.apple.com`: what `softwareupdate --list` needs (checked live
    ///   on 2026-11-03: without either it fails, "cannot connect" / "server not found"; with
    ///   both it lists the updates);
    /// - `time.apple.com`: the clock (NTP; the guest's clock matched the Mac's within 0.03 s).
    /// Left out on purpose: `xp.apple.com` (not needed by `softwareupdate`, and it sends more than
    /// it gets: likely analytics), the download CDN (`updates.cdn-apple.com`,
    /// `updates-http.cdn-apple.com`: needed only to download an update, allowed by hand), App
    /// Store and iTunes (`itunes.apple.com`, `bag.itunes.apple.com`), iCloud, Apple ID and
    /// CloudKit (`gateway.icloud.com`, `appleid.apple.com`, `gsa.apple.com`,
    /// `api.apple-cloudkit.com`), push (`push.apple.com`, `init.push.apple.com`), Maps and
    /// location (`gspe*-ssl.ls.apple.com`), and certificate status (`ocsp2.apple.com`,
    /// `ocsp.digicert.com`; macOS goes on without an answer). They show up in the VM's log and
    /// can be allowed from there. Setup Assistant reaches the desktop with this list when the
    /// Apple ID is skipped (checked live on 2026-11-03); an Apple ID sign-in needs more.
    public static let macOSBase = exact([
        "albert.apple.com", "gdmf.apple.com", "mesu.apple.com", "swscan.apple.com", "swdist.apple.com",
        "time.apple.com",
    ])

    /// The base list for a VM of `distribution` (nil: Debian 13, as every VM without one).
    public static func base(for distribution: LinuxDistribution?) -> EgressPolicy {
        (distribution ?? .debian13).isUbuntu ? ubuntuBase : base
    }

    /// `ollama pull` and the time server: in every distribution's base list.
    private static let sharedBase = [
        "registry.ollama.ai",
        "dd20bb891979d25aebc8bec07b2b3bbc.r2.cloudflarestorage.com",
        GuestTimeSync.server,
    ]

    private static func exact(_ names: [String]) -> EgressPolicy {
        EgressPolicy(
            v: currentVersion,
            allow: names.map { name in
                do {
                    return try DomainPattern(name)
                } catch {
                    preconditionFailure("EgressPolicy.base: \(name)")
                }
            })
    }

    public init(v: Int, allow: [DomainPattern]) {
        self.v = v
        self.allow = allow
    }

    /// True when a pattern of the list covers `name`.
    public func allows(_ name: String) -> Bool {
        allow.contains { $0.matches(name) }
    }

    private enum CodingKeys: String, CodingKey { case v, allow }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        v = try container.decode(Int.self, forKey: .v)
        guard v == Self.currentVersion else {
            throw DecodingError.dataCorruptedError(forKey: .v, in: container, debugDescription: "unsupported version")
        }
        allow = try container.decode([DomainPattern].self, forKey: .allow)
        guard allow.count <= Self.maxPatterns else {
            throw DecodingError.dataCorruptedError(forKey: .allow, in: container, debugDescription: "too many patterns")
        }
    }
}

// MARK: - Broad wildcards

extension DomainPattern {
    /// Public suffixes and shared platforms of more than two labels: a wildcard on one of them
    /// opens every site or bucket of everyone under it. Not exhaustive: the most common ones.
    static let sharedSuffixes: Set<String> = [
        "co.uk", "org.uk", "ac.uk", "gov.uk", "me.uk", "ltd.uk", "plc.uk", "net.uk",
        "com.au", "net.au", "org.au", "edu.au", "gov.au", "co.nz", "org.nz", "net.nz",
        "co.jp", "ne.jp", "or.jp", "ac.jp", "go.jp", "co.kr", "or.kr",
        "com.br", "net.br", "org.br", "com.ar", "com.mx", "com.tr", "com.cn", "net.cn", "org.cn",
        "com.hk", "com.sg", "com.tw", "co.in", "net.in", "org.in", "co.za", "co.il", "com.pl", "com.es",
        "github.io", "githubusercontent.com", "gitlab.io", "pages.dev", "workers.dev", "r2.dev",
        "r2.cloudflarestorage.com", "cloudflarestorage.com", "trycloudflare.com",
        "amazonaws.com", "s3.amazonaws.com", "cloudfront.net", "elasticbeanstalk.com",
        "azurewebsites.net", "blob.core.windows.net", "core.windows.net", "azureedge.net", "cloudapp.net",
        "appspot.com", "googleapis.com", "storage.googleapis.com", "googleusercontent.com", "web.app",
        "firebaseapp.com", "run.app", "herokuapp.com", "netlify.app", "vercel.app", "fly.dev",
        "onrender.com", "ngrok.io", "ngrok-free.app", "ngrok.app", "blogspot.com", "fastly.net",
        "global.ssl.fastly.net", "akamaized.net", "akamaiedge.net", "edgekey.net", "hf.space",
        "huggingface.co", "repl.co", "glitch.me", "surge.sh", "duckdns.org", "no-ip.org", "dyndns.org",
    ]

    /// A wildcard so wide that it needs a warning and an extra confirmation: its suffix has two
    /// labels or fewer (`*.com` never parses; `*.example.com` covers every name of a site), is a
    /// known public or platform suffix (`*.co.uk`, `*.r2.cloudflarestorage.com`), or sits under
    /// Amazon's shared `amazonaws.com` space (`*.s3.eu-west-1.amazonaws.com`).
    public var isBroadWildcard: Bool {
        guard isWildcard else { return false }
        if name.split(separator: ".").count <= 2 { return true }
        if Self.sharedSuffixes.contains(name) { return true }
        return name.hasSuffix(".amazonaws.com")
    }
}
