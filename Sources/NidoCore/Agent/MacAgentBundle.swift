// SPDX-License-Identifier: Apache-2.0
import Foundation
import Security

/// Finds the signed `NidoAgent.app` that Nido ships (the helper `nido agent setup` copies into a macOS guest)
/// and checks its code signature. Like `GvproxyBinary`, the search is limited to three fixed places and
/// never looks at `PATH`; unlike it, the target is a directory bundle.
public enum MacAgentBundle {
    /// Code signing identifier Nido gives the helper (see `scripts/build-agent.sh`).
    public static let signingIdentifier = "io.gitlab.pichierri.Nido.Agent"

    /// Where the app may live, in order of preference: inside Nido.app, next to a debug build of the CLI,
    /// and in the per-user install directory.
    public static func candidates(executable: URL, home: URL) -> [URL] {
        // The CLI is usually started through ~/.local/bin/nido, a link into the app: follow every link first.
        let directory = executable.resolvingSymlinksInPath().deletingLastPathComponent()
        return [
            directory.appendingPathComponent("../Resources/NidoAgent.app").standardized,
            directory.appendingPathComponent("NidoAgent.app"),
            home.appendingPathComponent(".local/libexec/nido/NidoAgent.app"),
        ]
    }

    /// Returns the first candidate that is a real directory (a symbolic link is skipped) and passes `verify`.
    /// Throws `NidoError.macAgentUnavailable` when none does.
    public static func locate(
        executable: URL = Bundle.main.executableURL!,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        verify: (URL) -> Bool = { MacAgentBundle.hasValidSignature($0) }
    ) throws -> URL {
        guard let found = candidates(executable: executable, home: home).first(where: { isDirectory($0) && verify($0) })
        else {
            throw NidoError.macAgentUnavailable
        }
        return found
    }

    /// The code requirement the app must satisfy. Under a Developer ID signature it is pinned to Nido's
    /// Team ID; an ad hoc build only checks the identifier.
    public static func requirement(teamID: String?) -> String {
        let identifier = "identifier \"\(signingIdentifier)\""
        guard let teamID else { return identifier }
        return "anchor apple generic and \(identifier) and certificate leaf[subject.OU] = \"\(teamID)\""
    }

    /// True when the bundle at `url` has a valid code signature (sealed resources included) that satisfies
    /// `requirement(teamID:)`.
    public static func hasValidSignature(_ url: URL, teamID: String? = CodeSigningIdentity.currentTeamID()) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return false }
        var requirement: SecRequirement?
        let text = MacAgentBundle.requirement(teamID: teamID) as CFString
        guard SecRequirementCreateWithString(text, [], &requirement) == errSecSuccess, let requirement else {
            return false
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate)
        return SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess
    }

    /// The app's `CFBundleShortVersionString`.
    public static func bundledVersion(_ app: URL) throws -> String {
        let plist = app.appendingPathComponent("Contents/Info.plist")
        let data = try Data(contentsOf: plist)
        guard let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let version = info["CFBundleShortVersionString"] as? String else {
            throw NidoError.macAgentUnavailable
        }
        return version
    }

    /// `lstat` does not follow links, so a symbolic link never counts as a directory.
    private static func isDirectory(_ url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFDIR
    }
}
