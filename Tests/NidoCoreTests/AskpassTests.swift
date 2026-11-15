// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation
import Synchronization
import Testing
@testable import NidoCore

/// The one-shot askpass socket, with real sockets in a private temporary folder.
@Suite(.italian) struct AskpassTests {
    /// A short folder (the socket path must fit `sun_path`), removed by `cleanup`.
    struct Folder {
        let parent: URL
        var directory: URL { parent.appendingPathComponent("nido-askpass", isDirectory: true) }

        init() throws {
            let base = AgentControlServer.darwinUserTempDirectory() ?? "/private/tmp"
            parent = URL(fileURLWithPath: base, isDirectory: true)
                .appendingPathComponent("np-\(UUID().uuidString.prefix(8))", isDirectory: true)
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        }

        func cleanup() { try? FileManager.default.removeItem(at: parent) }
    }

    /// Accepts any peer: the real check refuses the test process, which is no ssh's child.
    let anyPeer: @Sendable (pid_t) -> Bool = { _ in true }

    // MARK: - Peer check

    @Test func refusedPeerDoesNotUseUpTheAnswer() throws {
        let folder = try Folder(); defer { folder.cleanup() }
        let seen = Mutex<[pid_t]>([])
        let server = try AskpassServer(
            password: try #require(GuestPassword("pw")), directory: folder.directory,
            peerCheck: { pid in seen.withLock { $0.append(pid); return $0.count > 1 } })
        defer { server.close() }
        // The first peer is refused: hung up on with nothing, the socket stays.
        #expect(throws: (any Error).self) { try Askpass.fetch(socketPath: server.socketPath) }
        #expect(!server.answered)
        #expect(FileManager.default.fileExists(atPath: server.socketPath))
        // The second passes and gets the one answer.
        #expect(try Askpass.fetch(socketPath: server.socketPath) == Data("pw".utf8))
        #expect(server.answered)
        // The check got the connecting process's pid (this test process).
        #expect(seen.withLock { $0 } == [getpid(), getpid()])
    }

    @Test func realCheckRefusesAProcessThatIsNoAskpassOfOurSSH() throws {
        let folder = try Folder(); defer { folder.cleanup() }
        // The public init uses the real check; this test process is not a child of an ssh.
        let server = try AskpassServer(password: try #require(GuestPassword("pw")), directory: folder.directory)
        defer { server.close() }
        #expect(throws: (any Error).self) { try Askpass.fetch(socketPath: server.socketPath) }
        #expect(!server.answered)
        #expect(!AskpassServer.isAskpassOfOurSSH(getpid()))
        #expect(!AskpassServer.isAskpassOfOurSSH(0))
        #expect(!AskpassServer.isAskpassOfOurSSH(-1))
    }

    @Test func processLookups() {
        #expect(AskpassServer.parentPID(of: getpid()) == getppid())
        let path = AskpassServer.executablePath(of: getpid())
        #expect(path != nil)
        #expect(path.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
            == Bundle.main.executableURL?.resolvingSymlinksInPath().path)
        #expect(AskpassServer.executablePath(of: 1) == "/sbin/launchd")
        // pid_t's largest value is never a running process.
        #expect(AskpassServer.parentPID(of: .max) == nil)
        #expect(AskpassServer.executablePath(of: .max) == nil)
    }

    private func mode(_ path: String) -> mode_t? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return info.st_mode & 0o7777
    }

    @Test func answersOnceThenRefuses() throws {
        let folder = try Folder(); defer { folder.cleanup() }
        let password = try #require(GuestPassword("s3cret pàss"))
        let server = try AskpassServer(password: password, directory: folder.directory, peerCheck: anyPeer)
        defer { server.close() }
        let answer = try Askpass.fetch(socketPath: server.socketPath)
        #expect(answer == Data("s3cret pàss".utf8))
        // A second prompt of ssh runs the askpass again: it gets nothing.
        #expect(throws: (any Error).self) { try Askpass.fetch(socketPath: server.socketPath) }
    }

    @Test func socketIsPrivate() throws {
        let folder = try Folder(); defer { folder.cleanup() }
        let server = try AskpassServer(password: try #require(GuestPassword("pw")), directory: folder.directory, peerCheck: anyPeer)
        defer { server.close() }
        #expect(mode(folder.directory.path) == 0o700)
        #expect(mode(server.socketPath) == 0o600)
        var info = stat()
        #expect(lstat(server.socketPath, &info) == 0)
        #expect((info.st_mode & S_IFMT) == S_IFSOCK)
        #expect(info.st_uid == getuid())
        #expect(server.socketPath.hasPrefix(folder.directory.path + "/"))
    }

    @Test func closeRemovesSocket() throws {
        let folder = try Folder(); defer { folder.cleanup() }
        let server = try AskpassServer(password: try #require(GuestPassword("pw")), directory: folder.directory, peerCheck: anyPeer)
        let path = server.socketPath
        #expect(FileManager.default.fileExists(atPath: path))
        server.close()
        #expect(!FileManager.default.fileExists(atPath: path))
        server.close()  // idempotent
        #expect(throws: (any Error).self) { try Askpass.fetch(socketPath: path) }
    }

    @Test func answeredOnlyAfterTheAnswer() throws {
        let folder = try Folder(); defer { folder.cleanup() }
        let server = try AskpassServer(password: try #require(GuestPassword("pw")), directory: folder.directory, peerCheck: anyPeer)
        defer { server.close() }
        #expect(!server.answered)
        _ = try Askpass.fetch(socketPath: server.socketPath)
        #expect(server.answered)
        server.close()
        #expect(server.answered)

        let unused = try AskpassServer(password: try #require(GuestPassword("pw")), directory: folder.directory, peerCheck: anyPeer)
        unused.close()
        #expect(!unused.answered)
    }

    @Test func answeringRemovesSocket() throws {
        let folder = try Folder(); defer { folder.cleanup() }
        let server = try AskpassServer(password: try #require(GuestPassword("pw")), directory: folder.directory, peerCheck: anyPeer)
        defer { server.close() }
        _ = try Askpass.fetch(socketPath: server.socketPath)
        #expect(!FileManager.default.fileExists(atPath: server.socketPath))
    }

    @Test func endsWhenNobodyConnects() throws {
        let folder = try Folder(); defer { folder.cleanup() }
        let server = try AskpassServer(
            password: try #require(GuestPassword("pw")), directory: folder.directory, idleTimeout: .milliseconds(200), peerCheck: anyPeer)
        defer { server.close() }
        let deadline = Date().addingTimeInterval(5)
        while FileManager.default.fileExists(atPath: server.socketPath), Date() < deadline { usleep(20_000) }
        #expect(!FileManager.default.fileExists(atPath: server.socketPath))
        #expect(throws: (any Error).self) { try Askpass.fetch(socketPath: server.socketPath) }
    }

    @Test func pathFitsSunPath() throws {
        let server = try AskpassServer(password: try #require(GuestPassword("pw")))
        defer { server.close() }
        #expect(server.socketPath.utf8.count < 104)
        #expect(server.socketPath.hasPrefix(Askpass.defaultDirectory.path + "/"))
        #expect(Askpass.defaultDirectory.lastPathComponent == "nido-askpass")
    }

    @Test func twoServersHaveDistinctSockets() throws {
        let folder = try Folder(); defer { folder.cleanup() }
        let one = try AskpassServer(password: try #require(GuestPassword("a")), directory: folder.directory, peerCheck: anyPeer)
        let two = try AskpassServer(password: try #require(GuestPassword("b")), directory: folder.directory, peerCheck: anyPeer)
        defer { one.close(); two.close() }
        #expect(one.socketPath != two.socketPath)
        #expect(try Askpass.fetch(socketPath: two.socketPath) == Data("b".utf8))
        #expect(try Askpass.fetch(socketPath: one.socketPath) == Data("a".utf8))
    }

    @Test func refusesAnOpenDirectory() throws {
        let folder = try Folder(); defer { folder.cleanup() }
        try FileManager.default.createDirectory(at: folder.directory, withIntermediateDirectories: true)
        #expect(chmod(folder.directory.path, 0o755) == 0)
        #expect(throws: (any Error).self) {
            _ = try AskpassServer(password: try #require(GuestPassword("pw")), directory: folder.directory, peerCheck: anyPeer)
        }
    }

    @Test func fetchOfMissingSocketThrows() {
        #expect(throws: (any Error).self) { try Askpass.fetch(socketPath: "/nonexistent/nido.sock") }
    }

    // MARK: - The askpass mode of `nido`

    @Test func answerModeNeedsBothVariables() {
        var written = Data()
        #expect(Askpass.answer(environment: [:], write: { written.append($0) }) == nil)
        #expect(Askpass.answer(environment: ["NIDO_ASKPASS": "1"], write: { written.append($0) }) == 1)
        #expect(Askpass.answer(environment: ["NIDO_ASKPASS_SOCKET": "/x"], write: { written.append($0) }) == nil)
        #expect(Askpass.answer(
            environment: ["NIDO_ASKPASS": "0", "NIDO_ASKPASS_SOCKET": "/x"], write: { written.append($0) }) == nil)
        #expect(written.isEmpty)
    }

    @Test func answerModeWritesThePasswordAndANewline() throws {
        let folder = try Folder(); defer { folder.cleanup() }
        let server = try AskpassServer(password: try #require(GuestPassword("pw")), directory: folder.directory, peerCheck: anyPeer)
        defer { server.close() }
        var written = Data()
        let environment = [Askpass.modeVariable: "1", Askpass.socketVariable: server.socketPath]
        #expect(Askpass.answer(environment: environment, write: { written.append($0) }) == 0)
        #expect(written == Data("pw\n".utf8))
        written = Data()
        #expect(Askpass.answer(environment: environment, write: { written.append($0) }) == 1)
        #expect(written.isEmpty)
    }

    // MARK: - Executable

    @Test func executableIsTheAppsHelper() throws {
        let folder = try Folder(); defer { folder.cleanup() }
        let app = folder.parent.appendingPathComponent("Nido.app", isDirectory: true)
        let helpers = app.appendingPathComponent("Contents/Helpers", isDirectory: true)
        try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
        let tool = helpers.appendingPathComponent("nido")
        #expect(FileManager.default.createFile(atPath: tool.path, contents: Data("#!/bin/sh\n".utf8)))
        #expect(chmod(tool.path, 0o755) == 0)
        let bundle = try #require(Bundle(url: app))
        #expect(Askpass.executable(bundle: bundle)?.path == tool.path)
    }

    @Test func executableIsNilOutsideNido() {
        // The test runner is neither Nido.app nor `nido`.
        #expect(Askpass.executable(bundle: .main) == nil)
    }
}
