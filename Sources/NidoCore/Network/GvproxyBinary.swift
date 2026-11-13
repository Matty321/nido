// SPDX-License-Identifier: Apache-2.0
import Foundation
import Security

/// Finds the pinned `gvproxy` binary that Nido ships and checks its code signature before it is started.
/// The search is limited to three fixed places and never looks at `PATH`.
public enum GvproxyBinary {
    /// Code signing identifier Nido gives `gvproxy` when it re-signs it (see `scripts/build-app.sh`).
    public static let signingIdentifier = "io.gitlab.pichierri.Nido.gvproxy"

    /// Where `gvproxy` may live, in order of preference: inside the app, next to a debug build of the CLI,
    /// and in the per-user install directory used by `scripts/install.sh`.
    public static func candidates(executable: URL, home: URL) -> [URL] {
        // The CLI is usually started through ~/.local/bin/nido, a link into the app: follow every link first.
        let directory = executable.resolvingSymlinksInPath().deletingLastPathComponent()
        return [
            directory.appendingPathComponent("../Helpers/gvproxy").standardized,
            directory.appendingPathComponent("libexec/gvproxy"),
            home.appendingPathComponent(".local/libexec/nido/gvproxy"),
        ]
    }

    /// Returns the first candidate that is a regular file (a symbolic link is skipped) and passes `verify`.
    /// Throws `NidoError.controlledNetworkUnavailable` when none exists or the binary is not the expected one.
    public static func locate(
        executable: URL = Bundle.main.executableURL!,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        verify: (URL) -> Bool = { GvproxyBinary.hasValidSignature($0) }
    ) throws -> URL {
        guard let found = candidates(executable: executable, home: home).first(where: isRegularFile) else {
            throw NidoError.controlledNetworkUnavailable(L10n.string("gvproxy not found"))
        }
        guard verify(found) else {
            throw NidoError.controlledNetworkUnavailable(L10n.string("gvproxy isn’t the expected program"))
        }
        return found
    }

    /// The code requirement `gvproxy` must satisfy. Under a Developer ID signature it is pinned to Nido's
    /// Team ID, so a binary signed by anyone else (or ad hoc) is rejected; an ad hoc build only checks the identifier.
    public static func requirement(teamID: String?) -> String {
        let identifier = "identifier \"\(signingIdentifier)\""
        guard let teamID else { return identifier }
        return "anchor apple generic and \(identifier) and certificate leaf[subject.OU] = \"\(teamID)\""
    }

    /// True when the file at `url` has a valid code signature that satisfies `requirement(teamID:)`.
    public static func hasValidSignature(_ url: URL, teamID: String? = CodeSigningIdentity.currentTeamID()) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return false }
        var requirement: SecRequirement?
        let text = GvproxyBinary.requirement(teamID: teamID) as CFString
        guard SecRequirementCreateWithString(text, [], &requirement) == errSecSuccess, let requirement else {
            return false
        }
        return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), requirement)
            == errSecSuccess
    }

    /// `lstat` does not follow links, so a symbolic link never counts as a regular file.
    private static func isRegularFile(_ url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFREG
    }
}
