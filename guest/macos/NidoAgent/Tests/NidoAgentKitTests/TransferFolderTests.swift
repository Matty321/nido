// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation
import Testing
@testable import NidoAgentKit

/// A fresh temporary directory, removed when the test ends; `root` is the transfer folder inside
/// it (not created: `TransferFolder` creates it on first use), `outside` a folder next to it.
private final class Sandbox {
    let base: URL
    var root: URL { base.appendingPathComponent("NidoTransfer") }
    var outside: URL { base.appendingPathComponent("outside") }

    init() throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("nido-transfer-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: base) }

    var folder: TransferFolder { TransferFolder(root: root) }

    func names(in url: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).sorted()
    }
}

private func code(_ body: () throws -> Void) -> AgentErrorCode? {
    do {
        try body()
        return nil
    } catch let error as TransferError {
        return error.code
    } catch {
        return .internalError
    }
}

// MARK: - Paths

@Test func validateRefuses() {
    let tooMany = Array(repeating: "a", count: 17).joined(separator: "/")
    let tooLong = String(repeating: "a", count: 1025)
    for path in ["", "/etc/passwd", "a/../b", "..", "./a", "a/.", "a//b", "a/", "a\u{0}b", tooMany, tooLong] {
        #expect(code { _ = try TransferFolder.validate(path) } == .badRequest, "\(path.debugDescription)")
    }
}

@Test func validateAccepts() throws {
    #expect(try TransferFolder.validate("dir/file.txt") == ["dir", "file.txt"])
    #expect(try TransferFolder.validate("file") == ["file"])
    #expect(try TransferFolder.validate(".hidden") == [".hidden"])
    let sixteen = Array(repeating: "a", count: 16).joined(separator: "/")
    #expect(try TransferFolder.validate(sixteen).count == 16)
    #expect(try TransferFolder.validate(String(repeating: "a", count: 255)).count == 1)
    #expect(code { _ = try TransferFolder.validate(String(repeating: "a", count: 256)) } == .badRequest)
    // Split on the `/` byte: a combining mark after it does not glue two components together.
    #expect(try TransferFolder.validate("a/\u{301}b") == ["a", "\u{301}b"])
    #expect(code { _ = try TransferFolder.validate("a/..\u{0}") } == .badRequest)
    #expect(code { _ = try TransferFolder.validate("../\u{301}") } == .badRequest)
}

// MARK: - Root

@Test func rootCreatedPrivateOnFirstUse() throws {
    let box = try Sandbox()
    #expect(!FileManager.default.fileExists(atPath: box.root.path))
    let listed = try box.folder.list(nil, limit: 500)
    #expect(listed.entries.isEmpty)
    #expect(listed.truncated == false)
    let attributes = try FileManager.default.attributesOfItem(atPath: box.root.path)
    #expect(attributes[.type] as? FileAttributeType == .typeDirectory)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
}

@Test func rootSymlinkRefused() throws {
    let box = try Sandbox()
    try FileManager.default.createDirectory(at: box.outside, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: box.root, withDestinationURL: box.outside)
    #expect(throws: TransferError.self) { try box.folder.write(Data("x".utf8), to: "a/b.txt") }
    #expect(throws: TransferError.self) { _ = try box.folder.read("b.txt", maxBytes: 100) }
    #expect(throws: TransferError.self) { _ = try box.folder.list(nil, limit: 500) }
    #expect(box.names(in: box.outside).isEmpty)
}

@Test func danglingRootSymlinkRefused() throws {
    let box = try Sandbox()
    try FileManager.default.createSymbolicLink(at: box.root, withDestinationURL: box.outside)
    #expect(throws: TransferError.self) { try box.folder.write(Data("x".utf8), to: "b.txt") }
    #expect(!FileManager.default.fileExists(atPath: box.outside.path))
}

@Test func rootThatIsAFileRefused() throws {
    let box = try Sandbox()
    try Data("not a folder".utf8).write(to: box.root)
    #expect(throws: TransferError.self) { try box.folder.write(Data("x".utf8), to: "b.txt") }
    #expect(try Data(contentsOf: box.root) == Data("not a folder".utf8))
}

// MARK: - Write

@Test func writeCreatesParentsAndReplacesAtomically() throws {
    let box = try Sandbox()
    let folder = box.folder
    try folder.write(Data("one".utf8), to: "a/b/c.txt")
    let target = box.root.appendingPathComponent("a/b/c.txt")
    #expect(try Data(contentsOf: target) == Data("one".utf8))
    let firstInode = try FileManager.default.attributesOfItem(atPath: target.path)[.systemFileNumber] as? NSNumber

    try folder.write(Data("two, longer".utf8), to: "a/b/c.txt")
    #expect(try Data(contentsOf: target) == Data("two, longer".utf8))
    // Replaced by a rename (a new file), not rewritten in place.
    let secondInode = try FileManager.default.attributesOfItem(atPath: target.path)[.systemFileNumber] as? NSNumber
    #expect(firstInode != secondInode)
    #expect(box.names(in: box.root.appendingPathComponent("a/b")) == ["c.txt"])
    #expect(try folder.read("a/b/c.txt", maxBytes: 100) == Data("two, longer".utf8))

    try folder.write(Data(), to: "empty")
    #expect(try folder.read("empty", maxBytes: 100) == Data())
}

@Test func writeLeavesNoTempOnFailure() throws {
    let box = try Sandbox()
    let folder = box.folder
    try FileManager.default.createDirectory(at: box.root.appendingPathComponent("dir/sub"), withIntermediateDirectories: true)
    // The target is a folder: the bytes go to a temporary file first, which must go away.
    #expect(code { try folder.write(Data("x".utf8), to: "dir/sub") } == .badRequest)
    #expect(box.names(in: box.root.appendingPathComponent("dir")) == ["sub"])
    #expect(box.names(in: box.root.appendingPathComponent("dir/sub")).isEmpty)
}

@Test func writeRefusesTooLarge() throws {
    let box = try Sandbox()
    let big = Data(count: AgentProtocol.maxTransferBytes + 1)
    #expect(code { try box.folder.write(big, to: "big.bin") } == .badRequest)
    #expect(box.names(in: box.root).isEmpty)
}

@Test func writeThroughFileInPathRefused() throws {
    let box = try Sandbox()
    try box.folder.write(Data("x".utf8), to: "file")
    #expect(code { try box.folder.write(Data("y".utf8), to: "file/inner") } == .badRequest)
}

@Test func writeKeepsAnExistingFilesPermissions() throws {
    let box = try Sandbox()
    try box.folder.write(Data("#!/bin/sh\n".utf8), to: "run.sh")
    let target = box.root.appendingPathComponent("run.sh")
    #expect((try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: target.path)
    try box.folder.write(Data("#!/bin/sh\necho hi\n".utf8), to: "run.sh")
    #expect((try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? NSNumber)?.intValue == 0o700)
}

// MARK: - Symlinks

@Test func symlinkFileNeverFollowed() throws {
    let box = try Sandbox()
    try FileManager.default.createDirectory(at: box.outside, withIntermediateDirectories: true)
    let secret = box.outside.appendingPathComponent("secret")
    try Data("secret".utf8).write(to: secret)
    _ = try box.folder.list(nil, limit: 500)
    let link = box.root.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: secret)

    #expect(code { _ = try box.folder.read("link", maxBytes: 100) } == .badRequest)
    #expect(throws: TransferError(.badRequest, "'link' is a symbolic link: Nido Agent never follows links")) {
        _ = try box.folder.read("link", maxBytes: 100)
    }
    #expect(code { try box.folder.write(Data("pwned".utf8), to: "link") } == .badRequest)
    #expect(try Data(contentsOf: secret) == Data("secret".utf8))
    // The link is still a link, and no temporary file is left next to it.
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == secret.path)
    #expect(box.names(in: box.root) == ["link"])
    // A link to a file that does not exist yet is not followed either.
    let dangling = box.root.appendingPathComponent("dangling")
    try FileManager.default.createSymbolicLink(at: dangling, withDestinationURL: box.outside.appendingPathComponent("new"))
    #expect(code { try box.folder.write(Data("pwned".utf8), to: "dangling") } == .badRequest)
    #expect(!FileManager.default.fileExists(atPath: box.outside.appendingPathComponent("new").path))
}

@Test func symlinkFolderNeverFollowed() throws {
    let box = try Sandbox()
    try FileManager.default.createDirectory(at: box.outside, withIntermediateDirectories: true)
    try Data("secret".utf8).write(to: box.outside.appendingPathComponent("secret"))
    _ = try box.folder.list(nil, limit: 500)
    try FileManager.default.createSymbolicLink(at: box.root.appendingPathComponent("dir"), withDestinationURL: box.outside)

    #expect(code { _ = try box.folder.read("dir/secret", maxBytes: 100) } == .badRequest)
    #expect(throws: TransferError(.badRequest, "'dir' is a symbolic link: Nido Agent never follows links")) {
        try box.folder.write(Data("pwned".utf8), to: "dir/new")
    }
    #expect(code { try box.folder.write(Data("pwned".utf8), to: "dir/new") } == .badRequest)
    #expect(code { try box.folder.write(Data("pwned".utf8), to: "dir/sub/new") } == .badRequest)
    #expect(code { _ = try box.folder.list("dir", limit: 500) } == .badRequest)
    #expect(box.names(in: box.outside) == ["secret"])
    #expect(try Data(contentsOf: box.outside.appendingPathComponent("secret")) == Data("secret".utf8))
}

// MARK: - Read

@Test func readRefusesFolderAndTooLarge() throws {
    let box = try Sandbox()
    try box.folder.write(Data(count: 1000), to: "dir/file.bin")
    #expect(code { _ = try box.folder.read("dir", maxBytes: 100) } == .badRequest)
    #expect(code { _ = try box.folder.read("dir/file.bin", maxBytes: 999) } == .badRequest)
    #expect(try box.folder.read("dir/file.bin", maxBytes: 1000).count == 1000)
    #expect(code { _ = try box.folder.read("dir/missing", maxBytes: 100) } == .badRequest)
    #expect(code { _ = try box.folder.read("../outside", maxBytes: 100) } == .badRequest)
}

/// The host recognises a file too large by its wording (`MCPServer`'s hint): the refusal is
/// `tooLargeMessage` exactly, and only it matches `isTooLargeMessage`.
@Test func tooLargeRefusalHasTheSharedWording() throws {
    let box = try Sandbox()
    try box.folder.write(Data(count: 1000), to: "dir/file.bin")
    #expect(throws: TransferError(.badRequest, TransferFolder.tooLargeMessage(path: "dir/file.bin", maxBytes: 999))) {
        _ = try box.folder.read("dir/file.bin", maxBytes: 999)
    }
    #expect(TransferFolder.tooLargeMessage(path: "a b", maxBytes: 5) == "'a b' is larger than 5 bytes")
    #expect(TransferFolder.isTooLargeMessage("'a b' is larger than 5 bytes", maxBytes: 5))
    #expect(!TransferFolder.isTooLargeMessage("'a b' is larger than 5 bytes", maxBytes: 6))
    do {
        _ = try box.folder.read("dir/missing", maxBytes: 5)
        Issue.record("a missing file was read")
    } catch let error as TransferError {
        #expect(!TransferFolder.isTooLargeMessage(error.message, maxBytes: 5))
    }
    // A path that holds the wording itself does not fake the refusal of another file.
    let tricky = "x' is larger than 5 bytes"
    do {
        _ = try box.folder.read(tricky, maxBytes: 5)
        Issue.record("a missing file was read")
    } catch let error as TransferError {
        #expect(!TransferFolder.isTooLargeMessage(error.message, maxBytes: 5))
    }
}

@Test func readRefusesAFifoWithoutBlocking() throws {
    let box = try Sandbox()
    _ = try box.folder.list(nil, limit: 500)
    #expect(mkfifo(box.root.appendingPathComponent("pipe").path, 0o600) == 0)
    #expect(code { _ = try box.folder.read("pipe", maxBytes: 100) } == .badRequest)
    #expect(code { try box.folder.write(Data("x".utf8), to: "pipe") } == .badRequest)
}

// MARK: - List

@Test func listNewestFirstAndTruncates() throws {
    let box = try Sandbox()
    let folder = box.folder
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    for i in 0..<600 {
        let name = String(format: "f%03d", i)
        try folder.write(Data(count: i), to: name)
        try FileManager.default.setAttributes([.modificationDate: start.addingTimeInterval(Double(i))],
                                              ofItemAtPath: box.root.appendingPathComponent(name).path)
    }
    let listed = try folder.list(nil, limit: 500)
    #expect(listed.entries.count == 500)
    #expect(listed.truncated)
    #expect(listed.entries.first?.name == "f599")
    #expect(listed.entries.first?.kind == "file")
    #expect(listed.entries.first?.size == 599)
    #expect(listed.entries.first?.modified == start.addingTimeInterval(599))
    #expect(listed.entries.last?.name == "f100")
    #expect(listed.entries.map(\.modified) == listed.entries.map(\.modified).sorted(by: >))

    let all = try folder.list(nil, limit: 600)
    #expect(all.entries.count == 600)
    #expect(all.truncated == false)
}

@Test func listHidesTempFilesAndWriteRemovesStaleOnes() throws {
    let box = try Sandbox()
    try box.folder.write(Data("x".utf8), to: "a.txt")
    let old = box.root.appendingPathComponent(".nido-transfer-OLD.tmp")
    let fresh = box.root.appendingPathComponent(".nido-transfer-FRESH.tmp")
    let other = box.root.appendingPathComponent(".keep-OLD.tmp")
    for url in [old, fresh, other] { #expect(FileManager.default.createFile(atPath: url.path, contents: Data("t".utf8))) }
    let longAgo = Date(timeIntervalSinceNow: -3600)
    try FileManager.default.setAttributes([.modificationDate: longAgo], ofItemAtPath: old.path)
    try FileManager.default.setAttributes([.modificationDate: longAgo], ofItemAtPath: other.path)

    // Not listed, and listing removes nothing.
    #expect(try box.folder.list(nil, limit: 500).entries.map(\.name).sorted() == [".keep-OLD.tmp", "a.txt"])
    #expect(FileManager.default.fileExists(atPath: old.path))

    // A write removes the old temp file only: not the fresh one, not other names.
    try box.folder.write(Data("y".utf8), to: "b.txt")
    #expect(box.names(in: box.root) == [".keep-OLD.tmp", ".nido-transfer-FRESH.tmp", "a.txt", "b.txt"])
}

@Test func writeDoesNotFollowAStaleTempLink() throws {
    let box = try Sandbox()
    try box.folder.write(Data("x".utf8), to: "a.txt")
    try FileManager.default.createDirectory(at: box.outside, withIntermediateDirectories: true)
    let target = box.outside.appendingPathComponent("keep.txt")
    #expect(FileManager.default.createFile(atPath: target.path, contents: Data("k".utf8)))
    let link = box.root.appendingPathComponent(".nido-transfer-LINK.tmp")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    try box.folder.write(Data("y".utf8), to: "b.txt")
    #expect(FileManager.default.fileExists(atPath: target.path))
    #expect(box.names(in: box.root).contains(".nido-transfer-LINK.tmp"))
}

@Test func listMarksFoldersAndSkipsSymlinks() throws {
    let box = try Sandbox()
    try box.folder.write(Data("x".utf8), to: "docs/a.txt")
    try box.folder.write(Data("yy".utf8), to: "b.txt")
    try FileManager.default.createDirectory(at: box.outside, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: box.root.appendingPathComponent("link"), withDestinationURL: box.outside)
    #expect(mkfifo(box.root.appendingPathComponent("pipe").path, 0o600) == 0)

    let top = try box.folder.list(nil, limit: 500).entries
    #expect(Set(top.map(\.name)) == ["docs", "b.txt"])
    #expect(top.first { $0.name == "docs" }?.kind == "folder")
    #expect(top.first { $0.name == "b.txt" }?.kind == "file")
    #expect(top.first { $0.name == "b.txt" }?.size == 2)

    let inner = try box.folder.list("docs", limit: 500).entries
    #expect(inner.map(\.name) == ["a.txt"])
    #expect(code { _ = try box.folder.list("b.txt", limit: 500) } == .badRequest)
    #expect(code { _ = try box.folder.list("missing", limit: 500) } == .badRequest)
}

@Test func transferEntryRoundTrips() throws {
    let entry = TransferEntry(name: "a.txt", kind: "file", size: 3, modified: Date(timeIntervalSince1970: 1_700_000_000.25))
    let data = try JSONEncoder().encode(entry)
    #expect(try JSONDecoder().decode(TransferEntry.self, from: data) == entry)
}
