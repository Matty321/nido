// SPDX-License-Identifier: Apache-2.0
import Foundation

/// A file Nido puts into a Linux guest: through cloud-init `write_files` for new VMs, through
/// `GuestSetup.legacyCommand` for VMs created by an older Nido.
public struct GuestFile: Sendable, Equatable {
    public let path: String
    public let content: String

    public init(path: String, content: String) {
        self.path = path
        self.content = content
    }
}

/// Guest-side setup of the VirtioFS devices (shared folders, Rosetta).
///
/// A device is mounted by a oneshot systemd unit, never by fstab: when the VM is started without
/// the device (no shared folders, Rosetta off) a missing VirtioFS tag fails its mount unit even
/// with `nofail`, leaving cloud-init in `error` and the system `degraded` at every boot. The mount
/// is the unit's `ExecCondition` instead, so a missing tag skips the unit (no failed unit).
public enum GuestSetup {
    /// `ExecCondition` line: creates the mount point and mounts `tag` there unless something is
    /// mounted already. A missing tag makes `mount` fail, which skips the unit.
    static func mountCondition(tag: String, mountPoint: String, options: String) -> String {
        "ExecCondition=/bin/sh -c \"mkdir -p \(mountPoint) && { mountpoint -q \(mountPoint) || "
            + "mount -t virtiofs -o \(options) \(tag) \(mountPoint); }\""
    }

    /// cloud-init `write_files` entries (0644), each content as a YAML literal block.
    static func writeFiles(_ files: [GuestFile]) -> String {
        files.map { file in
            let body = file.content.split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.isEmpty ? "" : "      \($0)" }.joined(separator: "\n")
            return "  - path: \(file.path)\n    permissions: \"0644\"\n    content: |\n\(body)"
        }.joined(separator: "\n")
    }

    /// The one-time command for a guest created by an older Nido: one single-quoted `sh -c`
    /// script that writes `files` (printf "%s", so backslashes stay text), then enables and
    /// starts `unitName`. Idempotent: running it again rewrites the same files.
    ///
    /// The contents are Nido constants. Inside the double-quoted printf arguments only `"` is
    /// escaped, so they must not contain `'`, `$`, a backtick, or a backslash before anything
    /// but `x` (the binfmt escapes); a precondition checks it.
    static func legacyCommand(files: [GuestFile], unitName: String) -> String {
        var parents: [String] = []
        for file in files {
            let parent = (file.path as NSString).deletingLastPathComponent
            if !parents.contains(parent) { parents.append(parent) }
        }
        var steps = ["mkdir -p \(parents.joined(separator: " "))"]
        for file in files {
            precondition(isSafeForDoubleQuotes(file.content), "guest file not safe for sh: \(file.path)")
            let lines = file.content.split(separator: "\n", omittingEmptySubsequences: false)
                .map { "\"\($0.replacingOccurrences(of: "\"", with: "\\\""))\"" }.joined(separator: " ")
            steps.append("printf \"%s\\n\" \(lines) > \(file.path)")
        }
        steps += ["systemctl daemon-reload", "systemctl enable --now \(unitName)"]
        return "sudo sh -c '\(steps.joined(separator: " && "))'"
    }

    private static func isSafeForDoubleQuotes(_ text: String) -> Bool {
        let chars = Array(text)
        for (i, c) in chars.enumerated() {
            if c == "'" || c == "$" || c == "`" { return false }
            if c == "\\", i + 1 >= chars.count || chars[i + 1] != "x" { return false }
        }
        return true
    }
}
