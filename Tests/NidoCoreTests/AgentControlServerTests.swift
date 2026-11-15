// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation
import NidoAgentKit
import Synchronization
import Testing
@testable import NidoCore

/// A stand-in for `AgentClient.perform`: records what it is asked, answers like a helper would,
/// and notices if two calls ever overlap.
private final class FakeHelper: Sendable {
    static let png = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3, 4])
    static let image = PixelSize(1280, 800)
    static let screen = ScreenSize(width: 1440, height: 900)
    static let status = AgentStatus(
        helperVersion: "1.0.0", protocolVersion: 1, screenRecording: true, accessibility: true, screen: screen)

    private struct State {
        var requests: [AgentRequest] = []
        var inFlight = 0
        var maxInFlight = 0
    }
    private let state = Mutex(State())
    let delay: Duration

    init(delay: Duration = .zero) { self.delay = delay }

    var requests: [AgentRequest] { state.withLock { $0.requests } }
    var maxInFlight: Int { state.withLock { $0.maxInFlight } }

    var perform: @Sendable (AgentRequest) async throws(AgentFailure) -> (AgentReply, Data?) {
        { [self] request throws(AgentFailure) in
            state.withLock {
                $0.requests.append(request)
                $0.inFlight += 1
                $0.maxInFlight = max($0.maxInFlight, $0.inFlight)
            }
            if delay > .zero { try? await Task.sleep(for: delay) }
            state.withLock { $0.inFlight -= 1 }
            switch request.action {
            case .status:
                return (AgentReply(ok: true, status: Self.status), nil)
            case .screenshot:
                return (AgentReply(ok: true, image: Self.image, screen: Self.screen), Self.png)
            case .type(let text):
                return (AgentReply(ok: true, message: text), nil)
            case .key(let combo) where combo == "fail":
                throw AgentFailure(code: .notReady, message: "not ready")
            case .key(let combo) where combo == "old":
                throw AgentFailure(code: .versionMismatch, message: "incompatible")
            case .key(let combo) where combo == "refuse":
                return (AgentReply(ok: false, error: .permissionMissing, message: "no permission"), nil)
            default:
                return (AgentReply(ok: true), nil)
            }
        }
    }
}

/// A raw connection to the control socket, for what `AgentControlClient` (one command per
/// connection) cannot do: several commands on one connection, garbage, oversized lines.
private final class RawConnection: @unchecked Sendable {
    let fd: Int32
    /// The VM id and bundle every command carries.
    let vmID: UUID
    let bundle: URL

    init(_ url: URL, vmID: UUID, bundle: URL) throws {
        self.vmID = vmID
        self.bundle = bundle
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        try #require(fd >= 0)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = Array(url.path.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            for (i, byte) in path.enumerated() { raw[i] = byte }
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result != 0 { close(fd) }
        try #require(result == 0)
    }

    deinit { close(fd) }

    /// Writes all of `data`, or as much as the peer takes before it closes.
    func write(_ data: Data) {
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n <= 0 { return }
                offset += n
            }
        }
    }

    func send(_ action: AgentAction) throws {
        var line = try JSONEncoder().encode(AgentCommand(vmID: vmID, bundlePath: AgentCommand.bundlePath(bundle), action: action))
        line.append(0x0A)
        write(line)
    }

    /// The next line, or nil at EOF.
    func readLine() -> Data? {
        var line = Data()
        var byte: UInt8 = 0
        while true {
            let n = read(fd, &byte, 1)
            if n <= 0 { return nil }
            if byte == 0x0A { return line }
            line.append(byte)
        }
    }

    func readAnswer() throws -> AgentAnswer? {
        guard let line = readLine() else { return nil }
        return try JSONDecoder().decode(AgentAnswer.self, from: line)
    }
}

/// A bundle with agent access on, a fake helper and a short socket root under /Users/Shared.
private struct Env {
    let tmp: URL
    let root: URL
    let bundle: VMBundle
    let config: VMConfig
    let helper: FakeHelper

    init(delay: Duration = .zero) throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("nido-act-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        // Short and not yet existing: the server creates it.
        root = URL(fileURLWithPath: "/Users/Shared", isDirectory: true)
            .appendingPathComponent("nat-\(UUID().uuidString.prefix(8))", isDirectory: true)
        config = VMConfig(
            id: UUID(), name: try VMName("mac"), guest: .macos, cpuCount: 4,
            memoryBytes: 8 * 1024 * 1024 * 1024, diskBytes: 64 * 1024 * 1024 * 1024,
            macAddress: "02:00:00:00:00:01", agentAccess: true)
        bundle = try VMBundle.create(config: config, paths: NidoPaths(root: tmp.appendingPathComponent("VMs")))
        helper = FakeHelper(delay: delay)
    }

    var socketURL: URL { AgentControlServer.socketURL(vmID: config.id, root: root) }

    func start() throws -> AgentControlServer {
        try AgentControlServer.start(bundle: bundle, vmID: config.id, perform: helper.perform, root: root)
    }

    func start(sendTimeoutSeconds: Int) throws -> AgentControlServer {
        try AgentControlServer.start(
            bundle: bundle, vmID: config.id, perform: helper.perform, root: root, sendTimeoutSeconds: sendTimeoutSeconds)
    }

    func client() -> AgentControlClient {
        AgentControlClient(vmID: config.id, vmName: config.name.rawValue, bundle: bundle.url, root: root)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: tmp)
        try? FileManager.default.removeItem(at: root)
    }
}

private func mode(_ url: URL) -> (type: mode_t, permissions: mode_t)? {
    var info = stat()
    guard lstat(url.path, &info) == 0 else { return nil }
    return (info.st_mode & S_IFMT, info.st_mode & 0o777)
}


/// Runs blocking socket I/O on a thread of its own. Swift Testing runs tests on the cooperative
/// pool, which the server's gate needs too: tests blocked there in `read`, many in parallel,
/// would starve it (and the timing of every other suite).
private func blocking<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        Thread { continuation.resume(with: Result { try body() }) }.start()
    }
}

@Suite struct AgentControlServerTests {
    @Test func socketAndDirectoryModes() throws {
        let env = try Env()
        defer { env.cleanup() }
        let server = try env.start()
        defer { server.stop() }

        #expect(env.socketURL.lastPathComponent == String(env.config.id.uuidString.lowercased().prefix(8)) + ".sock")
        #expect(env.socketURL.deletingLastPathComponent().standardizedFileURL == env.root.standardizedFileURL)
        let directory = try #require(mode(env.root))
        #expect(directory.type == S_IFDIR)
        #expect(directory.permissions == 0o700)
        let socket = try #require(mode(env.socketURL))
        #expect(socket.type == S_IFSOCK)
        #expect(socket.permissions == 0o600)
        #expect(AgentControlServer.socketURL(vmID: env.config.id).path.utf8.count <= 103)
        #expect(AgentControlServer.defaultRoot.lastPathComponent == "nido-agent")
    }

    /// The owner (the app, started by launchd, or `nido start`) and the client (`nido mcp`,
    /// started by any MCP client) must find the same socket: the root comes from the user's
    /// temporary folder as `confstr` gives it, never from `$TMPDIR`, which each may set apart.
    @Test func rootComesFromTheUserTempDirectoryNotTMPDIR() throws {
        #expect(AgentControlServer.root(userTempDirectory: "/var/folders/ab/xyz0000gn/T/").path
            == "/var/folders/ab/xyz0000gn/T/nido-agent")
        let fromConfstr = try #require(AgentControlServer.darwinUserTempDirectory())
        #expect(fromConfstr.hasPrefix("/") && fromConfstr.hasSuffix("/T/"))
        #expect(AgentControlServer.defaultRoot == AgentControlServer.root(userTempDirectory: fromConfstr))
        // No answer from confstr (or not an absolute path): a per-user folder in /private/tmp,
        // which `prepareDirectory` still requires to be this user's own and private.
        let fallback = "/private/tmp/nido-agent-\(getuid())"
        #expect(AgentControlServer.root(userTempDirectory: nil).path == fallback)
        #expect(AgentControlServer.root(userTempDirectory: "relative/T/").path == fallback)
    }

    @Test func unsafeDirectoryRefused() throws {
        let env = try Env()
        defer { env.cleanup() }

        // A directory others can enter.
        try FileManager.default.createDirectory(at: env.root, withIntermediateDirectories: false)
        #expect(chmod(env.root.path, 0o755) == 0)
        #expect(throws: (any Error).self) { try env.start() }
        #expect(mode(env.socketURL) == nil)

        // A symlink to a private directory.
        try FileManager.default.removeItem(at: env.root)
        let target = env.tmp.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        #expect(chmod(target.path, 0o700) == 0)
        try FileManager.default.createSymbolicLink(at: env.root, withDestinationURL: target)
        #expect(throws: (any Error).self) { try env.start() }
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
    }

    @Test func staleSocketIsReplaced() async throws {
        let env = try Env()
        defer { env.cleanup() }
        try FileManager.default.createDirectory(at: env.root, withIntermediateDirectories: false)
        #expect(chmod(env.root.path, 0o700) == 0)
        try Data("stale".utf8).write(to: env.socketURL)

        let server = try env.start()
        defer { server.stop() }
        let client = env.client()
        let answer = try await blocking { try client.send(.status) }
        #expect(answer.ok)
    }

    /// A socket bound and then abandoned (its owner died without `stop()`): nobody accepts on it.
    @Test func staleDeadSocketIsReplaced() async throws {
        let env = try Env()
        defer { env.cleanup() }
        try AgentControlServer.prepareDirectory(env.root)
        let dead = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = try AgentControlServer.socketAddress(env.socketURL)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(dead, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        #expect(bound == 0)
        close(dead)
        #expect(mode(env.socketURL)?.type == S_IFSOCK)

        let server = try env.start()
        defer { server.stop() }
        let client = env.client()
        let answer = try await blocking { try client.send(.status) }
        #expect(answer.ok)
    }

    /// SECURITY: a socket another owner serves (a VM whose id starts with the same 8 hex digits,
    /// or a copy of this bundle) is never taken over: the second owner refuses to start, and the
    /// first one keeps answering.
    @Test func liveSocketIsNotStolen() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let server = try env.start()
        defer { server.stop() }

        let intruder = FakeHelper()
        #expect(throws: NidoError.agentSocketInUse(env.socketURL.path)) {
            _ = try AgentControlServer.start(
                bundle: env.bundle, vmID: env.config.id, perform: intruder.perform, root: env.root)
        }
        let client = env.client()
        let answer = try await blocking { try client.send(.status) }
        #expect(answer.ok)
        #expect(env.helper.requests.count == 1)
        #expect(intruder.requests.isEmpty)
    }

    /// Owners claim their socket name under a lock on the folder; one stuck while holding it
    /// delays another's start by at most 3 s, then that start fails (a warning) and binds nothing.
    @Test func startGivesUpWhenTheFolderStaysLocked() async throws {
        let env = try Env()
        defer { env.cleanup() }
        try AgentControlServer.prepareDirectory(env.root)
        let held = try AgentControlServer.lockDirectory(env.root)
        defer { close(held) }

        let began = ContinuousClock.now
        let failed = try await blocking { () -> Bool in
            do {
                _ = try env.start()
                return false
            } catch let error as POSIXError {
                return error.code == .EWOULDBLOCK
            }
        }
        #expect(failed)
        #expect(began.duration(to: .now) >= .seconds(3))
        #expect(mode(env.socketURL) == nil)
    }

    /// SECURITY: a command for another VM whose socket name is the same (same first 8 hex digits
    /// of the id) is refused as `notRunning` and never reaches this VM's helper.
    @Test func commandForAnotherVMIsRefused() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let server = try env.start()
        defer { server.stop() }

        let id = env.config.id.uuidString
        let twin = try #require(UUID(uuidString: String(id.dropLast()) + (id.hasSuffix("0") ? "1" : "0")))
        #expect(AgentControlServer.socketURL(vmID: twin, root: env.root) == env.socketURL)
        let client = AgentControlClient(vmID: twin, vmName: "other", bundle: env.bundle.url, root: env.root)
        let answer = try await blocking { try client.send(.status) }
        #expect(!answer.ok)
        #expect(answer.error == .notRunning)
        #expect(env.helper.requests.isEmpty)
    }

    /// SECURITY: a bundle duplicated in Finder keeps the VM id. The copy, started second, serves
    /// no socket (`liveSocketIsNotStolen`); `nido act copy` must not drive the original through
    /// the original's socket: the command names its bundle, and another bundle is refused.
    @Test func commandFromACopiedBundleIsRefused() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let server = try env.start()
        defer { server.stop() }

        // Only its path matters to the owner: an empty folder stands for the copy.
        let copy = env.tmp.appendingPathComponent("VMs/mac copy", isDirectory: true)
        try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
        let client = AgentControlClient(vmID: env.config.id, vmName: "mac copy", bundle: copy, root: env.root)
        let answer = try await blocking { try client.send(.status) }
        #expect(!answer.ok)
        #expect(answer.error == .notRunning)
        #expect(env.helper.requests.isEmpty)

        // The same bundle through a symlink is the same bundle.
        let link = env.tmp.appendingPathComponent("link.nidovm")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: env.bundle.url)
        let viaLink = AgentControlClient(vmID: env.config.id, vmName: "mac", bundle: link, root: env.root)
        #expect(try await blocking { try viaLink.send(.status) }.ok)
    }

    @Test func statusThroughSocket() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let server = try env.start()
        defer { server.stop() }

        let client = env.client()
        let answer = try await blocking { try client.send(.status) }
        #expect(answer.ok)
        #expect(answer.status?.helperVersion == "1.0.0")
        #expect(env.helper.requests == [AgentRequest(v: AgentProtocol.version, action: .status)])
    }

    @Test func screenshotWritesPrivateFile() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let server = try env.start()
        defer { server.stop() }

        let client = env.client()
        let answer = try await blocking { try client.send(.screenshot(maxLongEdge: 1000)) }
        #expect(answer.ok)
        #expect(answer.image == FakeHelper.image)
        #expect(answer.screen == FakeHelper.screen)
        let path = try #require(answer.path)
        let file = try #require(mode(URL(fileURLWithPath: path)))
        #expect(file.type == S_IFREG)
        #expect(file.permissions == 0o600)
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == FakeHelper.png)
        #expect(URL(fileURLWithPath: path).deletingLastPathComponent().standardizedFileURL
            == env.bundle.agentShotsURL.standardizedFileURL)
        // maxLongEdge is the client's, forwarded unchanged.
        #expect(env.helper.requests.first?.action == .screenshot(maxLongEdge: 1000))
    }

    @Test func clickBeforeScreenshotRefused() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let server = try env.start()
        defer { server.stop() }

        let client = env.client()
        for action: AgentAction in [
            .click(x: 10, y: 10, button: .left, count: 1),
            .drag(fromX: 1, fromY: 1, toX: 2, toY: 2),
            .scroll(dx: 0, dy: 3, x: 5, y: 5),
        ] {
            let answer = try await blocking { try client.send(action) }
            #expect(!answer.ok)
            #expect(answer.error == .noScreenshot)
            #expect(answer.message?.isEmpty == false)
        }
        #expect(env.helper.requests.isEmpty)

        // Nothing that carries coordinates needs a screenshot.
        for action: AgentAction in [.scroll(dx: 0, dy: 3, x: nil, y: nil), .type(text: "hi"), .key(combo: "cmd+a")] {
            let answer = try await blocking { try client.send(action) }
            #expect(answer.ok)
        }
        #expect(env.helper.requests.count == 3)
    }

    /// Only the VM's owner puts text on the guest's clipboard, over its own vsock: the socket of
    /// `nido act` and `nido mcp` refuses it, and the helper never hears of it.
    @Test func setClipboardIsRefusedOnTheSocket() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let server = try env.start()
        defer { server.stop() }

        let raw = try RawConnection(env.socketURL, vmID: env.config.id, bundle: env.bundle.url)
        let answers = try await blocking {
            try raw.send(.setClipboard(text: "secret-value", clearAfter: 60))
            let refused = try raw.readAnswer()
            // The connection stays: the next command is served.
            try raw.send(.status)
            return [refused, try raw.readAnswer()]
        }
        #expect(answers[0]?.ok == false)
        #expect(answers[0]?.error == .badRequest)
        #expect(answers[0]?.message?.contains("secret-value") == false)
        #expect(answers[1]?.ok == true)
        #expect(env.helper.requests.map(\.action) == [.status])
    }

    @Test func clickCarriesLastScreenshotSize() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let server = try env.start()
        defer { server.stop() }

        let client = env.client()
        let answers = try await blocking {
            [
                try client.send(.screenshot(maxLongEdge: 1280)),
                try client.send(.click(x: 100, y: 200, button: .right, count: 2)),
                try client.send(.drag(fromX: 1, fromY: 2, toX: 3, toY: 4)),
                try client.send(.scroll(dx: 0, dy: -2, x: 7, y: 8)),
            ]
        }
        #expect(answers.map(\.ok) == [true, true, true, true])
        let requests = env.helper.requests
        try #require(requests.count == 4)
        for request in requests.dropFirst() {
            #expect(request.v == AgentProtocol.version)
            #expect(request.image == FakeHelper.image)
            #expect(request.screen == FakeHelper.screen)
        }
        #expect(requests[1].action == .click(x: 100, y: 200, button: .right, count: 2))
    }

    @Test func helperErrorsAreForwardedAndConnectionStays() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let server = try env.start()
        defer { server.stop() }

        let connection = try RawConnection(env.socketURL, vmID: env.config.id, bundle: env.bundle.url)
        let (refused, failed, status) = try await blocking {
            try connection.send(.key(combo: "refuse"))
            let refused = try connection.readAnswer()
            try connection.send(.key(combo: "fail"))
            let failed = try connection.readAnswer()
            try connection.send(.status)
            return (refused, failed, try connection.readAnswer())
        }
        #expect(refused?.ok == false)
        #expect(refused?.error == .permissionMissing)
        #expect(refused?.message == "no permission")
        #expect(failed?.ok == false)
        #expect(failed?.error == .notReady)
        #expect(failed?.message == "not ready")
        #expect(status?.ok == true)
    }

    /// A helper too old (or too new) for this Nido: the answer names the command that updates it,
    /// with the VM's name.
    @Test func versionMismatchNamesTheSetupCommand() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let server = try env.start()
        defer { server.stop() }

        let client = env.client()
        let answer = try await blocking { try client.send(.key(combo: "old")) }
        #expect(answer.error == .versionMismatch)
        #expect(answer.message?.contains("nido agent setup mac") == true)
    }

    @Test func agentAccessOffRefusesNext() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let server = try env.start()
        defer { server.stop() }

        let connection = try RawConnection(env.socketURL, vmID: env.config.id, bundle: env.bundle.url)
        let first = try await blocking {
            try connection.send(.status)
            return try connection.readAnswer()
        }
        #expect(first?.ok == true)

        try env.bundle.updateConfig { $0.agentAccess = false }
        let (answer, closed) = try await blocking {
            try connection.send(.status)
            return (try connection.readAnswer(), connection.readLine() == nil)
        }
        #expect(answer?.ok == false)
        #expect(answer?.error == .agentAccessOff)
        #expect(answer?.message?.contains("mac") == true)
        #expect(closed)
        #expect(env.helper.requests.count == 1)

        // Off for new connections too.
        let client = env.client()
        let again = try await blocking { try client.send(.status) }
        #expect(again.error == .agentAccessOff)
    }

    @Test func concurrentClientsSerialize() async throws {
        let env = try Env(delay: .milliseconds(2))
        defer { env.cleanup() }
        let server = try env.start()
        defer { server.stop() }

        let client = env.client()
        let mismatches = try await withThrowingTaskGroup(of: Int.self) { group in
            for c in 0..<2 {
                group.addTask {
                    try await blocking {
                        var wrong = 0
                        for i in 0..<20 {
                            let text = "c\(c)-\(i)"
                            let answer = try client.send(.type(text: text))
                            if !answer.ok || answer.message != text { wrong += 1 }
                        }
                        return wrong
                    }
                }
            }
            return try await group.reduce(0, +)
        }
        #expect(mismatches == 0)
        #expect(env.helper.requests.count == 40)
        #expect(env.helper.maxInFlight == 1)
    }

    /// A client that sends many commands and never reads blocks its own connection on writing
    /// the answers, not the gate: another client is still served.
    @Test func clientThatStopsReadingBlocksOnlyItself() async throws {
        let env = try Env()
        defer { env.cleanup() }
        // A send timeout far beyond the other client's: if the blocked write held the gate, that
        // client would time out instead of being served.
        let server = try env.start(sendTimeoutSeconds: 120)
        defer { server.stop() }

        let stuck = try RawConnection(env.socketURL, vmID: env.config.id, bundle: env.bundle.url)
        var lines = Data()
        for _ in 0..<2000 {
            lines.append(try JSONEncoder().encode(AgentCommand(vmID: env.config.id, bundlePath: AgentCommand.bundlePath(env.bundle.url), action: .status)))
            lines.append(0x0A)
        }
        let lineData = lines
        let written = Task { _ = try await blocking { stuck.write(lineData) } }

        // Wait until the server has filled the stuck client's buffer with answers and blocks
        // writing the next one: the count stops growing well before the 2000 commands. (A pause
        // mistaken for that only weakens the test: the other client then queues behind at most
        // one command of the stuck one.)
        let deadline = ContinuousClock.now + .seconds(60)
        var count = 0
        while ContinuousClock.now < deadline {
            try await Task.sleep(for: .seconds(1))
            let now = env.helper.requests.count
            if now > 0 && now == count { break }
            count = now
        }
        #expect(count > 0 && count < 2000)

        let client = env.client()
        let answer = try await blocking { try client.send(.status, timeout: .seconds(30)) }
        #expect(answer.ok)

        shutdown(stuck.fd, SHUT_RDWR)  // frees the writer
        try await written.value
    }

    @Test func garbageLineGetsErrorAndServerLives() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let server = try env.start()
        defer { server.stop() }

        let garbage = try RawConnection(env.socketURL, vmID: env.config.id, bundle: env.bundle.url)
        let bad = try await blocking {
            garbage.write(Data("not json\n".utf8))
            return try garbage.readAnswer()
        }
        #expect(bad?.ok == false)
        #expect(bad?.error == .badRequest)

        let long = try RawConnection(env.socketURL, vmID: env.config.id, bundle: env.bundle.url)
        let (tooLong, closed) = try await blocking {
            long.write(Data(repeating: UInt8(ascii: "a"), count: 70 * 1024) + Data("\n".utf8))
            return (try long.readAnswer(), long.readLine() == nil)
        }
        #expect(tooLong?.error == .badRequest)
        #expect(closed)

        let client = env.client()
        let status = try await blocking { try client.send(.status) }
        #expect(status.status?.helperVersion == "1.0.0")
        #expect(env.helper.requests.count == 1)
    }

    @Test func notRunningWithoutSocket() async throws {
        let env = try Env()
        defer { env.cleanup() }

        let client = env.client()
        let answer = try await blocking { try client.send(.status) }
        #expect(!answer.ok)
        #expect(answer.error == .notRunning)
        #expect(answer.message?.contains("nido start mac") == true)
    }

    /// `nido agent enable` on a running VM: its owner serves no socket until the next start, and
    /// the client says so rather than "start it".
    @Test func runningVMWithoutSocketSaysRestart() async throws {
        let env = try Env()
        defer { env.cleanup() }

        let client = AgentControlClient(
            vmID: env.config.id, vmName: env.config.name.rawValue, bundle: env.bundle.url, root: env.root,
            isRunningWithAgentAccess: { true })
        let answer = try await blocking { try client.send(.status) }
        #expect(answer.error == .notRunning)
        #expect(answer.message == L10n.string("agent access was turned on after \("mac") started: restart it"))
        #expect(answer.message != L10n.string("start it with `nido start \("mac")`"))
    }

    /// The restart hint is only for no socket at all: a socket file nobody answers on (its owner
    /// died, or failed to serve) keeps the generic text.
    @Test func deadSocketKeepsTheGenericText() async throws {
        let env = try Env()
        defer { env.cleanup() }
        try AgentControlServer.prepareDirectory(env.root)
        let dead = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = try AgentControlServer.socketAddress(env.socketURL)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(dead, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        #expect(bound == 0)
        close(dead)

        let client = AgentControlClient(
            vmID: env.config.id, vmName: env.config.name.rawValue, bundle: env.bundle.url, root: env.root,
            isRunningWithAgentAccess: { true })
        let answer = try await blocking { try client.send(.status) }
        #expect(answer.error == .notRunning)
        #expect(answer.message == L10n.string("start it with `nido start \("mac")`"))
    }

    @Test func stopClosesConnectionsAndRemovesSocket() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let server = try env.start()

        let connection = try RawConnection(env.socketURL, vmID: env.config.id, bundle: env.bundle.url)
        let first = try await blocking {
            try connection.send(.status)
            return try connection.readAnswer()
        }
        #expect(first?.ok == true)
        server.stop()
        let closed = try await blocking { connection.readLine() == nil }
        #expect(closed)
        #expect(mode(env.socketURL) == nil)
        let client = env.client()
        let after = try await blocking { try client.send(.status) }
        #expect(after.error == .notRunning)
        server.stop()  // idempotent
    }
}
