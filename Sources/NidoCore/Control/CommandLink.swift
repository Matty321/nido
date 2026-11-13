// SPDX-License-Identifier: Apache-2.0
import Foundation

/// The `nido` command as a symlink to the CLI inside the app (`Contents/Helpers/nido`).
/// Nothing here touches a link or file that is not Nido's own, except a regular file the caller
/// was explicitly allowed to replace.
public enum CommandLink {
    public enum Status: Equatable, Sendable {
        case missing
        case linkedToNido
        /// A symlink to something else (its destination).
        case otherLink(String)
        case regularFile
        /// A directory or another non-regular item: never touched, whatever the consent.
        case otherItem
    }

    public static var defaultLink: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/nido")
    }

    /// The old per-user gvproxy copy, no longer needed now that the CLI finds the app's.
    public static var legacyGvproxy: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/libexec/nido/gvproxy")
    }

    public static func status(link: URL, target: URL) -> Status {
        let fm = FileManager.default
        guard let destination = try? fm.destinationOfSymbolicLink(atPath: link.path) else {
            guard let type = (try? fm.attributesOfItem(atPath: link.path))?[.type] as? FileAttributeType else {
                return .missing
            }
            return type == .typeRegular ? .regularFile : .otherItem
        }
        return destination == target.path ? .linkedToNido : .otherLink(destination)
    }

    public static func install(link: URL, target: URL, replacingRegularFile: Bool) throws(NidoError) {
        guard isUsableTarget(target) else { throw .commandTargetUnusable }
        let fm = FileManager.default
        switch status(link: link, target: target) {
        case .linkedToNido: return
        case .otherLink: throw .commandLinkForeign(link.path)
        case .otherItem: throw .commandLinkNotAFile(link.path)
        case .regularFile:
            guard replacingRegularFile else { throw .commandLinkIsFile(link.path) }
            do { try fm.removeItem(at: link) } catch { throw .commandLinkFailed(error.localizedDescription) }
        case .missing: break
        }
        do {
            try fm.createDirectory(
                at: link.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o755])
            try fm.createSymbolicLink(atPath: link.path, withDestinationPath: target.path)
        } catch {
            throw .commandLinkFailed(error.localizedDescription)
        }
    }

    public static func remove(link: URL, target: URL) throws(NidoError) {
        switch status(link: link, target: target) {
        case .linkedToNido:
            do { try FileManager.default.removeItem(at: link) } catch {
                throw .commandLinkFailed(error.localizedDescription)
            }
        case .otherLink: throw .commandLinkForeign(link.path)
        case .regularFile: throw .commandLinkIsFile(link.path)
        case .otherItem: throw .commandLinkNotAFile(link.path)
        case .missing: return
        }
    }

    /// False for an app on a disk image or run translocated by Gatekeeper: the link would vanish.
    public static func isUsableTarget(_ target: URL) -> Bool {
        let path = target.standardizedFileURL.path
        return !path.hasPrefix("/Volumes/") && !path.contains("AppTranslocation")
    }

    public static func directoryIsInPATH(_ dir: URL, path: String) -> Bool {
        func normalized(_ p: String) -> String {
            var p = p
            while p.count > 1, p.hasSuffix("/") { p.removeLast() }
            return p
        }
        let wanted = normalized(dir.path)
        return path.split(separator: ":").contains { normalized(String($0)) == wanted }
    }
}
