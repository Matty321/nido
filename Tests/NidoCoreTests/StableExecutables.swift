// SPDX-License-Identifier: Apache-2.0
import CryptoKit
import Foundation

/// Executables the tests run, made once in a fixed place under `$TMPDIR/nido-test-bin` and from
/// then on only reused: never signed again, renamed over or deleted.
///
/// Gatekeeper (`syspolicyd`) scans every new executable that starts. Copies of `/bin/sleep` (a
/// universal binary) made, run and deleted a moment later, and a 27 MB `gvproxy` signed again and
/// renamed over the old one at every run, made it crash while reading them
/// (`EXC_BAD_ACCESS` in `Security::Universal::architecture`), dozens of times a day; with
/// `syspolicyd` down, `tccd` and then WindowServer stalled until the watchdog restarted the
/// session (seen on 2026-11-03).
enum StableExecutables {
    /// A process named `gvproxy` that is not one: `/bin/sleep` thinned to arm64e (not universal)
    /// and signed ad hoc (a platform binary copied elsewhere does not run). Takes the seconds to
    /// sleep as its argument.
    static let fakeGvproxy: Result<URL, StableExecutableError> = make(directory: "sleep-arm64e", name: "gvproxy") {
        staging in
        try run("/usr/bin/lipo", ["/bin/sleep", "-thin", "arm64e", "-output", staging.path])
        try run("/usr/bin/codesign", ["--force", "--sign", "-", staging.path])
    }

    /// `source` signed ad hoc with `identifier`, once per content of `source`: a new pinned
    /// version gets a directory of its own, an unchanged one is reused as it is.
    static func signedCopy(of source: URL, identifier: String) -> Result<URL, StableExecutableError> {
        guard let data = try? Data(contentsOf: source, options: .alwaysMapped) else {
            return .failure(StableExecutableError("\(source.path) non leggibile"))
        }
        let digest = SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
        return make(directory: "\(source.lastPathComponent)-\(digest)", name: source.lastPathComponent) { staging in
            try FileManager.default.copyItem(at: source, to: staging)
            try run("/usr/bin/codesign", ["--force", "--sign", "-", "--identifier", identifier, staging.path])
        }
    }

    /// `<root>/<directory>/<name>`, built by `build` into a staging file the first time and then
    /// hard-linked into place: a link never replaces a copy another test process made meanwhile,
    /// and dropping the staging name leaves the file itself untouched.
    private static func make(
        directory: String, name: String, build: (URL) throws -> Void
    ) -> Result<URL, StableExecutableError> {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("nido-test-bin", isDirectory: true)
            .appendingPathComponent(directory, isDirectory: true)
        let final = folder.appendingPathComponent(name)
        if FileManager.default.isExecutableFile(atPath: final.path) { return .success(final) }
        do {
            try FileManager.default.createDirectory(
                at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let staging = folder.appendingPathComponent(".\(name)-\(UUID().uuidString.prefix(8))")
            defer { unlink(staging.path) }
            try build(staging)
            guard link(staging.path, final.path) == 0 || errno == EEXIST else {
                throw StableExecutableError("link di \(final.path): errno \(errno)")
            }
            return .success(final)
        } catch let error as StableExecutableError {
            return .failure(error)
        } catch {
            return .failure(StableExecutableError("\(final.path): \(error)"))
        }
    }

    private static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw StableExecutableError("\(tool) \(arguments.joined(separator: " ")): codice \(process.terminationStatus)")
        }
    }
}

struct StableExecutableError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
