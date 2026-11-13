// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing

@testable import NidoCore

@Suite("CommandLink")
struct CommandLinkTests {
    private func makeDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("nido-link-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeTarget(in dir: URL) throws -> URL {
        let target = dir.appendingPathComponent("Nido.app/Contents/Helpers/nido")
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: target)
        return target
    }

    @Test func installsLinkWhenMissing() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = try makeTarget(in: dir)
        let link = dir.appendingPathComponent("home/.local/bin/nido")
        #expect(CommandLink.status(link: link, target: target) == .missing)
        try CommandLink.install(link: link, target: target, replacingRegularFile: false)
        #expect(CommandLink.status(link: link, target: target) == .linkedToNido)
        let mode = try FileManager.default.attributesOfItem(atPath: link.deletingLastPathComponent().path)[.posixPermissions] as? Int
        #expect(mode == 0o755)
        // Installing again over its own link is a no-op, not an error.
        try CommandLink.install(link: link, target: target, replacingRegularFile: false)
    }

    @Test func refusesRegularFileWithoutConsent() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = try makeTarget(in: dir)
        let link = dir.appendingPathComponent("nido")
        try Data("old".utf8).write(to: link)
        #expect(CommandLink.status(link: link, target: target) == .regularFile)
        #expect(throws: NidoError.self) {
            try CommandLink.install(link: link, target: target, replacingRegularFile: false)
        }
        #expect(CommandLink.status(link: link, target: target) == .regularFile)
    }

    @Test func replacesRegularFileWithConsent() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = try makeTarget(in: dir)
        let link = dir.appendingPathComponent("nido")
        try Data("old".utf8).write(to: link)
        try CommandLink.install(link: link, target: target, replacingRegularFile: true)
        #expect(CommandLink.status(link: link, target: target) == .linkedToNido)
    }

    @Test func neverReplacesForeignLink() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = try makeTarget(in: dir)
        let link = dir.appendingPathComponent("nido")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/usr/bin/true")
        #expect(CommandLink.status(link: link, target: target) == .otherLink("/usr/bin/true"))
        #expect(throws: NidoError.self) {
            try CommandLink.install(link: link, target: target, replacingRegularFile: true)
        }
        #expect(throws: NidoError.self) { try CommandLink.remove(link: link, target: target) }
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == "/usr/bin/true")
    }

    @Test func removeOnlyRemovesOwnLink() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = try makeTarget(in: dir)
        let link = dir.appendingPathComponent("nido")
        try CommandLink.install(link: link, target: target, replacingRegularFile: false)
        try CommandLink.remove(link: link, target: target)
        #expect(CommandLink.status(link: link, target: target) == .missing)
        // A regular file is not ours either.
        try Data("old".utf8).write(to: link)
        #expect(throws: NidoError.self) { try CommandLink.remove(link: link, target: target) }
        #expect(FileManager.default.fileExists(atPath: link.path))
    }

    @Test func refusesTargetsOnVolumesOrTranslocated() throws {
        #expect(!CommandLink.isUsableTarget(URL(fileURLWithPath: "/Volumes/Nido/Nido.app/Contents/Helpers/nido")))
        #expect(!CommandLink.isUsableTarget(
            URL(fileURLWithPath: "/private/var/folders/x/AppTranslocation/y/d/Nido.app/Contents/Helpers/nido")))
        #expect(CommandLink.isUsableTarget(URL(fileURLWithPath: "/Applications/Nido.app/Contents/Helpers/nido")))
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let link = dir.appendingPathComponent("nido")
        #expect(throws: NidoError.self) {
            try CommandLink.install(
                link: link, target: URL(fileURLWithPath: "/Volumes/Nido/Nido.app/Contents/Helpers/nido"),
                replacingRegularFile: false)
        }
    }

    @Test func neverRemovesADirectory() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = try makeTarget(in: dir)
        let link = dir.appendingPathComponent("nido")
        try FileManager.default.createDirectory(at: link, withIntermediateDirectories: true)
        let inner = link.appendingPathComponent("keep.txt")
        try Data("x".utf8).write(to: inner)
        #expect(CommandLink.status(link: link, target: target) != .regularFile)
        #expect(throws: NidoError.self) {
            try CommandLink.install(link: link, target: target, replacingRegularFile: true)
        }
        #expect(throws: NidoError.self) { try CommandLink.remove(link: link, target: target) }
        #expect(FileManager.default.fileExists(atPath: inner.path))
    }

    @Test func pathCheck() {
        let dir = URL(fileURLWithPath: "/Users/u/.local/bin", isDirectory: true)
        #expect(CommandLink.directoryIsInPATH(dir, path: "/usr/bin:/Users/u/.local/bin"))
        #expect(!CommandLink.directoryIsInPATH(dir, path: "/usr/bin"))
        #expect(CommandLink.directoryIsInPATH(dir, path: "/usr/bin:/Users/u/.local/bin/"))
    }
}
