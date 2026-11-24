// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation
import NidoAgentKit
import Synchronization
import Testing
@_spi(Testing) @testable import NidoCore

/// A stand-in for `AgentClient.perform`: records what it is asked, answers like a helper would,
/// and notices if two calls ever overlap.
private final class FakeHelper: Sendable {
    /// A real PNG: the owner makes the activity log's thumbnail from it.
    static let png = testPNG(width: 640, height: 400)
    static let image = PixelSize(1280, 800)
    static let screen = ScreenSize(width: 1440, height: 900)
    static let zoomImage = PixelSize(400, 200)
    /// What `getFile` answers: binary, with a secret the log must never hold.
    static let fileBytes = Data("GUESTSECRET\u{0}\u{1B}[31m".utf8) + Data((0..<1000).map { UInt8($0 % 256) })
    /// What `listFiles` answers: one name with controls a terminal would run.
    static let entries = [
        TransferEntry(name: "report\u{1B}]0;pwned\u{7}\nnext", kind: "file", size: 12,
                      modified: Date(timeIntervalSince1970: 1_800_000_000)),
        TransferEntry(name: "folder", kind: "folder", size: 0, modified: Date(timeIntervalSince1970: 1_700_000_000)),
    ]

    private struct State {
        var requests: [AgentRequest] = []
        var inFlight = 0
        var maxInFlight = 0
    }
    private let state = Mutex(State())
    let delay: Duration
    let helperVersion: String
    /// What `status` answers instead of a status: a refusal (`ok` false) or an ok reply without one.
    let statusReply: AgentReply?
    /// What `uiTree` answers.
    let tree: UITree
    /// What the clipboard holds: lines, a tab, and escape sequences a terminal would run.
    static let clipboardText = "line one\n\tindented\u{1B}[31m red\r\nline\u{9B}three\u{200B}"
    private let clipboardOverride = Mutex<AgentReply?>(nil)
    /// What `readClipboard` answers instead of the clipboard text.
    var clipboardReply: AgentReply? {
        get { clipboardOverride.withLock { $0 } }
        set { clipboardOverride.withLock { $0 = newValue } }
    }
    private let zoomOverride = Mutex<AgentReply?>(nil)
    /// What `zoom` answers instead of an image (a refusal such as `screenChanged`).
    var zoomReply: AgentReply? {
        get { zoomOverride.withLock { $0 } }
        set { zoomOverride.withLock { $0 = newValue } }
    }

    init(delay: Duration = .zero, helperVersion: String = "1.0.0", statusReply: AgentReply? = nil,
         tree: UITree = UITree(app: "Notes", elements: [], truncated: false)) {
        self.delay = delay
        self.helperVersion = helperVersion
        self.statusReply = statusReply
        self.tree = tree
    }

    var status: AgentStatus {
        AgentStatus(helperVersion: helperVersion, protocolVersion: 1, screenRecording: true, accessibility: true,
                    screen: Self.screen)
    }

    var requests: [AgentRequest] { state.withLock { $0.requests } }
    var maxInFlight: Int { state.withLock { $0.maxInFlight } }

    static let lockedMessage = "the VM's screen is locked: log in through its window"
    private let lockedState = Mutex(false)
    /// The guest's screen is locked: `screenshot`, `zoom` and `uiTree` answer as Nido Agent does.
    var locked: Bool {
        get { lockedState.withLock { $0 } }
        set { lockedState.withLock { $0 = newValue } }
    }

    var perform: @Sendable (AgentRequest) async throws(AgentFailure) -> (AgentReply, Data?) {
        { [self] request throws(AgentFailure) in
            state.withLock {
                $0.requests.append(request)
                $0.inFlight += 1
                $0.maxInFlight = max($0.maxInFlight, $0.inFlight)
            }
            if delay > .zero { try? await Task.sleep(for: delay) }
            state.withLock { $0.inFlight -= 1 }
            if locked {
                switch request.action {
                case .screenshot, .zoom, .uiTree:
                    return (AgentReply(ok: false, error: .notReady, message: Self.lockedMessage), nil)
                default:
                    break
                }
            }
            switch request.action {
            case .status:
                return (statusReply ?? AgentReply(ok: true, status: status), nil)
            case .screenshot:
                return (AgentReply(ok: true, image: Self.image, screen: Self.screen), Self.png)
            case .zoom where zoomReply != nil:
                return (zoomReply!, nil)
            case .zoom:
                return (AgentReply(ok: true, image: Self.zoomImage, screen: Self.screen), Self.png)
            case .uiTree:
                return (AgentReply(ok: true, tree: tree), nil)
            case .type(let text):
                return (AgentReply(ok: true, message: text), nil)
            case .putFile:
                return (AgentReply(ok: true, bytes: request.payload?.count), nil)
            case .getFile(let path, _) where path == "missing":
                return (AgentReply(ok: false, error: .badRequest, message: "no such file: missing"), nil)
            case .getFile:
                return (AgentReply(ok: true, bytes: Self.fileBytes.count), Self.fileBytes)
            case .listFiles:
                return (AgentReply(ok: true, files: Self.entries, truncated: true), nil)
            case .readClipboard:
                return (clipboardReply ?? AgentReply(ok: true, clipboard: Self.clipboardText), nil)
            case .writeClipboard:
                return (AgentReply(ok: true), nil)
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

/// A stand-in for Vision: answers what it is given and keeps the PNGs it was asked to read.
private final class FakeRecognizer: TextRecognizing, @unchecked Sendable {
    private let state = Mutex<[Data]>([])
    private let lock = Mutex<(found: [RecognizedText], failure: Bool)>(([], false))
    var found: [RecognizedText] {
        get { lock.withLock { $0.found } }
        set { lock.withLock { $0.found = newValue } }
    }
    var pngs: [Data] { state.withLock { $0 } }

    init(_ found: [RecognizedText] = [], failure: Bool = false) {
        lock.withLock { $0 = (found, failure) }
    }

    /// When set, the first call waits for `release()`.
    var warmUpHold: Bool {
        get { hold.withLock { $0.on } }
        set { hold.withLock { $0.on = newValue } }
    }
    private let hold = Mutex<(on: Bool, released: Bool)>((false, false))
    func release() { hold.withLock { $0.released = true } }

    func recognize(png: Data) async throws -> [RecognizedText] {
        let first = state.withLock { pngs -> Bool in pngs.append(png); return pngs.count == 1 }
        if first {
            while hold.withLock({ $0.on && !$0.released }) { try? await Task.sleep(for: .milliseconds(10)) }
        }
        let (found, failure) = lock.withLock { $0 }
        if failure { throw CocoaError(.fileReadUnknown) }
        return found
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

    func send(_ action: AgentAction, client: String? = nil, session: String? = nil, staged: String? = nil) throws {
        var command = AgentCommand(
            vmID: vmID, bundlePath: AgentCommand.bundlePath(bundle), action: action, client: client, session: session)
        command.staged = staged
        // Sorted keys, like `AgentControlClient`: a long clipboard line must start with its `op`.
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        var line = try encoder.encode(command)
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

/// A stand-in for the owner's checkpoint handling: records each call and answers like the
/// coordinator would.
private final class FakeCheckpoints: AgentCheckpointHandling {
    static let defaultName = "agent-20261117-101500"
    static let list = [
        AgentCheckpointInfo(name: "newest", createdAt: Date(timeIntervalSince1970: 1_800_000_100)),
        AgentCheckpointInfo(name: "older", createdAt: Date(timeIntervalSince1970: 1_800_000_000)),
    ]
    private let state = Mutex<[String]>([])
    var calls: [String] { state.withLock { $0 } }

    func checkpoint(name: String?) async -> AgentAnswer {
        state.withLock { $0.append("checkpoint \(name ?? "nil")") }
        let saved = name ?? Self.defaultName
        return AgentAnswer(ok: true, message: "checkpoint \(saved) saved",
                           checkpoint: AgentCheckpointInfo(name: saved, createdAt: Date(timeIntervalSince1970: 1_800_000_200)))
    }

    func checkpoints() async -> AgentAnswer {
        state.withLock { $0.append("checkpoints") }
        return AgentAnswer(ok: true, checkpoints: Self.list)
    }

    func rollback(name: String?) async -> AgentAnswer {
        state.withLock { $0.append("rollback \(name ?? "nil")") }
        guard let target = name.map({ n in Self.list.first { $0.name == n } }) ?? Self.list.first else {
            return .failure(.badRequest, "no agent checkpoint named \(name ?? "")")
        }
        return AgentAnswer(ok: true, message: "going back to \(target.name)", checkpoint: target)
    }
}

/// A bundle with agent access on, a fake helper and a short socket root under /Users/Shared.
private struct Env {
    let tmp: URL
    let root: URL
    let bundle: VMBundle
    let config: VMConfig
    let helper: FakeHelper

    init(delay: Duration = .zero, helperVersion: String = "1.0.0", statusReply: AgentReply? = nil,
         tree: UITree = UITree(app: "Notes", elements: [], truncated: false)) throws {
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
        helper = FakeHelper(delay: delay, helperVersion: helperVersion, statusReply: statusReply, tree: tree)
    }

    var socketURL: URL { AgentControlServer.socketURL(vmID: config.id, root: root) }

    func start() throws -> AgentControlServer {
        try AgentControlServer.start(bundle: bundle, vmID: config.id, perform: helper.perform, root: root)
    }

    func start(sendTimeoutSeconds: Int) throws -> AgentControlServer {
        try AgentControlServer.start(
            bundle: bundle, vmID: config.id, perform: helper.perform, root: root, sendTimeoutSeconds: sendTimeoutSeconds)
    }

    /// `start` with the activity log's clock injected.
    func start(now: @escaping @Sendable () -> Date) throws -> AgentControlServer {
        try AgentControlServer.start(
            bundle: bundle, vmID: config.id, perform: helper.perform, root: root,
            sendTimeoutSeconds: AgentControlServer.sendTimeoutSeconds, now: now)
    }

    func client(_ name: String? = nil, session: String? = nil) -> AgentControlClient {
        AgentControlClient(vmID: config.id, vmName: config.name.rawValue, bundle: bundle.url, root: root,
                           client: name, session: session)
    }

    /// `start` with the activity log's writer injected.
    func start(appendLog: @escaping AgentActivityWriter.Append) throws -> AgentControlServer {
        try AgentControlServer.start(
            bundle: bundle, vmID: config.id, perform: helper.perform, root: root,
            sendTimeoutSeconds: AgentControlServer.sendTimeoutSeconds, appendLog: appendLog)
    }

    /// `start` with the recognizer read-text requests use.
    func start(recognizer: any TextRecognizing) throws -> AgentControlServer {
        try AgentControlServer.start(
            bundle: bundle, vmID: config.id, perform: helper.perform, root: root,
            sendTimeoutSeconds: AgentControlServer.sendTimeoutSeconds, recognizer: recognizer, warmUp: false)
    }

    /// `start` with the recognizer, left to warm up as in the app.
    func startWarming(recognizer: any TextRecognizing) throws -> AgentControlServer {
        try AgentControlServer.start(
            bundle: bundle, vmID: config.id, perform: helper.perform, root: root,
            sendTimeoutSeconds: AgentControlServer.sendTimeoutSeconds, recognizer: recognizer, warmUp: true)
    }

    /// `start` with the owner's checkpoint handling.
    func start(checkpoints: any AgentCheckpointHandling) throws -> AgentControlServer {
        try AgentControlServer.start(bundle: bundle, vmID: config.id, perform: helper.perform, checkpoints: checkpoints,
                                     root: root)
    }

    /// The activity log as a reader sees it once `server` has written what it was handed.
    func log(_ server: AgentControlServer) -> [AgentActivityEntry] {
        server.waitForLog()
        return (try? AgentActivityLog.read(in: bundle, limit: nil)) ?? []
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
    /// The owner reads a line over 64 KiB only when it starts with its long-line prefix: the
    /// client's encoding of a `writeClipboard` command must (contract between the two).
    @Test func clientEncodingOfWriteClipboardStartsWithTheLongLinePrefix() throws {
        let command = AgentCommand(
            vmID: UUID(), bundlePath: "/tmp/x.nidovm", action: .writeClipboard(text: "héllo\n\u{1}"),
            client: "mcp", session: "s", staged: nil, readText: nil)
        let line = try AgentControlClient.encode(command)
        #expect(line.starts(with: AgentControlServer.longLinePrefix))
        let other = try AgentControlClient.encode(AgentCommand(
            vmID: UUID(), bundlePath: "/tmp/x.nidovm", action: .type(text: "x")))
        #expect(!other.starts(with: AgentControlServer.longLinePrefix))
    }

    /// The client waits longer than the owner's own limits towards the helper, so the owner's
    /// error arrives rather than a timeout: a zoom asks `status` first, then the image.
    @Test func clientTimeoutCoversTheOwnersLimits() {
        let zoom = AgentControlClient.timeout(for: .zoom(x: 0, y: 0, width: 10, height: 10, maxLongEdge: 800))
        #expect(zoom > AgentClient.defaultTimeout + AgentClient.defaultImageTimeout)
        for action: AgentAction in [.status, .screenshot(maxLongEdge: 800), .click(x: 1, y: 1, button: .left, count: 1)] {
            let limit = AgentControlClient.timeout(for: action)
            #expect(limit > AgentClient.defaultImageTimeout, "\(action)")
            #expect(limit < zoom, "\(action)")
        }
        #expect(AgentControlClient.timeout(for: .status) == .seconds(20))
    }

    /// A `uiTree` asks `status` first, then the tree: the client waits for both of the owner's
    /// limits towards the helper.
    @Test func clientTimeoutCoversUITree() {
        let limit = AgentControlClient.timeout(for: .uiTree(maxElements: 300))
        #expect(limit > AgentClient.defaultTimeout + AgentClient.defaultTimeout)
        #expect(limit == AgentClient.defaultTimeout + AgentClient.defaultTimeout + AgentControlClient.ownerMargin)
        #expect(limit == AgentControlClient.timeout(for: .uiTree(maxElements: 1)))
    }

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

    // MARK: - Clipboard text

    /// An agent never gets the owner's `setClipboard` (password copy, concealed, auto-clear),
    /// even on a helper that has the plain clipboard ops.
    @Test func ownerClipboardStillRefusedToAgents() async throws {
        let env = try Env(helperVersion: "1.0.8")
        defer { env.cleanup() }
        let server = try env.start()
        defer { server.stop() }

        let raw = try RawConnection(env.socketURL, vmID: env.config.id, bundle: env.bundle.url)
        let answer = try await blocking {
            try raw.send(.setClipboard(text: "secret-value", clearAfter: 60))
            return try raw.readAnswer()
        }
        #expect(answer?.ok == false)
        #expect(answer?.error == .badRequest)
        #expect(answer?.message == L10n.string("only Nido can use the VM’s clipboard"))
        #expect(env.helper.requests.isEmpty)
    }

    @Test func readClipboardForwardsText() async throws {
        let env = try Env(helperVersion: "1.0.8")
        defer { env.cleanup() }
        env.helper.clipboardReply = AgentReply(ok: true, truncated: true, clipboard: FakeHelper.clipboardText)
        let server = try env.start()
        defer { server.stop() }

        let client = env.client()
        let answer = try await blocking { try client.send(.readClipboard) }
        #expect(answer.ok)
        // Newlines and tabs stay; every other control and format character is gone.
        #expect(answer.clipboard == "line one\n\tindented[31m red\nlinethree")
        #expect(answer.truncated == true)
        #expect(env.helper.requests.map(\.action) == [.status, .readClipboard])
    }

    @Test func readClipboardRefusalIsForwarded() async throws {
        let env = try Env(helperVersion: "1.0.8")
        defer { env.cleanup() }
        env.helper.clipboardReply = AgentReply(
            ok: false, error: .badRequest, message: "the clipboard holds a concealed item: its text is not shown")
        let server = try env.start()
        defer { server.stop() }

        let client = env.client()
        let answer = try await blocking { try client.send(.readClipboard) }
        #expect(!answer.ok)
        #expect(answer.error == .badRequest)
        #expect(answer.clipboard == nil)
        #expect(answer.message == "the clipboard holds a concealed item: its text is not shown")
    }

    @Test func writeClipboardForwards() async throws {
        let env = try Env(helperVersion: "1.0.8")
        defer { env.cleanup() }
        let server = try env.start()
        defer { server.stop() }

        let client = env.client()
        let answer = try await blocking { try client.send(.writeClipboard(text: "hello\nworld")) }
        #expect(answer.ok)
        #expect(env.helper.requests.map(\.action) == [.status, .writeClipboard(text: "hello\nworld")])
    }

    @Test func clipboardOnOldHelper() async throws {
        let env = try Env(helperVersion: "1.0.7")
        defer { env.cleanup() }
        let server = try env.start()
        defer { server.stop() }

        let client = env.client()
        let (read, write) = try await blocking {
            (try client.send(.readClipboard), try client.send(.writeClipboard(text: "x")))
        }
        let expected = L10n.string(
            "Nido Agent is too old for the clipboard: run nido agent setup \(env.config.name.rawValue) to update it")
        for answer in [read, write] {
            #expect(!answer.ok)
            #expect(answer.error == .versionMismatch)
            #expect(answer.message == expected)
        }
        #expect(env.helper.requests.allSatisfy { $0.action == .status })
    }

    @Test func minimumHelperVersionForTheClipboard() {
        #expect(AgentGate.minimumHelperVersion(for: .readClipboard) == "1.0.8")
        #expect(AgentGate.minimumHelperVersion(for: .writeClipboard(text: "a")) == "1.0.8")
        #expect(AgentGate.minimumHelperVersion(for: .setClipboard(text: "a", clearAfter: 1)) == nil)
    }

    @Test func readClipboardNeverLogsText() async throws {
        let env = try Env(helperVersion: "1.0.8")
        defer { env.cleanup() }
        let secret = "hunter2-on-the-clipboard"
        env.helper.clipboardReply = AgentReply(ok: true, clipboard: secret)
        let server = try env.start()
        defer { server.stop() }

        let client = env.client("mcp")
        let answer = try await blocking { try client.send(.readClipboard) }
        #expect(answer.clipboard == secret)
        let entry = try #require(env.log(server).last)
        #expect(entry.op == "readClipboard")
        #expect(entry.detail == ["chars": String(secret.count)])
        #expect(Self.bundleBytes(env).range(of: Data(secret.utf8)) == nil)
    }

    @Test func writeClipboardNeverLogsText() async throws {
        let env = try Env(helperVersion: "1.0.8")
        defer { env.cleanup() }
        let secret = "hunter2-to-the-clipboard"
        let server = try env.start()
        defer { server.stop() }

        let client = env.client("mcp")
        _ = try await blocking { try client.send(.writeClipboard(text: secret)) }
        let entry = try #require(env.log(server).last)
        #expect(entry.op == "writeClipboard")
        #expect(entry.detail == ["chars": String(secret.count)])
        #expect(Self.bundleBytes(env).range(of: Data(secret.utf8)) == nil)
    }

    /// Every byte of every file in the VM's bundle (the activity log among them).
    private static func bundleBytes(_ env: Env) -> Data {
        var all = Data()
        let walker = FileManager.default.enumerator(at: env.bundle.url, includingPropertiesForKeys: [.isRegularFileKey])
        while let url = walker?.nextObject() as? URL {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            all.append((try? Data(contentsOf: url)) ?? Data())
        }
        return all
    }

    /// A 1 MiB clipboard of a character JSON escapes (`/` becomes `\/`) crosses the socket in
    /// both directions.
    @Test func aMebibyteClipboardRoundTrips() async throws {
        let env = try Env(helperVersion: "1.0.8")
        defer { env.cleanup() }
        let big = String(repeating: "/", count: AgentProtocol.maxClipboardBytes)
        env.helper.clipboardReply = AgentReply(ok: true, clipboard: big)
        let server = try env.start()
        defer { server.stop() }

        let client = env.client()
        let (read, write) = try await blocking {
            (try client.send(.readClipboard), try client.send(.writeClipboard(text: big)))
        }
        #expect(read.ok)
        #expect(read.clipboard == big)
        #expect(write.ok)
        #expect(env.helper.requests.last?.action == .writeClipboard(text: big))
    }

    /// A line over 64 KiB that is not a clipboard write is refused as soon as its first 64 KiB
    /// are in, never buffered up to the clipboard's limit nor decoded.
    @Test func oversizeNonClipboardLinesAreRefusedEarly() async throws {
        let env = try Env(helperVersion: "1.0.8")
        defer { env.cleanup() }
        let server = try env.start()
        defer { server.stop() }

        for size in [AgentControlServer.maxLineBytes + 1, 5 * 1024 * 1024] {
            let raw = try RawConnection(env.socketURL, vmID: env.config.id, bundle: env.bundle.url)
            let answer = try await blocking {
                try raw.send(.type(text: String(repeating: "a", count: size)))
                return try raw.readAnswer()
            }
            #expect(answer?.ok == false)
            #expect(answer?.message == L10n.string("command longer than 64 KiB"))
        }
        #expect(env.helper.requests.isEmpty)
    }

    @Test func cleanedClipboardKeepsNewlines() {
        let answer = AgentAnswer(ok: true, clipboard: "a\r\nb\tc\u{1B}d\u{9B}e\u{200B}f\n\ng ").cleaned
        #expect(answer.clipboard == "a\nb\tcdef\n\ng ")
        // Bidi overrides are format characters; Unicode line and paragraph separators become lines.
        let unicode = AgentAnswer(ok: true, clipboard: "a\u{202E}b\u{2028}c\u{2029}d").cleaned
        #expect(unicode.clipboard == "ab\nc\nd")
        let long = String(repeating: "é\n", count: 5000)
        #expect(AgentAnswer(ok: true, clipboard: long).cleaned.clipboard == long)
    }

    /// A compromised guest may send more than the limit: the Mac cuts it at a character boundary.
    @Test func cleanedClipboardIsCutAtTheLimit() {
        let limit = AgentProtocol.maxClipboardBytes
        let over = AgentAnswer(ok: true, truncated: false,
                               clipboard: String(repeating: "a", count: limit - 1) + "é" + "tail").cleaned
        #expect(over.clipboard?.utf8.count == limit - 1)
        #expect(over.truncated == true)
        let exact = AgentAnswer(ok: true, truncated: false, clipboard: String(repeating: "a", count: limit)).cleaned
        #expect(exact.clipboard?.utf8.count == limit)
        #expect(exact.truncated == false)
        // The guest's own cut is kept.
        #expect(AgentAnswer(ok: true, truncated: true, clipboard: "abc").cleaned.truncated == true)
    }

    /// The checkpoint ops are the owner's own: never forwarded to Nido Agent, refused when the
    /// owner hands the gate no checkpoint handling, and logged like any other command.
    @Test func checkpointOpsWithoutHandlingAreRefused() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let server = try env.start()
        defer { server.stop() }

        let raw = try RawConnection(env.socketURL, vmID: env.config.id, bundle: env.bundle.url)
        let answers = try await blocking {
            var answers: [AgentAnswer?] = []
            for action in [AgentAction.checkpoint(name: nil), .rollback(name: "a1"), .checkpoints] {
                try raw.send(action)
                answers.append(try raw.readAnswer())
            }
            return answers
        }
        for answer in answers {
            #expect(answer?.ok == false)
            #expect(answer?.error == .badRequest)
            #expect(answer?.message == L10n.string("this VM’s owner can’t take checkpoints"))
        }
        #expect(L10n.string("this VM’s owner can’t take checkpoints", language: "en")
            == "this VM’s owner can’t take checkpoints")
        #expect(env.helper.requests.isEmpty)
        let log = env.log(server)
        #expect(log.map(\.op) == ["checkpoint", "rollback", "checkpoints"])
        #expect(log.map(\.error) == ["badRequest", "badRequest", "badRequest"])
        #expect(log.map(\.detail) == [[:], ["name": "a1"], [:]])
    }

    /// With the owner's handling, each op reaches it (never the helper) and its answer goes back
    /// as it is; each op leaves one entry, a checkpoint and a rollback naming their checkpoint.
    @Test func checkpointOpsReachTheOwnersHandling() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let handling = FakeCheckpoints()
        let server = try env.start(checkpoints: handling)
        defer { server.stop() }

        let client = env.client()
        let answers = try await blocking {
            [
                try client.send(.checkpoint(name: nil)),
                try client.send(.checkpoint(name: "before-brew")),
                try client.send(.checkpoints),
                try client.send(.rollback(name: nil)),
                try client.send(.rollback(name: "nope")),
            ]
        }
        #expect(handling.calls == ["checkpoint nil", "checkpoint before-brew", "checkpoints", "rollback nil", "rollback nope"])
        #expect(env.helper.requests.isEmpty)
        #expect(answers.map(\.ok) == [true, true, true, true, false])
        #expect(answers[0].checkpoint?.name == FakeCheckpoints.defaultName)
        #expect(answers[0].message == "checkpoint \(FakeCheckpoints.defaultName) saved")
        #expect(answers[2].checkpoints == FakeCheckpoints.list)
        #expect(answers[4].error == .badRequest)

        let log = env.log(server)
        #expect(log.map(\.op) == ["checkpoint", "checkpoint", "checkpoints", "rollback", "rollback"])
        #expect(log.map(\.ok) == [true, true, true, true, false])
        // The name the owner gave (or the one asked); the target a rollback goes back to.
        #expect(log.map(\.detail) == [
            ["name": FakeCheckpoints.defaultName], ["name": "before-brew"], [:], ["name": "newest"], ["name": "nope"],
        ])
        #expect(log[4].message == "no agent checkpoint named nope")
    }

    /// Agent access off: refused first, the connection closed, the owner's handling never asked.
    @Test func checkpointOpsNeedAgentAccess() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let handling = FakeCheckpoints()
        let server = try env.start(checkpoints: handling)
        defer { server.stop() }
        try env.bundle.updateConfig { $0.agentAccess = false }

        for action in [AgentAction.checkpoint(name: "x"), .rollback(name: nil), .checkpoints] {
            let raw = try RawConnection(env.socketURL, vmID: env.config.id, bundle: env.bundle.url)
            let (answer, closed) = try await blocking {
                try raw.send(action)
                return (try raw.readAnswer(), raw.readLine() == nil)
            }
            #expect(answer?.error == .agentAccessOff, "\(action)")
            #expect(closed, "\(action)")
        }
        #expect(handling.calls.isEmpty)
        #expect(env.helper.requests.isEmpty)
    }

    /// A checkpoint saves the VM's memory: the client waits up to 120 s for it, the other two ops
    /// the default.
    @Test func clientTimeoutForCheckpoints() {
        #expect(AgentControlClient.timeout(for: .checkpoint(name: nil)) == .seconds(120))
        #expect(AgentControlClient.timeout(for: .checkpoint(name: "x")) == .seconds(120))
        #expect(AgentControlClient.timeout(for: .rollback(name: nil)) == AgentControlClient.timeout(for: .status))
        #expect(AgentControlClient.timeout(for: .checkpoints) == AgentControlClient.timeout(for: .status))
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

    @Test func carriesPointIncludesZoom() {
        #expect(AgentGate.carriesPoint(.zoom(x: 1, y: 2, width: 3, height: 4, maxLongEdge: 800)))
    }

    @Test func zoomBeforeScreenshot() async throws {
        let env = try Env(helperVersion: "1.0.4")
        defer { env.cleanup() }
        let server = try env.start()
        defer { server.stop() }

        let client = env.client()
        let answer = try await blocking { try client.send(.zoom(x: 0, y: 0, width: 10, height: 10, maxLongEdge: 800)) }
        #expect(!answer.ok)
        #expect(answer.error == .noScreenshot)
        #expect(answer.message == L10n.string("take a screenshot first: coordinates refer to the last screenshot"))
        #expect(env.helper.requests.isEmpty)
    }

    @Test func zoomKeepsLastShot() async throws {
        let env = try Env(helperVersion: "1.0.4")
        defer { env.cleanup() }
        let server = try env.start()
        defer { server.stop() }

        let client = env.client()
        let answers = try await blocking {
            [
                try client.send(.screenshot(maxLongEdge: 1280)),
                try client.send(.zoom(x: 10, y: 20, width: 300, height: 200, maxLongEdge: 800)),
                try client.send(.click(x: 5, y: 6, button: .left, count: 1)),
            ]
        }
        #expect(answers.map(\.ok) == [true, true, true])
        #expect(answers[1].image == FakeHelper.zoomImage)
        let requests = env.helper.requests.filter { if case .status = $0.action { false } else { true } }
        try #require(requests.count == 3)
        #expect(requests[1].action == .zoom(x: 10, y: 20, width: 300, height: 200, maxLongEdge: 800))
        #expect(requests[1].image == FakeHelper.image)
        #expect(requests[1].screen == FakeHelper.screen)
        #expect(requests[2].image == FakeHelper.image)
        #expect(requests[2].screen == FakeHelper.screen)
    }

    @Test func zoomSavesPNG() async throws {
        let env = try Env(helperVersion: "1.0.4")
        defer { env.cleanup() }
        let server = try env.start()
        defer { server.stop() }

        let client = env.client()
        let answer = try await blocking {
            _ = try client.send(.screenshot(maxLongEdge: 1280))
            return try client.send(.zoom(x: 0, y: 0, width: 50, height: 50, maxLongEdge: 800))
        }
        let path = try #require(answer.path)
        #expect(answer.screen == FakeHelper.screen)
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == FakeHelper.png)
        #expect(URL(fileURLWithPath: path).deletingLastPathComponent().standardizedFileURL
            == env.bundle.agentShotsURL.standardizedFileURL)
    }

    @Test func minimumHelperVersions() {
        #expect(AgentGate.minimumHelperVersion(for: .zoom(x: 0, y: 0, width: 1, height: 1, maxLongEdge: 800)) == "1.0.4")
        #expect(AgentGate.minimumHelperVersion(for: .uiTree(maxElements: 300)) == "1.0.5")
        #expect(AgentGate.minimumHelperVersion(for: .click(x: 1, y: 2, button: .left, count: 1)) == nil)
        #expect(AgentGate.minimumHelperVersion(for: .status) == nil)
        #expect(AgentGate.minimumHelperVersion(for: .putFile(path: "a", size: 1)) == "1.0.6")
        #expect(AgentGate.minimumHelperVersion(for: .getFile(path: "a", maxBytes: 1)) == "1.0.6")
        #expect(AgentGate.minimumHelperVersion(for: .listFiles(path: nil)) == "1.0.6")
    }

    @Test func uiTreeBeforeScreenshot() async throws {
        let env = try Env(helperVersion: "1.0.5")
        defer { env.cleanup() }
        let server = try env.start()
        defer { server.stop() }

        let client = env.client()
        let answer = try await blocking { try client.send(.uiTree(maxElements: 300)) }
        #expect(!answer.ok)
        #expect(answer.error == .noScreenshot)
        #expect(env.helper.requests.isEmpty)
    }

    @Test func uiTreeOnOldHelper() async throws {
        let env = try Env(helperVersion: "1.0.4")
        defer { env.cleanup() }
        let server = try env.start()
        defer { server.stop() }

        let client = env.client()
        let answer = try await blocking {
            _ = try client.send(.screenshot(maxLongEdge: 1280))
            return try client.send(.uiTree(maxElements: 300))
        }
        #expect(answer.error == .versionMismatch)
        #expect(answer.message == L10n.string("Nido Agent is too old for ui_tree: run nido agent setup \(env.config.name.rawValue) to update it"))
        #expect(!env.helper.requests.contains { if case .uiTree = $0.action { true } else { false } })
    }

    // MARK: - read_text

    private static func zooms(_ helper: FakeHelper) -> [AgentRequest] {
        helper.requests.filter { if case .zoom = $0.action { true } else { false } }
    }

    private static let hello = RecognizedText(text: "Hello", box: CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5))

    @Test func readTextSendsAZoom() async throws {
        let env = try Env(helperVersion: "1.0.7")
        defer { env.cleanup() }
        let server = try env.start(recognizer: FakeRecognizer([Self.hello]))
        defer { server.stop() }

        let client = env.client()
        _ = try await blocking {
            _ = try client.send(.screenshot(maxLongEdge: 1280))
            return try client.readText(region: nil, maxLines: 300)
        }
        let zoom = try #require(Self.zooms(env.helper).first)
        #expect(zoom.action == .zoom(x: 0, y: 0, width: 1280, height: 800, maxLongEdge: 4096))
        #expect(zoom.image == FakeHelper.image)
        #expect(zoom.screen == FakeHelper.screen)
        // The guest never learns of a new op.
        #expect(env.helper.requests.allSatisfy {
            switch $0.action {
            case .status, .screenshot, .zoom: true
            default: false
            }
        })
    }

    @Test func readTextAnswersMappedLines() async throws {
        let env = try Env(helperVersion: "1.0.7")
        defer { env.cleanup() }
        let recognizer = FakeRecognizer([Self.hello])
        let server = try env.start(recognizer: recognizer)
        defer { server.stop() }

        let client = env.client()
        let answers = try await blocking {
            _ = try client.send(.screenshot(maxLongEdge: 1280))
            recognizer.found = [Self.hello, RecognizedText(text: "World", box: CGRect(x: 0, y: 0, width: 0.5, height: 0.5))]
            return [
                try client.readText(region: nil, maxLines: 300),
                try client.readText(region: nil, maxLines: 1),
                try client.readText(region: PixelRect(x: 1200, y: 700, w: 500, h: 500), maxLines: 300),
            ]
        }
        #expect(answers[0].ok)
        #expect(answers[0].lines == [
            TextLine(text: "Hello", frame: PixelRect(x: 0, y: 0, w: 640, h: 400)),
            TextLine(text: "World", frame: PixelRect(x: 0, y: 400, w: 640, h: 400)),
        ])
        #expect(answers[0].truncated == false)
        // Text only: no capture is handed to the client.
        #expect(answers[0].path == nil)
        #expect(answers[1].lines?.count == 1)
        #expect(answers[1].truncated == true)
        // A partial region is clamped to the screenshot, like a zoom; frames are in screenshot pixels.
        let zooms = Self.zooms(env.helper)
        #expect(zooms[2].action == .zoom(x: 1200, y: 700, width: 80, height: 100, maxLongEdge: 4096))
        #expect(answers[2].lines?.first == TextLine(text: "Hello", frame: PixelRect(x: 1200, y: 700, w: 40, h: 50)))
        #expect(recognizer.pngs.allSatisfy { $0 == FakeHelper.png })
    }

    @Test func readTextOutsideTheScreenshotIsRefused() async throws {
        let env = try Env(helperVersion: "1.0.7")
        defer { env.cleanup() }
        let server = try env.start(recognizer: FakeRecognizer([Self.hello]))
        defer { server.stop() }

        let client = env.client()
        let answer = try await blocking {
            _ = try client.send(.screenshot(maxLongEdge: 1280))
            return try client.readText(region: PixelRect(x: 5000, y: 5000, w: 10, h: 10), maxLines: 300)
        }
        #expect(answer.error == .badRequest)
        #expect(Self.zooms(env.helper).isEmpty)
    }

    @Test func screenChangedIsReported() async throws {
        let env = try Env(helperVersion: "1.0.7")
        defer { env.cleanup() }
        let recognizer = FakeRecognizer([Self.hello])
        let server = try env.start(recognizer: recognizer)
        defer { server.stop() }

        let client = env.client()
        let helper = env.helper
        let answer = try await blocking {
            _ = try client.send(.screenshot(maxLongEdge: 1280))
            helper.zoomReply = AgentReply(ok: false, error: .screenChanged, message: "the screen changed")
            return try client.readText(region: nil, maxLines: 300)
        }
        #expect(answer.error == .screenChanged)
        #expect(answer.lines == nil)
        #expect(recognizer.pngs.isEmpty)
    }

    /// "No text found" is a successful answer with no lines, never a version mismatch.
    @Test func noTextIsAnEmptyOkAnswer() async throws {
        let env = try Env(helperVersion: "1.0.7")
        defer { env.cleanup() }
        let server = try env.start(recognizer: FakeRecognizer([]))
        defer { server.stop() }

        let client = env.client()
        let answer = try await blocking {
            _ = try client.send(.screenshot(maxLongEdge: 1280))
            return try client.readText(region: nil, maxLines: 300)
        }
        #expect(answer.ok)
        #expect(answer.error == nil)
        #expect(answer.lines == [])
    }

    @Test func noScreenshotFirst() async throws {
        let env = try Env(helperVersion: "1.0.7")
        defer { env.cleanup() }
        let server = try env.start(recognizer: FakeRecognizer([Self.hello]))
        defer { server.stop() }

        let client = env.client()
        let answer = try await blocking { try client.readText(region: nil, maxLines: 300) }
        #expect(answer.error == .noScreenshot)
        #expect(env.helper.requests.isEmpty)
    }

    @Test func recognizerFailureIsAnError() async throws {
        let env = try Env(helperVersion: "1.0.7")
        defer { env.cleanup() }
        let server = try env.start(recognizer: FakeRecognizer(failure: true))
        defer { server.stop() }

        let client = env.client()
        let answer = try await blocking {
            _ = try client.send(.screenshot(maxLongEdge: 1280))
            return try client.readText(region: nil, maxLines: 300)
        }
        #expect(answer.ok == false)
        #expect(answer.error == .internalError)
    }

    @Test func oldHelperNamesReadText() async throws {
        let env = try Env(helperVersion: "1.0.3")
        defer { env.cleanup() }
        let recognizer = FakeRecognizer([Self.hello])
        let server = try env.start(recognizer: recognizer)
        defer { server.stop() }

        let client = env.client()
        let answer = try await blocking {
            _ = try client.send(.screenshot(maxLongEdge: 1280))
            return try client.readText(region: nil, maxLines: 300)
        }
        #expect(answer.error == .versionMismatch)
        #expect(answer.message == L10n.string("Nido Agent is too old for read_text: run nido agent setup \(env.config.name.rawValue) to update it"))
        #expect(Self.zooms(env.helper).isEmpty)
        #expect(recognizer.pngs.isEmpty)
    }

    @Test func readTextIsLoggedWithoutText() async throws {
        let env = try Env(helperVersion: "1.0.7")
        defer { env.cleanup() }
        let secret = "hunter2-on-screen"
        let server = try env.start(recognizer: FakeRecognizer([RecognizedText(text: secret, box: Self.hello.box)]))
        defer { server.stop() }

        let client = env.client("mcp")
        let answer = try await blocking {
            _ = try client.send(.screenshot(maxLongEdge: 1280))
            return try client.readText(region: PixelRect(x: 10, y: 20, w: 300, h: 200), maxLines: 300)
        }
        #expect(answer.lines?.first?.text == secret)
        let log = env.log(server)
        let entry = try #require(log.last)
        #expect(entry.op == "readText")
        #expect(entry.detail == ["region": "10,20,300,200", "lines": "1"])
        #expect(entry.ok)
        let thumb = try #require(entry.thumb)
        #expect(FileManager.default.fileExists(atPath: AgentActivityLog.thumbnailURL(thumb, in: env.bundle).path))
        let raw = try JSONEncoder().encode(log)
        #expect(!String(decoding: raw, as: UTF8.self).contains(secret))
    }

    @Test func linesAreCleaned() async throws {
        let dirty = "a\u{1B}[31mb\nc\u{9B}d" + String(repeating: "x", count: 400)
        let env = try Env(helperVersion: "1.0.7")
        defer { env.cleanup() }
        let server = try env.start(recognizer: FakeRecognizer([RecognizedText(text: dirty, box: Self.hello.box)]))
        defer { server.stop() }

        let client = env.client()
        let answer = try await blocking {
            _ = try client.send(.screenshot(maxLongEdge: 1280))
            return try client.readText(region: nil, maxLines: 300)
        }
        let text = try #require(answer.lines?.first?.text)
        #expect(!text.contains("\u{1B}") && !text.contains("\n") && !text.contains("\u{9B}"))
        #expect(text.count <= 200)
    }

    /// An owner started before read text existed ignores the unknown key and answers a plain status.
    @Test func readTextOnAnOwnerTooOld() async throws {
        let env = try Env()
        defer { env.cleanup() }
        try AgentControlServer.prepareDirectory(env.root)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        try #require(fd >= 0)
        defer { close(fd) }
        var address = try AgentControlServer.socketAddress(env.socketURL)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        try #require(bound == 0 && listen(fd, 1) == 0)
        let status = FakeHelper().status
        Thread {
            let conn = accept(fd, nil, nil)
            guard conn >= 0 else { return }
            defer { close(conn) }
            var byte: UInt8 = 0
            while read(conn, &byte, 1) == 1, byte != 0x0A {}
            var line = (try? JSONEncoder().encode(AgentAnswer(ok: true, status: status))) ?? Data()
            line.append(0x0A)
            _ = line.withUnsafeBytes { write(conn, $0.baseAddress, $0.count) }
        }.start()

        let client = env.client()
        let answer = try await blocking { try client.readText(region: nil, maxLines: 300) }
        #expect(answer.ok == false)
        #expect(answer.error == .versionMismatch)
        #expect(answer.message == L10n.string("The VM was started by an older Nido that can’t read text: restart \(env.config.name.rawValue) with this version"))
    }

    @Test func readTextRegionNearIntMaxIsRefusedNotACrash() async throws {
        let env = try Env(helperVersion: "1.0.7")
        defer { env.cleanup() }
        let server = try env.start(recognizer: FakeRecognizer([Self.hello]))
        defer { server.stop() }

        let client = env.client()
        let answers = try await blocking {
            _ = try client.send(.screenshot(maxLongEdge: 1280))
            return [
                try client.readText(region: PixelRect(x: Int.max, y: 0, w: 1, h: 1), maxLines: 300),
                try client.readText(region: PixelRect(x: 0, y: Int.max, w: 1, h: 1), maxLines: 300),
                try client.readText(region: PixelRect(x: 5, y: 5, w: Int.max, h: Int.max), maxLines: 300),
            ]
        }
        #expect(answers[0].error == .badRequest)
        #expect(answers[1].error == .badRequest)
        // A huge size from a valid origin is cut to the screenshot, like a zoom.
        #expect(answers[2].ok)
        // The owner is alive.
        let status = try await blocking { try client.send(.status) }
        #expect(status.ok)
    }

    @Test func readTextOnAnotherActionIsRefused() throws {
        let env = try Env(helperVersion: "1.0.7")
        defer { env.cleanup() }
        let server = try env.start(recognizer: FakeRecognizer([Self.hello]))
        defer { server.stop() }

        let conn = try RawConnection(env.socketURL, vmID: env.config.id, bundle: env.bundle.url)
        let command = AgentCommand(
            vmID: env.config.id, bundlePath: AgentCommand.bundlePath(env.bundle.url), action: .key(combo: "a"),
            client: nil, session: nil, staged: nil, readText: ReadTextRequest(region: nil, maxLines: 5))
        var line = try JSONEncoder().encode(command)
        line.append(0x0A)
        conn.write(line)
        let answer = try #require(try conn.readAnswer())
        #expect(answer.error == .badRequest)
        #expect(env.helper.requests.isEmpty)
    }

    @Test func recognizerWarmsUpWhenTheServerStarts() async throws {
        let env = try Env(helperVersion: "1.0.7")
        defer { env.cleanup() }
        let recognizer = FakeRecognizer([Self.hello])
        let server = try env.startWarming(recognizer: recognizer)
        defer { server.stop() }

        for _ in 0..<200 where recognizer.pngs.isEmpty { try await Task.sleep(for: .milliseconds(25)) }
        #expect(recognizer.pngs.count == 1)
        #expect(recognizer.pngs.first?.starts(with: [0x89, 0x50, 0x4E, 0x47]) == true)

        // A read does not warm up again.
        let client = env.client()
        _ = try await blocking {
            _ = try client.send(.screenshot(maxLongEdge: 1280))
            return try client.readText(region: nil, maxLines: 300)
        }
        #expect(recognizer.pngs.count == 2)
    }

    @Test func readTextAwaitsTheWarmUpInsteadOfLoadingTwice() async throws {
        let env = try Env(helperVersion: "1.0.7")
        defer { env.cleanup() }
        let recognizer = FakeRecognizer([Self.hello])
        recognizer.warmUpHold = true
        let server = try env.startWarming(recognizer: recognizer)
        defer { server.stop() }
        for _ in 0..<200 where recognizer.pngs.isEmpty { try await Task.sleep(for: .milliseconds(25)) }
        #expect(recognizer.pngs.count == 1)

        let client = env.client()
        async let answer = blocking {
            _ = try client.send(.screenshot(maxLongEdge: 1280))
            return try client.readText(region: nil, maxLines: 300)
        }
        // While the warm-up holds, the read has not reached the recognizer; other commands answer.
        try await Task.sleep(for: .milliseconds(400))
        #expect(recognizer.pngs.count == 1)
        recognizer.release()
        let result = try await answer
        #expect(result.ok)
        #expect(recognizer.pngs.count == 2)
    }

    /// The first call after the owner starts can take longer than any plain timeout: a timeout on
    /// read_text says so, with a way forward.
    @Test func readTextTimeoutSaysRecognitionIsStarting() async throws {
        let env = try Env()
        defer { env.cleanup() }
        try AgentControlServer.prepareDirectory(env.root)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        try #require(fd >= 0)
        defer { close(fd) }
        var address = try AgentControlServer.socketAddress(env.socketURL)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        try #require(bound == 0 && listen(fd, 1) == 0)
        Thread {
            let conn = accept(fd, nil, nil)
            guard conn >= 0 else { return }
            Thread.sleep(forTimeInterval: 2)
            close(conn)
        }.start()

        let client = env.client()
        let answer = try await blocking { try client.readText(region: nil, maxLines: 300, timeout: .milliseconds(300)) }
        #expect(answer.ok == false)
        #expect(answer.error == .timeout)
        #expect(answer.message == L10n.string("Text recognition is still starting on this Mac: try read_text again in a minute"))
        #expect(AgentControlClient.readTextTimeout >= AgentControlClient.timeout(for: .zoom(x: 0, y: 0, width: 1, height: 1, maxLongEdge: 1)) + .seconds(150))
    }

    // MARK: - Files

    private static func stagedFiles(_ env: Env) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: env.bundle.agentFilesURL.path)) ?? []
    }

    private static func fileRequests(_ helper: FakeHelper) -> [AgentRequest] {
        helper.requests.filter {
            switch $0.action {
            case .putFile, .getFile, .listFiles: true
            default: false
            }
        }
    }

    @Test func clientTimeoutForTransfers() {
        let transfer = AgentClient.defaultTimeout + AgentClient.defaultImageTimeout + AgentControlClient.ownerMargin
        #expect(AgentControlClient.timeout(for: .putFile(path: "a", size: 1)) == transfer)
        #expect(AgentControlClient.timeout(for: .getFile(path: "a", maxBytes: 1)) == transfer)
        #expect(AgentControlClient.timeout(for: .listFiles(path: nil))
            == AgentClient.defaultTimeout + AgentClient.defaultTimeout + AgentControlClient.ownerMargin)
    }

    /// A helper older than 1.0.6 would answer "unknown action": the owner asks its version first
    /// and never sends the op.
    @Test func oldHelperRefused() async throws {
        let env = try Env(helperVersion: "1.0.5")
        defer { env.cleanup() }
        let server = try env.start()
        defer { server.stop() }

        let client = env.client()
        let (put, get, list) = try await blocking {
            (try client.putFile(Data("hello".utf8), to: "a.txt"),
             try client.getFile("a.txt", maxBytes: 1 << 20),
             try client.send(.listFiles(path: nil)))
        }
        let expected = L10n.string(
            "Nido Agent is too old for files: run nido agent setup \(env.config.name.rawValue) to update it")
        for answer in [put, get.0, list] {
            #expect(!answer.ok)
            #expect(answer.error == .versionMismatch)
            #expect(answer.message == expected)
        }
        #expect(get.1 == nil)
        #expect(Self.fileRequests(env.helper).isEmpty)
        #expect(env.helper.requests.allSatisfy { $0.action == .status })
        #expect(Self.stagedFiles(env).isEmpty)
    }

    /// A forged client names a file outside the staging folder, or one that is not ours: refused
    /// before anything reaches the helper, the status check included.
    @Test func stagedNameRefused() async throws {
        let env = try Env(helperVersion: "1.0.6")
        defer { env.cleanup() }
        let server = try env.start()
        defer { server.stop() }

        let outside = env.tmp.appendingPathComponent("config.json")
        try Data("secret".utf8).write(to: outside)
        _ = try AgentFiles.stage(Data(), in: env.bundle)
        let linked = UUID().uuidString.lowercased() + ".bin"
        #expect(symlink(outside.path, env.bundle.agentFilesURL.appendingPathComponent(linked).path) == 0)
        let missing = UUID().uuidString.lowercased() + ".bin"

        let raw = try RawConnection(env.socketURL, vmID: env.config.id, bundle: env.bundle.url)
        let staged: [String?] = [nil, "../x", "/tmp/x", "x.bin", outside.path, "../config.json", linked, missing]
        let answers = try await blocking { () -> [AgentAnswer?] in
            try staged.map { name in
                try raw.send(.putFile(path: "a.txt", size: 6), staged: name)
                return try raw.readAnswer()
            }
        }
        #expect(answers.count == staged.count)
        for answer in answers {
            #expect(answer?.ok == false)
            #expect(answer?.error == .badRequest)
            #expect(answer?.message == L10n.string("the staged file is missing or invalid"))
        }
        #expect(env.helper.requests.isEmpty)
        #expect(try Data(contentsOf: outside) == Data("secret".utf8))
    }

    /// A staged file whose size is not the one the command says is never sent.
    @Test func stagedSizeMismatchRefused() async throws {
        let env = try Env(helperVersion: "1.0.6")
        defer { env.cleanup() }
        let server = try env.start()
        defer { server.stop() }

        let name = try AgentFiles.stage(Data("12345".utf8), in: env.bundle)
        let raw = try RawConnection(env.socketURL, vmID: env.config.id, bundle: env.bundle.url)
        let answer = try await blocking { () -> AgentAnswer? in
            try raw.send(.putFile(path: "a.txt", size: 4), staged: name)
            return try raw.readAnswer()
        }
        #expect(answer?.error == .badRequest)
        #expect(env.helper.requests.isEmpty)
        #expect(Self.stagedFiles(env).isEmpty)
    }

    @Test func putFileForwardsBytes() async throws {
        let env = try Env(helperVersion: "1.0.6")
        defer { env.cleanup() }
        let server = try env.start()
        defer { server.stop() }

        let bytes = Data((0..<70_000).map { UInt8($0 % 256) })  // more than a control line holds
        let client = env.client()
        let answer = try await blocking { try client.putFile(bytes, to: "in/data.bin") }
        #expect(answer.ok)
        #expect(answer.bytes == bytes.count)
        let puts = Self.fileRequests(env.helper)
        try #require(puts.count == 1)
        #expect(puts[0].action == .putFile(path: "in/data.bin", size: bytes.count))
        #expect(puts[0].payload == bytes)
        #expect(Self.stagedFiles(env).isEmpty)
    }

    @Test func putFileOverTheLimitIsRefusedByTheClient() async throws {
        let env = try Env(helperVersion: "1.0.6")
        defer { env.cleanup() }
        let server = try env.start()
        defer { server.stop() }

        let client = env.client()
        let answer = try await blocking { try client.putFile(Data(count: AgentProtocol.maxTransferBytes + 1), to: "big") }
        #expect(answer.error == .badRequest)
        #expect(answer.message == L10n.string("the file is larger than 16 MiB"))
        #expect(env.helper.requests.isEmpty)
        #expect(Self.stagedFiles(env).isEmpty)
    }

    /// Agent access off: refused before the staged file is read; the client removes it.
    @Test func putFileNeedsAgentAccess() async throws {
        let env = try Env(helperVersion: "1.0.6")
        defer { env.cleanup() }
        let server = try env.start()
        defer { server.stop() }
        try env.bundle.updateConfig { $0.agentAccess = false }

        let client = env.client()
        let answer = try await blocking { try client.putFile(Data("x".utf8), to: "a") }
        #expect(answer.error == .agentAccessOff)
        #expect(env.helper.requests.isEmpty)
        #expect(Self.stagedFiles(env).isEmpty)
    }

    @Test func getFileStagesReply() async throws {
        let env = try Env(helperVersion: "1.0.6")
        defer { env.cleanup() }
        let server = try env.start()
        defer { server.stop() }

        let raw = try RawConnection(env.socketURL, vmID: env.config.id, bundle: env.bundle.url)
        let answer = try await blocking { () -> AgentAnswer? in
            try raw.send(.getFile(path: "out.bin", maxBytes: 1 << 20))
            return try raw.readAnswer()
        }
        let staged = try #require(answer?.staged)
        #expect(answer?.ok == true)
        #expect(answer?.bytes == FakeHelper.fileBytes.count)
        #expect(AgentFiles.isStagedName(staged))
        #expect(try Data(contentsOf: env.bundle.agentFilesURL.appendingPathComponent(staged)) == FakeHelper.fileBytes)
        let gets = Self.fileRequests(env.helper)
        #expect(gets.map(\.action) == [.getFile(path: "out.bin", maxBytes: 1 << 20)])
        #expect(gets.first?.payload == nil)

        // The client reads the staged file and deletes it.
        let client = env.client()
        let (got, data) = try await blocking { try client.getFile("out.bin", maxBytes: 1 << 20) }
        #expect(got.ok)
        #expect(got.staged == nil)
        #expect(data == FakeHelper.fileBytes)
        #expect(Self.stagedFiles(env) == [staged])  // only the raw one, which nobody took
    }

    /// The client gives up (a timeout, Ctrl-C) before the answer: the file staged for it is removed
    /// at once, not left in the bundle.
    @Test func getFileForAClientThatWentAwayIsRemoved() async throws {
        let env = try Env(delay: .milliseconds(300), helperVersion: "1.0.6")
        defer { env.cleanup() }
        let server = try env.start()
        defer { server.stop() }

        var raw: RawConnection? = try RawConnection(env.socketURL, vmID: env.config.id, bundle: env.bundle.url)
        try raw?.send(.getFile(path: "out.bin", maxBytes: 1 << 20))
        // Once the owner works on it (each helper call takes 300 ms), the client gives up: closed.
        let started = ContinuousClock.now + .seconds(5)
        while env.helper.requests.isEmpty, ContinuousClock.now < started {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!env.helper.requests.isEmpty)
        raw = nil

        // The owner got the file (logged ok, with its size) and then removed what it staged.
        let deadline = ContinuousClock.now + .seconds(5)
        var logged: AgentActivityEntry?
        while ContinuousClock.now < deadline {
            logged = env.log(server).first { $0.op == "getFile" }
            if logged != nil, Self.stagedFiles(env).isEmpty { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(logged?.ok == true)
        #expect(logged?.detail["bytes"] == String(FakeHelper.fileBytes.count))
        #expect(Self.stagedFiles(env).isEmpty)
    }

    /// Starting and stopping the socket sweeps what an earlier owner left (it crashed, or its
    /// client went away after the answer was sent): files older than `AgentFiles.maxAge`.
    @Test func startAndStopSweepStagedFiles() throws {
        let env = try Env(helperVersion: "1.0.6")
        defer { env.cleanup() }
        let old = try AgentFiles.stage(Data("old".utf8), in: env.bundle)
        let fresh = try AgentFiles.stage(Data("fresh".utf8), in: env.bundle)
        let longAgo = Date().addingTimeInterval(-(AgentFiles.maxAge + 1))
        try FileManager.default.setAttributes(
            [.modificationDate: longAgo], ofItemAtPath: env.bundle.agentFilesURL.appendingPathComponent(old).path)

        let server = try env.start()
        #expect(Self.stagedFiles(env) == [fresh])

        try FileManager.default.setAttributes(
            [.modificationDate: longAgo], ofItemAtPath: env.bundle.agentFilesURL.appendingPathComponent(fresh).path)
        server.stop()
        #expect(Self.stagedFiles(env).isEmpty)
    }

    @Test func getFileFailureIsForwarded() async throws {
        let env = try Env(helperVersion: "1.0.6")
        defer { env.cleanup() }
        let server = try env.start()
        defer { server.stop() }

        let client = env.client()
        let (answer, data) = try await blocking { try client.getFile("missing", maxBytes: 1 << 20) }
        #expect(!answer.ok)
        #expect(answer.error == .badRequest)
        #expect(answer.message == "no such file: missing")
        #expect(data == nil)
        #expect(Self.stagedFiles(env).isEmpty)
    }

    /// An answer naming a staged file that is not ours (a forged owner) is refused by the client.
    @Test func clientRefusesAForgedStagedAnswer() throws {
        var answer = AgentAnswer(ok: true)
        answer.staged = "../config.json"
        answer.bytes = 3
        let bundle = VMBundle(url: FileManager.default.temporaryDirectory.appendingPathComponent("none-\(UUID())"))
        let (taken, data) = AgentControlClient.takeStaged(answer, in: bundle)
        #expect(!taken.ok)
        #expect(taken.error == .internalError)
        #expect(data == nil)

        // An ok answer without a staged file has no bytes either.
        let (empty, none) = AgentControlClient.takeStaged(AgentAnswer(ok: true), in: bundle)
        #expect(!empty.ok)
        #expect(none == nil)
    }

    @Test func listFilesCleansNames() async throws {
        let env = try Env(helperVersion: "1.0.6")
        defer { env.cleanup() }
        let server = try env.start()
        defer { server.stop() }

        let client = env.client()
        let answer = try await blocking { try client.send(.listFiles(path: "docs")) }
        #expect(answer.ok)
        #expect(answer.truncated == true)
        let files = try #require(answer.files)
        #expect(files.map(\.name) == ["report ]0;pwned next", "folder"])
        #expect(files.map(\.kind) == ["file", "folder"])
        #expect(files[0].size == 12 && files[0].modified == Date(timeIntervalSince1970: 1_800_000_000))
    }

    @Test func logRecordsPathAndBytesOnly() async throws {
        let env = try Env(helperVersion: "1.0.6")
        defer { env.cleanup() }
        let server = try env.start()
        defer { server.stop() }

        let client = env.client()
        let secret = Data("TOPSECRETCONTENT".utf8)
        _ = try await blocking { () -> Int in
            _ = try client.putFile(secret, to: "dir/secret\u{1B}[2J.txt")
            _ = try client.getFile("out.bin", maxBytes: 1 << 20)
            _ = try client.getFile("missing", maxBytes: 1 << 20)
            _ = try client.send(.listFiles(path: nil))
            _ = try client.send(.listFiles(path: "docs"))
            return 0
        }
        let log = env.log(server).filter { $0.op != "status" }
        #expect(log.map(\.op) == ["putFile", "getFile", "getFile", "listFiles", "listFiles"])
        try #require(log.count == 5)
        #expect(log[0].detail == ["path": "dir/secret [2J.txt", "bytes": String(secret.count)])
        #expect(log[1].detail == ["path": "out.bin", "bytes": String(FakeHelper.fileBytes.count)])
        #expect(log[2].detail == ["path": "missing"])
        #expect(log[2].ok == false)
        #expect(log[3].detail == ["entries": "2"])
        #expect(log[4].detail == ["path": "docs", "entries": "2"])
        let bytes = try Data(contentsOf: env.bundle.agentLogURL.appendingPathComponent("agent-log.jsonl"))
        let text = String(decoding: bytes, as: UTF8.self)
        #expect(!text.contains("TOPSECRETCONTENT") && !text.contains("GUESTSECRET") && !text.contains("pwned"))
    }

    @Test func uiTreeKeepsLastShot() async throws {
        let env = try Env(helperVersion: "1.0.5")
        defer { env.cleanup() }
        let server = try env.start()
        defer { server.stop() }

        let client = env.client()
        let answers = try await blocking {
            [
                try client.send(.screenshot(maxLongEdge: 1280)),
                try client.send(.uiTree(maxElements: 50)),
                try client.send(.click(x: 5, y: 6, button: .left, count: 1)),
            ]
        }
        #expect(answers.map(\.ok) == [true, true, true])
        #expect(answers[1].tree?.app == "Notes")
        #expect(answers[1].path == nil)
        let requests = env.helper.requests.filter { if case .status = $0.action { false } else { true } }
        try #require(requests.count == 3)
        #expect(requests[1].action == .uiTree(maxElements: 50))
        #expect(requests[1].image == FakeHelper.image)
        #expect(requests[1].screen == FakeHelper.screen)
        #expect(requests[2].image == FakeHelper.image)
        #expect(requests[2].screen == FakeHelper.screen)
    }

    /// A screen locked after a screenshot: the helper's own reason reaches the client for the
    /// three ops that need the screen, and the last screenshot stays the one clicks refer to.
    @Test func lockedScreenIsForwarded() async throws {
        let env = try Env(helperVersion: "1.0.5")
        defer { env.cleanup() }
        let server = try env.start()
        defer { server.stop() }

        let client = env.client()
        let helper = env.helper
        let answers = try await blocking {
            let shot = try client.send(.screenshot(maxLongEdge: 1280))
            helper.locked = true
            return [
                shot,
                try client.send(.screenshot(maxLongEdge: 1280)),
                try client.send(.zoom(x: 1, y: 2, width: 30, height: 40, maxLongEdge: 800)),
                try client.send(.uiTree(maxElements: 50)),
                try client.send(.click(x: 5, y: 6, button: .left, count: 1)),
            ]
        }
        #expect(answers.map(\.ok) == [true, false, false, false, true])
        for answer in answers[1...3] {
            #expect(answer.error == .notReady)
            #expect(answer.message == FakeHelper.lockedMessage)
            #expect(answer.path == nil)
        }
        let clicks = env.helper.requests.filter { if case .click = $0.action { true } else { false } }
        #expect(clicks.first?.image == FakeHelper.image)
    }

    @Test func treeTextIsCleaned() async throws {
        let dirty = UITree(app: "No\u{1B}[2Jtes\n", elements: [
            UIElement(id: 0, role: "but\nton", name: "Sa\u{1B}[31mve\nNow", value: "a\u{9B}b\r\nc", enabled: true,
                      focused: false, frame: PixelRect(x: 1, y: 2, w: 3, h: 4)),
        ], truncated: false)
        let env = try Env(helperVersion: "1.0.5", tree: dirty)
        defer { env.cleanup() }
        let server = try env.start()
        defer { server.stop() }

        let client = env.client()
        let answer = try await blocking {
            _ = try client.send(.screenshot(maxLongEdge: 1280))
            return try client.send(.uiTree(maxElements: 300))
        }
        // What the client returns, as MCP and `nido act` get it.
        let tree = try #require(answer.tree)
        let text = ([tree.app] + tree.elements.flatMap { [$0.role, $0.name ?? "", $0.value ?? ""] }).joined()
        #expect(!text.contains("\u{1B}"))
        #expect(!text.contains("\n"))
        #expect(!text.contains("\r"))
        #expect(!text.contains("\u{9B}"))
        #expect(tree.elements[0].name == "Sa [31mve Now")
        #expect(tree.elements[0].frame == PixelRect(x: 1, y: 2, w: 3, h: 4))
    }

    private static func bigTree(count: Int, text: Int) -> UITree {
        UITree(app: "Safari", elements: (0..<count).map { i in
            UIElement(id: i, role: "staticText", name: String(repeating: "n", count: text),
                      value: String(repeating: "v", count: text), enabled: true, focused: false,
                      frame: PixelRect(x: i, y: i, w: 100, h: 20))
        }, truncated: false)
    }

    @Test func bigTreeReachesTheClient() async throws {
        let env = try Env(helperVersion: "1.0.5", tree: Self.bigTree(count: 1000, text: 200))
        defer { env.cleanup() }
        let server = try env.start()
        defer { server.stop() }

        let client = env.client()
        let answer = try await blocking {
            _ = try client.send(.screenshot(maxLongEdge: 1280))
            return try client.send(.uiTree(maxElements: 1000))
        }
        #expect(answer.ok)
        #expect(answer.tree?.elements.count == 1000)
    }

    @Test func tooBigAnswerIsAClearError() async throws {
        let env = try Env(helperVersion: "1.0.5", tree: Self.bigTree(count: 1000, text: 3000))
        defer { env.cleanup() }
        let server = try env.start()
        defer { server.stop() }

        let client = env.client()
        let answer = try await blocking {
            _ = try client.send(.screenshot(maxLongEdge: 1280))
            return try client.send(.uiTree(maxElements: 1000))
        }
        #expect(!answer.ok)
        #expect(answer.message == L10n.string("the answer is too large: ask for fewer elements"))
    }

    @Test func secureValueIsDroppedOnTheHost() {
        let tree = UITree(app: "Safari", elements: [
            UIElement(id: 0, role: "secureTextField", name: "Password", value: "hunter2", enabled: true, focused: true,
                      frame: PixelRect(x: 1, y: 2, w: 3, h: 4)),
        ], truncated: false)
        let cleaned = AgentAnswer(ok: true, tree: tree).cleaned
        #expect(cleaned.tree?.elements[0].value == nil)
        #expect(cleaned.tree?.elements[0].name == "Password")
        #expect(!(String(decoding: (try? JSONEncoder().encode(cleaned)) ?? Data(), as: UTF8.self)).contains("hunter2"))
    }

    @Test func cleanedKeepsArea() {
        let tree = UITree(app: "Safari", elements: [
            UIElement(id: 0, role: "button", name: "Go", value: nil, enabled: true, focused: false,
                      frame: PixelRect(x: 1, y: 2, w: 3, h: 4)),
            UIElement(id: 1, role: "menuBarItem", name: "File", value: nil, enabled: true, focused: false,
                      frame: PixelRect(x: 1, y: 2, w: 3, h: 4), area: .menuBar),
            UIElement(id: 2, role: "dockItem", name: "Finder", value: "running", enabled: true, focused: false,
                      frame: PixelRect(x: 1, y: 2, w: 3, h: 4), area: .dock),
        ], truncated: false)
        let cleaned = AgentAnswer(ok: true, tree: tree).cleaned
        #expect(cleaned.tree?.elements.map(\.area) == [nil, .menuBar, .dock])
    }

    @Test func zoomOnOldHelper() async throws {
        let env = try Env(helperVersion: "1.0.3")
        defer { env.cleanup() }
        let server = try env.start()
        defer { server.stop() }

        let client = env.client()
        let answer = try await blocking {
            _ = try client.send(.screenshot(maxLongEdge: 1280))
            return try client.send(.zoom(x: 0, y: 0, width: 50, height: 50, maxLongEdge: 800))
        }
        #expect(answer.error == .versionMismatch)
        #expect(answer.message == L10n.string("Nido Agent is too old to zoom: run nido agent setup \(env.config.name.rawValue) to update it"))
        #expect(!env.helper.requests.contains { if case .zoom = $0.action { true } else { false } })
    }

    @Test func zoomForwardsAFailedStatus() async throws {
        let busy = AgentReply(ok: false, error: .timeout, message: "Nido Agent is still finishing the previous action")
        let env = try Env(statusReply: busy)
        defer { env.cleanup() }
        let server = try env.start()
        defer { server.stop() }

        let client = env.client()
        let answer = try await blocking {
            _ = try client.send(.screenshot(maxLongEdge: 1280))
            return try client.send(.zoom(x: 0, y: 0, width: 50, height: 50, maxLongEdge: 800))
        }
        #expect(answer.error == .timeout)
        #expect(answer.message == "Nido Agent is still finishing the previous action")
        #expect(!env.helper.requests.contains { if case .zoom = $0.action { true } else { false } })
    }

    @Test func zoomWithoutHelperVersionIsTooOld() async throws {
        let env = try Env(statusReply: AgentReply(ok: true))
        defer { env.cleanup() }
        let server = try env.start()
        defer { server.stop() }

        let client = env.client()
        let answer = try await blocking {
            _ = try client.send(.screenshot(maxLongEdge: 1280))
            return try client.send(.zoom(x: 0, y: 0, width: 50, height: 50, maxLongEdge: 800))
        }
        #expect(answer.error == .versionMismatch)
        #expect(!env.helper.requests.contains { if case .zoom = $0.action { true } else { false } })
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

// MARK: - Activity log

extension AgentControlServerTests {
    /// Every command the owner handles leaves one entry, whatever its outcome: the helper's
    /// answers, the owner's own refusals, the transport's errors. Never the clipboard.
    @Test func everyHandledCommandIsLogged() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let server = try env.start()
        defer { server.stop() }

        let client = env.client()
        let raw = try RawConnection(env.socketURL, vmID: env.config.id, bundle: env.bundle.url)
        let answers = try await blocking { () -> [AgentAnswer?] in
            var answers: [AgentAnswer?] = [
                try client.send(.status),
                try client.send(.click(x: 1, y: 2, button: .left, count: 1)),
                try client.send(.screenshot(maxLongEdge: 1280)),
                try client.send(.click(x: 10, y: 20, button: .left, count: 1)),
                try client.send(.key(combo: "refuse")),
                try client.send(.key(combo: "fail")),
                try client.send(.type(text: "hunter2!")),
            ]
            try raw.send(.setClipboard(text: "clip-secret", clearAfter: 60))
            answers.append(try raw.readAnswer())
            return answers
        }
        #expect(answers.map { $0?.ok } == [true, false, true, true, false, false, true, false])
        try env.bundle.updateConfig { $0.agentAccess = false }
        let off = try await blocking { try client.send(.status) }
        #expect(off.error == .agentAccessOff)

        let log = env.log(server)
        #expect(log.map(\.op) == ["status", "click", "screenshot", "click", "key", "key", "type", "status"])
        #expect(log.map(\.ok) == [true, false, true, true, false, false, true, false])
        #expect(log.map(\.error) == [nil, "noScreenshot", nil, nil, "permissionMissing", "notReady", nil, "agentAccessOff"])
        try #require(log.count == 8)
        // A key's failure keeps its code, never its message (it can echo the key).
        #expect(log[4].message == nil && log[5].message == nil)
        #expect(log[1].message?.isEmpty == false)
        #expect(log.allSatisfy { $0.v == 1 && $0.client == "act" && $0.ms >= 0 })
        #expect(log[3].detail == ["x": "10", "y": "20", "button": "left", "count": "1"])
        #expect(log[6].detail == ["chars": "8"])
        // The screenshot has its thumbnail; nothing else has one.
        let thumb = try #require(log[2].thumb)
        #expect(FileManager.default.fileExists(atPath: AgentActivityLog.thumbnailURL(thumb, in: env.bundle).path))
        #expect(log.enumerated().allSatisfy { $0.offset == 2 || $0.element.thumb == nil })
        let bytes = try Data(contentsOf: env.bundle.agentLogURL.appendingPathComponent("agent-log.jsonl"))
        let text = String(decoding: bytes, as: UTF8.self)
        #expect(!text.contains("hunter2") && !text.contains("clip-secret") && !text.contains("setClipboard"))
    }

    @Test func zoomAndTreeAreLogged() async throws {
        let env = try Env(helperVersion: "1.0.5")
        defer { env.cleanup() }
        let server = try env.start()
        defer { server.stop() }

        let client = env.client("mcp", session: "mcp-run-1")
        _ = try await blocking {
            [
                try client.send(.screenshot(maxLongEdge: 1280)),
                try client.send(.zoom(x: 10, y: 20, width: 300, height: 200, maxLongEdge: 800)),
                try client.send(.uiTree(maxElements: 50)),
            ]
        }
        let log = env.log(server)
        // The helper's version check before a zoom or a tree is the owner's, not the agent's.
        #expect(log.map(\.op) == ["screenshot", "zoom", "uiTree"])
        try #require(log.count == 3)
        #expect(log[1].detail == ["region": "10,20,300,200", "maxLongEdge": "800"])
        #expect(log[1].thumb != nil && log[1].thumb != log[0].thumb)
        #expect(log[2].detail == ["maxElements": "50", "elements": "0", "app": "Notes"])
        #expect(log.allSatisfy { $0.client == "mcp" && $0.session == "mcp-run-1" })
    }

    /// One connection is one session; a client that sends a session (a `nido mcp` run, one
    /// connection per command) keeps it across its connections.
    @Test func sessionsFollowConnectionsAndClients() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let server = try env.start()
        defer { server.stop() }

        let first = try RawConnection(env.socketURL, vmID: env.config.id, bundle: env.bundle.url)
        let second = try RawConnection(env.socketURL, vmID: env.config.id, bundle: env.bundle.url)
        let mcpA = env.client("mcp", session: "aaaa-1")
        let mcpB = env.client("mcp", session: "bbbb-2")
        _ = try await blocking {
            for connection in [first, second, first, second] {
                try connection.send(.status, client: "mcp")
                _ = try connection.readAnswer()
            }
            _ = try mcpA.send(.status)
            _ = try mcpB.send(.status)
            _ = try mcpA.send(.status)
        }
        let sessions = env.log(server).map(\.session)
        try #require(sessions.count == 7)
        #expect(sessions[0] == sessions[2])
        #expect(sessions[1] == sessions[3])
        #expect(sessions[0] != sessions[1])
        #expect(Array(sessions[4...]) == ["aaaa-1", "bbbb-2", "aaaa-1"])
        #expect(!sessions[0].isEmpty)

        // A session that is not a short token is not taken: the connection's own instead.
        let long = env.client("mcp", session: String(repeating: "x", count: 200))
        let weird = env.client("mcp", session: "bad\nsession")
        _ = try await blocking { (try long.send(.status), try weird.send(.status)) }
        let tail = env.log(server).suffix(2).map(\.session)
        #expect(tail.count == 2)
        #expect(tail.allSatisfy { !$0.isEmpty && $0.count <= 64 && !$0.contains("\n") && !$0.hasPrefix("xxxx") })
    }

    /// Each `nido act` is a connection of its own: it joins the last `act` session when that
    /// one's last entry is less than 10 minutes old.
    @Test func actCommandsShareASessionWithin10Minutes() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let clock = Mutex(Date(timeIntervalSince1970: 1_800_000_000))
        let server = try env.start(now: { clock.withLock { $0 } })
        defer { server.stop() }

        let act = env.client("act")
        let older = env.client()  // a client from before `client`: an `act`
        let mcp = env.client("mcp", session: "mcp-1")
        for (seconds, client) in [(0.0, act), (60, older), (90, mcp), (120, act), (120 + 11 * 60, act)] {
            clock.withLock { $0 = Date(timeIntervalSince1970: 1_800_000_000 + seconds) }
            _ = try await blocking { try client.send(.status) }
        }
        let log = env.log(server)
        #expect(log.map(\.client) == ["act", "act", "mcp", "act", "act"])
        try #require(log.count == 5)
        #expect(log[0].session == log[1].session)
        #expect(log[1].session == log[3].session)
        #expect(log[2].session == "mcp-1")
        #expect(log[4].session != log[3].session)
        #expect(log[1].time == Date(timeIntervalSince1970: 1_800_000_060))
    }

    /// The client names only its kind; anything else is recorded as `act`. Nido's own status
    /// checks (the app's Agent pane, `nido agent status`, the setup) are not the agent's actions.
    @Test func clientKindsAndNidoChecks() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let server = try env.start()
        defer { server.stop() }

        let nido = env.client("nido")
        let odd = env.client("x\u{1B}[2J")
        _ = try await blocking {
            _ = try nido.send(.status)
            _ = try nido.send(.key(combo: "cmd+a"))
            _ = try odd.send(.status)
        }
        let log = env.log(server)
        #expect(log.map(\.op) == ["key", "status"])
        #expect(log.map(\.client) == ["nido", "act"])
    }

    /// Writing the log (a thumbnail, a rotation) never delays an answer: a writer stuck on the
    /// disk leaves the agent served, and what it writes later keeps the order of the commands.
    @Test func slowLogNeverDelaysTheAnswer() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let release = DispatchSemaphore(value: 0)
        let written = Mutex<[(op: String, png: Bool)]>([])
        let server = try env.start(appendLog: { entry, png in
            release.wait()
            release.signal()
            written.withLock { $0.append((entry.op, png != nil)) }
        })
        defer { server.stop() }

        let client = env.client("mcp", session: "slow-1")
        let began = ContinuousClock.now
        let answers = try await blocking {
            [
                try client.send(.status, timeout: .seconds(5)),
                try client.send(.screenshot(maxLongEdge: 1280), timeout: .seconds(5)),
                try client.send(.click(x: 1, y: 2, button: .left, count: 1), timeout: .seconds(5)),
                try client.send(.type(text: "abc"), timeout: .seconds(5)),
            ]
        }
        #expect(answers.map(\.ok) == [true, true, true, true])
        #expect(began.duration(to: .now) < .seconds(5))
        #expect(written.withLock { $0.isEmpty })

        release.signal()
        server.waitForLog()
        let entries = written.withLock { $0 }
        #expect(entries.map(\.op) == ["status", "screenshot", "click", "type"])
        #expect(entries.map(\.png) == [false, true, false, false])
    }

    /// The log is the owner's own business: when it cannot be written, the agent's action and
    /// its answer are as they would be without it.
    @Test func appendFailureDoesNotChangeTheAnswer() async throws {
        let env = try Env()
        defer { env.cleanup() }
        try Data("not a folder".utf8).write(to: env.bundle.agentLogURL)
        let server = try env.start()
        defer { server.stop() }

        let client = env.client()
        let answers = try await blocking {
            [try client.send(.status), try client.send(.screenshot(maxLongEdge: 1280)),
             try client.send(.click(x: 1, y: 2, button: .left, count: 1))]
        }
        #expect(answers.map(\.ok) == [true, true, true])
        #expect(answers[1].path != nil)
        #expect(answers[1].image == FakeHelper.image)
        #expect(try Data(contentsOf: env.bundle.agentLogURL) == Data("not a folder".utf8))
    }
}
