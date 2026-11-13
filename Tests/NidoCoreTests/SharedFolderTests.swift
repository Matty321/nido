// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import NidoCore

/// A fake home (with `Library`), a VM root and an image cache, all in a temp directory.
private struct ShareFixture {
    let tmp: URL
    let home: URL
    let paths: NidoPaths
    let cache: URL

    init() throws {
        let fm = FileManager.default
        // Not in the temp directory: /private (the real /tmp and /var) cannot be shared.
        tmp = URL(fileURLWithPath: "/Users/Shared", isDirectory: true)
            .appendingPathComponent("nido-tests-share-\(UUID().uuidString)", isDirectory: true)
        home = tmp.appendingPathComponent("home", isDirectory: true)
        paths = NidoPaths(root: tmp.appendingPathComponent("VMs", isDirectory: true))
        cache = tmp.appendingPathComponent("cache/images", isDirectory: true)
        for dir in [home.appendingPathComponent("Library/Preferences"), home.appendingPathComponent("Projects"),
                    paths.root.appendingPathComponent("vm.nidovm"), cache.appendingPathComponent("sub")] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    func validate(_ path: String) throws(NidoError) -> URL {
        try SharedFolder.validate(hostPath: path, paths: paths, imageCache: cache, home: home)
    }

    func link(_ name: String, to target: String) throws -> String {
        let url = home.appendingPathComponent("Projects/\(name)")
        try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: target)
        return url.path
    }

    func cleanup() { try? FileManager.default.removeItem(at: tmp) }
}

@Suite(.italian) struct SharedFolderTests {
    @Test func rejectsDangerousHostPaths() throws {
        let f = try ShareFixture()
        defer { f.cleanup() }
        var dangerous = [
            "/",
            f.home.path,
            f.home.path + "/",
            f.home.appendingPathComponent("Library").path,
            f.home.appendingPathComponent("Library/Preferences").path,
            f.home.appendingPathComponent("Projects/../Library").path,
            f.paths.root.path,
            f.paths.root.appendingPathComponent("vm.nidovm").path,
            f.cache.path,
            f.cache.appendingPathComponent("sub").path,
            f.tmp.path,  // contains the home, the VMs and the cache
            "/Users/Shared/../Shared/..",  // /Users: contains the real home
            "relative/path",
            "Projects",
            "",
            f.home.appendingPathComponent("missing").path,
        ]
        dangerous.append(try f.link("root-link", to: "/"))
        dangerous.append(try f.link("library-link", to: f.home.appendingPathComponent("Library").path))
        dangerous.append(try f.link("vms-link", to: f.paths.root.path))
        let file = f.home.appendingPathComponent("Projects/file.txt")
        try Data("x".utf8).write(to: file)
        dangerous.append(file.path)
        for path in dangerous {
            #expect(throws: NidoError.self, "\(path)") { _ = try f.validate(path) }
        }
    }

    /// Spellings `realpath` keeps (firmlinks of the data volume, `/.nofollow`): the real home of
    /// this Mac, its Library and the whole data volume must be refused through every one of them.
    @Test func rejectsFirmlinkAndAliasSpellings() throws {
        let f = try ShareFixture()
        defer { f.cleanup() }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        func validateReal(_ path: String) throws(NidoError) -> URL {
            try SharedFolder.validate(hostPath: path, paths: f.paths, imageCache: f.cache)
        }
        var aliases = [
            "/System/Volumes/Data",
            "/System/Volumes/Data/Users",
            "/System/Volumes/Data\(home)",
            "/System/Volumes/Data\(home)/Library",
            "/System/Volumes/Data\(home)/Library/Preferences",
            "/System/Volumes/Preboot",
            "/System/Volumes",
            "/.nofollow\(home)",
            "/.nofollow\(home)/Library",
            "/.resolve/1/2",
            "/.vol/1/2",
            "/Users",
            "/Users/",
            home,
            home + "/Library",
        ]
        aliases.append(try f.link("firm-home", to: "/System/Volumes/Data\(home)"))
        aliases.append(try f.link("firm-library", to: "/System/Volumes/Data\(home)/Library"))
        aliases.append(try f.link("nofollow-home", to: "/.nofollow\(home)"))
        aliases.append(try f.link("firm-data", to: "/System/Volumes/Data"))
        for path in aliases {
            #expect(throws: NidoError.self, "\(path)") { _ = try validateReal(path) }
        }
    }

    /// The firmlink spelling of an allowed folder is accepted and stored in its short form.
    @Test func firmlinkSpellingOfAnAllowedFolderIsFolded() throws {
        let f = try ShareFixture()
        defer { f.cleanup() }
        let short = realPath(f.home.appendingPathComponent("Projects"))
        let url = try f.validate("/System/Volumes/Data" + short)
        #expect(url.path == short)
    }

    /// R-M3A-8: system areas are refused by prefix (the identity walk from the home never passes
    /// through /System, although the data volume lives under /System/Volumes/Data).
    @Test func rejectsSystemAreas() throws {
        let f = try ShareFixture()
        defer { f.cleanup() }
        let refused = ["/System", "/System/Library", "/System/Volumes/Data/System", "/private", "/private/tmp",
                       "/tmp", "/var", "/etc", "/private/var/folders", NSTemporaryDirectory(), "/dev", "/dev/fd",
                       "/Volumes/Macintosh HD/System"]
        for path in refused where FileManager.default.fileExists(atPath: path) {
            #expect(throws: NidoError.self, "\(path)") { _ = try f.validate(path) }
        }
        #expect(throws: NidoError.self) { _ = try f.validate(try f.link("system-link", to: "/System")) }
        #expect(throws: NidoError.self) { _ = try f.validate(try f.link("tmp-link", to: "/tmp")) }
    }

    @Test func applicationsAndVolumesFoldersStayAllowed() throws {
        let f = try ShareFixture()
        defer { f.cleanup() }
        let allowed = ["/Applications/Utilities", "/Volumes/.timemachine", "/Library/Fonts"]
            .filter { FileManager.default.fileExists(atPath: $0) }
        #expect(!allowed.isEmpty)
        for path in allowed {
            #expect(try f.validate(path).path == path)
        }
    }

    /// Fail closed: when the identity walk cannot be computed (for the folder or a protected
    /// one), the folder is refused, not let through.
    @Test func ancestryFailureRefuses() throws {
        let f = try ShareFixture()
        defer { f.cleanup() }
        let projects = f.home.appendingPathComponent("Projects").path
        func check(_ ancestry: (String) -> [SharedFolder.NodeID]?) throws(NidoError) -> URL {
            try SharedFolder.validate(hostPath: projects, paths: f.paths, imageCache: f.cache, home: f.home,
                                      alsoProtected: [], ancestry: ancestry)
        }
        _ = try check(SharedFolder.ancestry(of:))  // allowed with the real walk
        #expect(throws: NidoError.sharedFolderRefused("\(projects): impossibile verificare la cartella")) {
            _ = try check { _ in nil }
        }
        let cachePath = f.cache.standardizedFileURL.path
        #expect(throws: NidoError.sharedFolderRefused("\(projects): impossibile verificare la cartella")) {
            _ = try check { $0 == cachePath ? nil : SharedFolder.ancestry(of: $0) }
        }
    }

    /// A protected folder that does not exist yet is checked through its nearest existing parent.
    @Test func missingProtectedFolderStillProtects() throws {
        let f = try ShareFixture()
        defer { f.cleanup() }
        let future = f.tmp.appendingPathComponent("parent/not-yet/VMs")
        try FileManager.default.createDirectory(at: f.tmp.appendingPathComponent("parent"), withIntermediateDirectories: true)
        #expect(throws: NidoError.self) {
            _ = try SharedFolder.validate(hostPath: f.tmp.appendingPathComponent("parent").path,
                                          paths: NidoPaths(root: future), imageCache: f.cache, home: f.home)
        }
    }

    @Test func realpathFailuresSayWhy() throws {
        let f = try ShareFixture()
        defer { f.cleanup() }
        let locked = f.home.appendingPathComponent("Projects/locked", isDirectory: true)
        try FileManager.default.createDirectory(at: locked.appendingPathComponent("inner"), withIntermediateDirectories: true)
        #expect(chmod(locked.path, 0) == 0)
        defer { _ = chmod(locked.path, 0o755) }
        let inner = locked.appendingPathComponent("inner").path
        #expect(throws: NidoError.sharedFolderRefused("\(inner): permesso negato su una cartella del percorso")) {
            _ = try f.validate(inner)
        }
        let file = f.home.appendingPathComponent("Projects/file.txt")
        try Data("x".utf8).write(to: file)
        #expect(throws: NidoError.sharedFolderRefused("\(file.path)/x: un elemento del percorso non è una cartella")) {
            _ = try f.validate(file.path + "/x")
        }
        let loop = f.home.appendingPathComponent("Projects/loop").path
        try FileManager.default.createSymbolicLink(atPath: loop, withDestinationPath: loop)
        #expect(throws: NidoError.sharedFolderRefused("\(loop): troppi link simbolici")) { _ = try f.validate(loop) }
    }

    @Test func missingFolderIsItsOwnError() throws {
        let f = try ShareFixture()
        defer { f.cleanup() }
        let path = f.home.appendingPathComponent("missing").path
        #expect(throws: NidoError.sharedFolderMissing(path)) { _ = try f.validate(path) }
    }

    @Test func volumeRootsAreRefused() throws {
        let f = try ShareFixture()
        defer { f.cleanup() }
        // Every mounted volume of this Mac (`/Volumes/X` mount points, `Macintosh HD` → `/`).
        let mounted = (FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil) ?? [])
            .map(\.path)
        for path in ["/", "/System/Volumes/Data", "/Volumes/Macintosh HD"] + mounted {
            #expect(throws: NidoError.self, "\(path)") { _ = try f.validate(path) }
        }
    }

    @Test func libraryCheckIgnoresCase() throws {
        let f = try ShareFixture()
        defer { f.cleanup() }
        #expect(throws: NidoError.self) {
            _ = try f.validate(f.home.appendingPathComponent("library/preferences").path)
        }
    }

    @Test func acceptsAProjectFolderResolved() throws {
        let f = try ShareFixture()
        defer { f.cleanup() }
        let url = try f.validate(f.home.appendingPathComponent("Projects/./").path)
        #expect(url.path.hasSuffix("/home/Projects"))
        #expect(!url.path.contains("/./"))
        // Resolved with realpath.
        #expect(url.path == realPath(f.home.appendingPathComponent("Projects")))
        let link = try f.link("alias", to: f.home.appendingPathComponent("Projects").path)
        #expect(try f.validate(link).path == url.path)
    }

    @Test(arguments: ["progetti", "a", "Dev.data_1-x", String(repeating: "a", count: 63)])
    func acceptsNames(_ name: String) throws {
        try SharedFolder.validateName(name)
    }

    @Test(arguments: ["", ".hidden", "-x", "a/b", "..", "con spazio", "è", String(repeating: "a", count: 64)])
    func rejectsNames(_ name: String) {
        #expect(throws: NidoError.invalidShareName(name)) { try SharedFolder.validateName(name) }
    }

    @Test func namesAreUniqueIgnoringCase() throws {
        let one = SharedFolder(name: "Progetti", hostPath: "/a", readOnly: true)
        let two = SharedFolder(name: "progetti", hostPath: "/b", readOnly: true)
        #expect(throws: NidoError.shareNameTaken("progetti")) {
            _ = try SharedFolder.adding(two, to: [one])
        }
        let three = SharedFolder(name: "altro", hostPath: "/b", readOnly: false)
        #expect(try SharedFolder.adding(three, to: [one]) == [one, three])
    }

    @Test func defaultNameComesFromTheFolder() {
        #expect(SharedFolder.defaultName(for: URL(fileURLWithPath: "/Users/a/Progetti"), taken: []) == "Progetti")
        #expect(SharedFolder.defaultName(for: URL(fileURLWithPath: "/Users/a/Il mio lavoro"), taken: [])
            == "Il-mio-lavoro")
        #expect(SharedFolder.defaultName(for: URL(fileURLWithPath: "/Users/a/.config"), taken: []) == "config")
        #expect(SharedFolder.defaultName(for: URL(fileURLWithPath: "/Users/a/èèè"), taken: []) == "cartella")
        #expect(SharedFolder.defaultName(for: URL(fileURLWithPath: "/Users/a/Progetti"), taken: ["progetti"])
            == "Progetti-2")
    }

    @Test func removingAndReadOnly() throws {
        let one = SharedFolder(name: "Progetti", hostPath: "/a", readOnly: true)
        #expect(try SharedFolder.removing("PROGETTI", from: [one]).isEmpty)
        #expect(throws: NidoError.shareNotFound("x")) { _ = try SharedFolder.removing("x", from: [one]) }
        #expect(try SharedFolder.settingReadOnly(false, for: "progetti", in: [one]).first?.readOnly == false)
    }
}
