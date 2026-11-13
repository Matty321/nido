// SPDX-License-Identifier: Apache-2.0
import Compression
import Foundation

public enum GuestToolsInstallError: Error, Equatable, Sendable {
    /// `/etc/os-release` of the guest says neither `ID=debian` nor `ID=ubuntu`.
    case unsupportedDistribution
    /// The payload has a path or mode the installer refuses (a bug of the build, not of the user).
    case invalidPayload(String)
    /// The guest answered in a way the installer does not understand.
    case unexpectedOutput
}

extension GuestToolsInstallError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unsupportedDistribution:
            return L10n.string("unsupported distribution: install by hand, see the README")
        case .invalidPayload(let what):
            return L10n.string("the Guest Tools files aren’t valid: \(what)")
        case .unexpectedOutput:
            return L10n.string("the VM sent an unexpected response while installing the Guest Tools")
        }
    }
}

/// Installs the Nido Guest Tools of `GuestToolsPayload` into an existing, running Debian or Ubuntu guest
/// over SSH: one tar archive on stdin (the payload files and an `install.sh` made of constants),
/// extracted by root into a private temporary directory of the guest and installed from there.
/// Every file of the payload is installed with its exact mode and every `*.service` unit it puts
/// in `/etc/systemd/system/` is enabled and started: the second unit of a later release needs no
/// change here. Units elsewhere (`/opt/nido-guest-tools/ollama/ollama.service`, phase 2) are only
/// copied: `nido-provision` installs and enables them when the user chooses. `/home/nido` is
/// never touched.
public struct GuestToolsInstaller: Sendable {
    public enum Outcome: Equatable, Sendable { case installed, unchanged }

    private let runner: ProcessRunner
    private let resolveSSH: (@Sendable (VMBundle) throws -> SSHEndpoint)?
    private let timeout: Duration

    public init(
        runner: ProcessRunner = SystemProcessRunner(), timeout: Duration = .seconds(120),
        resolveSSH: (@Sendable (VMBundle) throws -> SSHEndpoint)? = nil
    ) {
        self.runner = runner
        self.timeout = timeout
        self.resolveSSH = resolveSSH
    }

    /// Installs (or finds already installed) the Guest Tools in the running VM `bundle` and
    /// records `GuestToolsPayload.version` in its config. The caller holds the VM's lock.
    @discardableResult
    public func install(on bundle: VMBundle) async throws -> Outcome {
        let files = GuestToolsPayload.files.map { (path: $0.path, mode: $0.mode, base64: $0.base64) }
        let archive = try Self.archive(files: files)
        let config = try bundle.readConfig()
        let ssh = resolveSSH.map { GuestSSH(bundle: bundle, config: config, runner: runner, resolveSSH: $0) }
            ?? GuestSSH(bundle: bundle, config: config, runner: runner)

        let output = try await ssh.run(.installGuestTools, stdin: archive, timeout: timeout)
        let lines = output.stdout.split(whereSeparator: \.isNewline).map(String.init)
        let outcome: Outcome
        switch lines.last {
        case "NIDO_RESULT=installed": outcome = .installed
        case "NIDO_RESULT=unchanged": outcome = .unchanged
        case "NIDO_RESULT=unsupported": throw GuestToolsInstallError.unsupportedDistribution
        default: throw GuestToolsInstallError.unexpectedOutput
        }
        // Fresh read: the app may have changed the config (shared folders) during the install.
        if try bundle.readConfig().guestToolsVersion != GuestToolsPayload.version {
            try bundle.updateConfig { $0.guestToolsVersion = GuestToolsPayload.version }
        }
        return outcome
    }

    // MARK: - Script and archive

    /// The only command line sent to the guest (constants): extract the archive from stdin into a
    /// fresh 0700 directory made by `mktemp`, run the `install.sh` it carries, remove the directory.
    static let bootstrapScript =
        #"set -e; find /var/tmp -maxdepth 1 -name 'nido-gt.*' -type d -user root -mmin +10 -exec rm -r -f {} + 2>/dev/null || true; d=$(mktemp -d /var/tmp/nido-gt.XXXXXX); trap 'rm -rf "$d"' EXIT; tar -x -f - -C "$d"; /bin/sh "$d/install.sh""#

    /// The manual installer must fit one paste in Nido's console (`TerminalView.maxPaste`, 32 KiB).
    public static let manualCommandLimit = 32 * 1024

    /// The manual installer for a guest Nido cannot reach over SSH: one text to paste in a shell
    /// of the guest (Nido's console, logged in as the VM's user). The same archive and bootstrap
    /// as `install(on:)`, gzip-compressed, as base64 in a quoted here-document (nothing in it is
    /// expanded), decompressed with the guest's `gunzip` into root's `/bin/sh -c` via sudo.
    public static func manualInstallCommand() throws -> String {
        let files = GuestToolsPayload.files.map { (path: $0.path, mode: $0.mode, base64: $0.base64) }
        let gz = try GzipWriter.compress(try archive(files: files))
        let encoded = gz.base64EncodedString(options: [.lineLength76Characters, .endLineWithLineFeed])
        return "base64 -d <<'NIDO_GUEST_TOOLS' | gunzip | sudo /bin/sh -c " + GuestCommand.shellQuote(bootstrapScript)
            + "\n" + encoded + "\nNIDO_GUEST_TOOLS\n"
    }

    private static func isSafePath(_ path: String) -> Bool {
        path.hasPrefix("/") && !path.contains("//") && path.utf8.count < 200
            && !path.split(separator: "/").contains("..")
            && path.unicodeScalars.allSatisfy {
                ($0.value >= 0x30 && $0.value <= 0x39) || ($0.value >= 0x41 && $0.value <= 0x5A)
                    || ($0.value >= 0x61 && $0.value <= 0x7A) || "/._-".unicodeScalars.contains($0)
            }
    }

    /// Where the guest keeps the list of files the installed Guest Tools put there.
    static let optRoot = "/opt/nido-guest-tools"
    static let unitDir = "/etc/systemd/system"

    /// `install.sh`: idempotent. A file is (re)installed when it is missing, differs (`cmp`) or has
    /// another mode; what the previous version installed (its `MANIFEST`) and this payload no
    /// longer has is removed (`pruneLines`); the unit files then make `daemon-reload`, and a
    /// changed or not-running unit is enabled and (re)started. Nothing changed and everything
    /// active: `NIDO_RESULT=unchanged`.
    static func installScript(files: [(path: String, mode: String, base64: String)]) throws -> String {
        var lines = [
            "set -eu",
            "here=$(dirname \"$0\")",
            "ID=",
            ". /etc/os-release 2>/dev/null || true",
            "case \"${ID:-}\" in debian|ubuntu) ;; *) echo NIDO_RESULT=unsupported; exit 0 ;; esac",
            "changed=0",
            "units_changed=0",
        ]
        var units: [String] = []
        for (index, file) in files.enumerated() {
            guard isSafePath(file.path) else { throw GuestToolsInstallError.invalidPayload(file.path) }
            guard file.mode.count == 4, file.mode.allSatisfy({ ("0"..."7").contains($0) }) else {
                throw GuestToolsInstallError.invalidPayload(file.mode)
            }
            let shortMode = String(file.mode.drop(while: { $0 == "0" }))
            let isUnit = file.path.hasPrefix("/etc/systemd/system/") && file.path.hasSuffix(".service")
            if isUnit { units.append(String(file.path.split(separator: "/").last!)) }
            lines += [
                "src=\"$here/files/\(index)\"; dest='\(file.path)'",
                "if [ ! -f \"$dest\" ] || ! cmp -s \"$src\" \"$dest\" || [ \"$(stat -c %a \"$dest\")\" != '\(shortMode)' ]; then",
                "  install -D -o root -g root -m \(file.mode) \"$src\" \"$dest\"; changed=1" + (isUnit ? "; units_changed=1" : ""),
                "fi",
            ]
        }
        lines += pruneLines(optRoot: optRoot, unitDir: unitDir)
        let manifest = GuestCommand.shellQuote(optRoot + "/MANIFEST")
        lines += [
            "if [ ! -f \(manifest) ] || ! cmp -s \"$here/MANIFEST\" \(manifest); then",
            "  install -D -o root -g root -m 0644 \"$here/MANIFEST\" \(manifest); fi",
        ]
        lines.append("if [ \"$units_changed\" = 1 ]; then systemctl daemon-reload; fi")
        for unit in units {
            lines += [
                "if [ \"$changed\" = 1 ]; then systemctl enable '\(unit)'; systemctl restart '\(unit)';",
                "elif ! systemctl is-enabled --quiet '\(unit)' || ! systemctl is-active --quiet '\(unit)'; then",
                "  systemctl enable --now '\(unit)'; changed=1; fi",
            ]
        }
        lines.append("if [ \"$changed\" = 1 ]; then echo NIDO_RESULT=installed; else echo NIDO_RESULT=unchanged; fi")
        return lines.joined(separator: "\n") + "\n"
    }

    /// Removes what the installed version's `MANIFEST` lists and the new one (`$here/MANIFEST`)
    /// does not: only regular files or links whose real folder is `optRoot` (or below) and
    /// `nido-*.service` units directly in `unitDir` (a unit is disabled first), never a path with
    /// `..` or through a link to another folder, whatever the old list says. Nothing at all without
    /// the new list. Sets `changed` (and `units_changed` for a unit). A guest without a `MANIFEST`
    /// (Guest Tools before 1.3.0) has nothing removed.
    static func pruneLines(optRoot: String, unitDir: String) -> [String] {
        [
            "opt_root=\(GuestCommand.shellQuote(optRoot)); unit_dir=\(GuestCommand.shellQuote(unitDir))",
            "if [ -s \"$here/MANIFEST\" ] && [ -f \"$opt_root/MANIFEST\" ]; then",
            "  opt_real=$(readlink -f -- \"$opt_root\"); unit_real=$(readlink -f -- \"$unit_dir\")",
            "  while IFS= read -r p || [ -n \"$p\" ]; do",
            "    case \"$p\" in *..*) continue ;; esac",
            "    case \"$p\" in \"$opt_root\"/*|\"$unit_dir\"/nido-*.service) ;; *) continue ;; esac",
            "    if grep -qxF -- \"$p\" \"$here/MANIFEST\"; then continue; fi",
            "    if [ ! -f \"$p\" ] && [ ! -L \"$p\" ]; then continue; fi",
            "    d=$(readlink -f -- \"$(dirname -- \"$p\")\") || continue",
            "    case \"$p\" in",
            "      \"$unit_dir\"/*) [ \"$d\" = \"$unit_real\" ] || continue",
            "        systemctl disable --now \"${p##*/}\" 2>/dev/null || true; units_changed=1 ;;",
            "      *) case \"$d\" in \"$opt_real\"|\"$opt_real\"/*) ;; *) continue ;; esac ;;",
            "    esac",
            "    rm -f -- \"$p\"; changed=1",
            "  done < \"$opt_root/MANIFEST\"",
            "fi",
        ]
    }

    static func archive(files: [(path: String, mode: String, base64: String)]) throws -> Data {
        var tar = TarWriter()
        try tar.add(name: "install.sh", mode: 0o644, content: Data(installScript(files: files).utf8))
        try tar.add(name: "MANIFEST", mode: 0o644, content: Data(files.map { $0.path + "\n" }.joined().utf8))
        for (index, file) in files.enumerated() {
            guard let content = Data(base64Encoded: file.base64) else {
                throw GuestToolsInstallError.invalidPayload(file.path)
            }
            try tar.add(name: "files/\(index)", mode: 0o600, content: content)
        }
        return tar.finish()
    }
}

/// A ustar writer: regular files only, owner root, time 0, flat names under 100 bytes.
struct TarWriter {
    private var data = Data()

    mutating func add(name: String, mode: Int, content: Data) throws {
        var header = [UInt8](repeating: 0, count: 512)
        func put(_ text: String, at offset: Int, length: Int) {
            for (i, byte) in text.utf8.prefix(length).enumerated() { header[offset + i] = byte }
        }
        func octal(_ value: Int, digits: Int) -> String {
            let s = String(value, radix: 8)
            return String(repeating: "0", count: max(0, digits - s.count)) + s
        }
        guard name.utf8.count < 100 else { throw GuestToolsInstallError.invalidPayload(name) }
        put(name, at: 0, length: 100)
        put(octal(mode, digits: 7), at: 100, length: 7)
        put(octal(0, digits: 7), at: 108, length: 7)
        put(octal(0, digits: 7), at: 116, length: 7)
        put(octal(content.count, digits: 11), at: 124, length: 11)
        put(octal(0, digits: 11), at: 136, length: 11)
        put("        ", at: 148, length: 8)
        header[156] = UInt8(ascii: "0")
        put("ustar", at: 257, length: 5)
        put("00", at: 263, length: 2)
        let checksum = header.reduce(0) { $0 + Int($1) }
        put(octal(checksum, digits: 6), at: 148, length: 6)
        header[154] = 0
        header[155] = UInt8(ascii: " ")
        data.append(contentsOf: header)
        data.append(content)
        let padding = (512 - content.count % 512) % 512
        data.append(Data(count: padding))
    }

    func finish() -> Data { data + Data(count: 1024) }
}

/// A gzip member (RFC 1952) around a raw deflate stream of the Compression framework
/// (`COMPRESSION_ZLIB` is raw deflate, RFC 1951): no name, time 0, OS unknown.
enum GzipWriter {
    static func compress(_ data: Data) throws -> Data {
        let capacity = data.count + data.count / 10 + 1024
        var deflated = Data(count: capacity)
        let written = deflated.withUnsafeMutableBytes { out in
            data.withUnsafeBytes { input in
                compression_encode_buffer(
                    out.bindMemory(to: UInt8.self).baseAddress!, capacity,
                    input.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { throw GuestToolsInstallError.invalidPayload(L10n.string("compression")) }
        var gz = Data([0x1F, 0x8B, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF])
        gz.append(deflated.prefix(written))
        for value in [crc32(data), UInt32(truncatingIfNeeded: data.count)] {
            withUnsafeBytes(of: value.littleEndian) { gz.append(contentsOf: $0) }
        }
        return gz
    }

    private static let table: [UInt32] = (0..<256).map { n in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }
}
