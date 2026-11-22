// SPDX-License-Identifier: Apache-2.0
import Foundation
import NidoAgentKit
import Synchronization
import Testing
@testable import NidoCLI
@_spi(Testing) @testable import NidoCore

@Suite(.italian) struct AgentCommandTests {
    private func makeBundle(guest: GuestOS, agentAccess: Bool? = nil) throws -> (VMBundle, URL) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("nido-tests-agent-cli-\(UUID().uuidString)", isDirectory: true)
        let paths = NidoPaths(root: tmp)
        var config = VMConfig(
            id: UUID(), name: try VMName("vm"), guest: guest, cpuCount: 2,
            memoryBytes: 4 << 30, diskBytes: 20 << 30, macAddress: "02:00:00:00:00:01")
        config.agentAccess = agentAccess
        return (try VMBundle.create(config: config, paths: paths), tmp)
    }

    /// The activity log tells an MCP run from `nido act`, and Nido's own checks from both: each
    /// caller names itself, and an MCP run keeps one session across its connections.
    @Test func clientsNameTheirCaller() throws {
        let (bundle, tmp) = try makeBundle(guest: .macos, agentAccess: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let config = try bundle.readConfig()

        let act = AgentSupport.client(bundle: bundle, config: config, for: .act)
        #expect(act.client == "act")
        #expect(act.session == nil)
        let nido = AgentSupport.client(bundle: bundle, config: config, for: .nido)
        #expect(nido.client == "nido")
        #expect(nido.session == nil)
        let mcp = AgentSupport.client(bundle: bundle, config: config, for: .mcp)
        let other = AgentSupport.client(bundle: bundle, config: config, for: .mcp)
        #expect(mcp.client == "mcp")
        let session = try #require(mcp.session)
        #expect(!session.isEmpty && session != other.session)
        #expect(mcp.vmID == config.id && mcp.bundle == bundle.url)
    }

    @Test func parsesClick() throws {
        let action = try AgentSupport.parseAction(["click", "10", "20", "--right", "--count", "2"])
        #expect(action == .click(x: 10, y: 20, button: .right, count: 2))
        #expect(try AgentSupport.parseAction(["click", "1.5", "2"]) == .click(x: 1.5, y: 2, button: .left, count: 1))
    }

    @Test func rejectsCountFour() throws {
        #expect(throws: (any Error).self) {
            _ = try AgentSupport.parseAction(["click", "10", "20", "--count", "4"])
        }
        #expect(throws: (any Error).self) {
            _ = try AgentSupport.parseAction(["click", "10", "20", "--count", "0"])
        }
    }

    /// `nido mcp --config`: the entry an MCP client adds, plain, with `--fresh` and with `--keep`.
    @Test func mcpConfigSnippetPlainFreshKeep() {
        let exe = "/usr/local/bin/nido"
        #expect(AgentSupport.mcpConfigSnippet(vm: "agent", executable: exe, fresh: false, keep: false)
            == #"{"mcpServers":{"nido-agent":{"args":["mcp","agent"],"command":"/usr/local/bin/nido"}}}"#)
        #expect(AgentSupport.mcpConfigSnippet(vm: "agent", executable: exe, fresh: true, keep: false)
            == #"{"mcpServers":{"nido-fresh-agent":{"args":["mcp","--fresh","agent"],"command":"/usr/local/bin/nido"}}}"#)
        #expect(AgentSupport.mcpConfigSnippet(vm: "agent", executable: exe, fresh: true, keep: true)
            == #"{"mcpServers":{"nido-fresh-agent":{"args":["mcp","--fresh","--keep","agent"],"command":"/usr/local/bin/nido"}}}"#)
    }

    @Test func rejectsBadCombo() throws {
        #expect(throws: KeyMapError.unknownKey("nope")) {
            _ = try AgentSupport.parseAction(["key", "cmd+nope"])
        }
        #expect(try AgentSupport.parseAction(["key", "cmd+a"]) == .key(combo: "cmd+a"))
        #expect(try AgentSupport.parseAction(["key", "cmd+é"]) == .key(combo: "cmd+é"))
    }

    @Test func parsesTheOtherActions() throws {
        #expect(try AgentSupport.parseAction(["status"]) == .status)
        #expect(try AgentSupport.parseAction(["screenshot"]) == .screenshot(maxLongEdge: 1280))
        #expect(try AgentSupport.parseAction(["screenshot", "--max", "64"]) == .screenshot(maxLongEdge: 64))
        #expect(throws: (any Error).self) { _ = try AgentSupport.parseAction(["screenshot", "--max", "63"]) }
        #expect(throws: (any Error).self) { _ = try AgentSupport.parseAction(["screenshot", "--max", "4097"]) }
        #expect(try AgentSupport.parseAction(["drag", "1", "2", "3", "4"])
            == .drag(fromX: 1, fromY: 2, toX: 3, toY: 4))
        #expect(try AgentSupport.parseAction(["scroll", "--dx", "0", "--dy", "-5"])
            == .scroll(dx: 0, dy: -5, x: nil, y: nil))
        #expect(try AgentSupport.parseAction(["scroll", "--dy", "3", "--x", "5", "--y", "6"])
            == .scroll(dx: 0, dy: 3, x: 5, y: 6))
        #expect(throws: (any Error).self) { _ = try AgentSupport.parseAction(["scroll", "--x", "5"]) }
        #expect(try AgentSupport.parseAction(["type", "hello world"]) == .type(text: "hello world"))
        #expect(throws: (any Error).self) { _ = try AgentSupport.parseAction(["frobnicate"]) }
        #expect(throws: (any Error).self) { _ = try AgentSupport.parseAction([]) }
        #expect(throws: (any Error).self) { _ = try AgentSupport.parseAction(["click", "10"]) }
        #expect(throws: (any Error).self) { _ = try AgentSupport.parseAction(["click", "a", "b"]) }
    }

    @Test func invocationCarriesOutputAndWait() throws {
        #expect(try AgentSupport.parseInvocation(["screenshot", "--output", "/x/a.png"])
            == .send(.screenshot(maxLongEdge: 1280), output: "/x/a.png"))
        #expect(try AgentSupport.parseInvocation(["wait", "250"]) == .wait(milliseconds: 250))
        #expect(try AgentSupport.parseInvocation(["status"]) == .send(.status, output: nil))
        #expect(throws: (any Error).self) { _ = try AgentSupport.parseInvocation(["click", "1", "2", "--output", "x"]) }
    }

    /// The text for an unknown action names every action `nido act` takes, in every language.
    @Test func unknownActionListsEveryAction() throws {
        let actions = ["status", "screenshot", "zoom", "ui-tree", "click", "drag", "scroll", "type", "key", "wait",
                       "checkpoint", "rollback", "checkpoints", "put-file", "get-file", "files"]
        for action in actions {
            do {
                _ = try AgentSupport.parseInvocation([action])
            } catch let error as CLIError {
                #expect(error != .unknownAgentAction(action), "\(action)")
            } catch {}
        }
        #expect(throws: CLIError.unknownAgentAction("teleport")) { _ = try AgentSupport.parseInvocation(["teleport"]) }
        let text = try #require(CLIError.unknownAgentAction("teleport").errorDescription)
        #expect(text.contains("teleport"))
        for language in ["en", "it", "de", "es", "fr"] {
            let translated = L10n.string(
                "unknown action “\("x")”: use status, screenshot, zoom, ui-tree, click, drag, scroll, type, key, wait, checkpoint, rollback, checkpoints, put-file, get-file or files",
                language: language)
            for action in actions {
                #expect(translated.contains(" \(action)"), "\(language) \(action)")
            }
        }
        #expect(text == L10n.string(
            "unknown action “\("teleport")”: use status, screenshot, zoom, ui-tree, click, drag, scroll, type, key, wait, checkpoint, rollback, checkpoints, put-file, get-file or files"))
    }

    // MARK: - Files

    @Test func fileParsing() throws {
        #expect(try AgentSupport.parseInvocation(["put-file", "/tmp/a.txt", "in/a.txt"])
            == .putFile(local: "/tmp/a.txt", guestPath: "in/a.txt"))
        #expect(try AgentSupport.parseInvocation(["get-file", "out/log.txt", "log.txt"])
            == .getFile(guestPath: "out/log.txt", local: "log.txt", force: false))
        #expect(try AgentSupport.parseInvocation(["get-file", "out/log.txt", "log.txt", "--force"])
            == .getFile(guestPath: "out/log.txt", local: "log.txt", force: true))
        #expect(try AgentSupport.parseInvocation(["files"]) == .send(.listFiles(path: nil), output: nil))
        #expect(try AgentSupport.parseInvocation(["files", "out"]) == .send(.listFiles(path: "out"), output: nil))
        for bad in [["put-file", "a"], ["put-file", "a", "b", "c"], ["put-file", "a", "b", "--force"],
                    ["get-file", "a"], ["get-file", "a", "b", "--output", "c"], ["files", "a", "b"], ["files", "--force"]] {
            #expect(throws: (any Error).self, "\(bad)") { _ = try AgentSupport.parseInvocation(bad) }
        }
        #expect(throws: CLIError.agentUsage("put-file LOCAL GUEST-PATH")) {
            _ = try AgentSupport.parseAction(["put-file", "a", "b"])
        }
    }

    private func makeFolder() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("nido-tests-agent-files-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    private func mode(_ url: URL) throws -> Int {
        try #require(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
    }

    /// A regular file is read whole; a link is never followed, a folder is no file, and more than
    /// 16 MiB is refused with the exact text.
    @Test func putFileReadsOnlyARegularFileUpTo16MiB() throws {
        let tmp = try makeFolder()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let file = tmp.appendingPathComponent("a.bin")
        try Data([1, 2, 3]).write(to: file)
        #expect(try AgentSupport.readLocalFile(file.path) == Data([1, 2, 3]))
        let exact = tmp.appendingPathComponent("exact.bin")
        #expect(FileManager.default.createFile(atPath: exact.path, contents: nil))
        try FileHandle(forWritingTo: exact).truncate(atOffset: UInt64(AgentProtocol.maxTransferBytes))
        #expect(try AgentSupport.readLocalFile(exact.path).count == AgentProtocol.maxTransferBytes)
        let big = tmp.appendingPathComponent("big.bin")
        #expect(FileManager.default.createFile(atPath: big.path, contents: nil))
        try FileHandle(forWritingTo: big).truncate(atOffset: UInt64(AgentProtocol.maxTransferBytes + 1))
        #expect(throws: CLIError.agentFileTooLarge) { try AgentSupport.readLocalFile(big.path) }
        #expect(CLIError.agentFileTooLarge.errorDescription == L10n.string("the file is larger than 16 MiB"))
        #expect(L10n.string("the file is larger than 16 MiB", language: "en") == "the file is larger than 16 MiB")

        let link = tmp.appendingPathComponent("link.bin")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        #expect(throws: CLIError.notARegularFile(link.path)) { try AgentSupport.readLocalFile(link.path) }
        #expect(throws: CLIError.notARegularFile(tmp.path)) { try AgentSupport.readLocalFile(tmp.path) }
        #expect(CLIError.notARegularFile("/x").errorDescription == L10n.string("\("/x") is not a regular file"))
        let none = tmp.appendingPathComponent("none").path
        #expect(throws: CLIError.localFileUnreadable(none, "No such file or directory")) { try AgentSupport.readLocalFile(none) }
        let message = CLIError.localFileUnreadable("/x", "No such file or directory").errorDescription
        #expect(message == L10n.string("can’t read \("/x"): \("No such file or directory")"))
        #expect(message?.contains("/x") == true)
    }

    /// Without --force an existing path (a file, or a link even to nothing) is refused with the
    /// exact text and left as it is; a new file is written 0600.
    @Test func getFileNeverReplacesWithoutForce() throws {
        let tmp = try makeFolder()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let existing = tmp.appendingPathComponent("there.txt")
        try Data("mine".utf8).write(to: existing)
        #expect(throws: CLIError.localFileExists(existing.path)) {
            try AgentSupport.checkLocalTarget(existing.path, force: false)
        }
        #expect(throws: CLIError.localFileExists(existing.path)) {
            try AgentSupport.writeLocalFile(Data("theirs".utf8), to: existing.path, force: false)
        }
        #expect(try Data(contentsOf: existing) == Data("mine".utf8))
        #expect(CLIError.localFileExists("/x/a").errorDescription == L10n.string("\("/x/a") already exists: add --force to replace it"))
        #expect(L10n.string("\("/x/a") already exists: add --force to replace it", language: "en")
            == "/x/a already exists: add --force to replace it")

        let outside = tmp.appendingPathComponent("outside.txt")
        let dangling = tmp.appendingPathComponent("dangling.txt")
        try FileManager.default.createSymbolicLink(at: dangling, withDestinationURL: outside)
        #expect(throws: CLIError.localFileExists(dangling.path)) {
            try AgentSupport.checkLocalTarget(dangling.path, force: false)
        }
        #expect(throws: CLIError.localFileExists(dangling.path)) {
            try AgentSupport.writeLocalFile(Data("x".utf8), to: dangling.path, force: false)
        }
        #expect(!FileManager.default.fileExists(atPath: outside.path))

        let fresh = tmp.appendingPathComponent("new.txt")
        try AgentSupport.checkLocalTarget(fresh.path, force: false)
        try AgentSupport.writeLocalFile(Data("new".utf8), to: fresh.path, force: false)
        #expect(try Data(contentsOf: fresh) == Data("new".utf8))
        #expect(try mode(fresh) == 0o600)
    }

    /// --force replaces a file atomically, 0600, and replaces a link as an entry: its target is
    /// never written. Nothing temporary stays in the folder.
    @Test func getFileWithForceReplacesWithoutFollowingALink() throws {
        let tmp = try makeFolder()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let existing = tmp.appendingPathComponent("there.txt")
        try Data("mine".utf8).write(to: existing)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: existing.path)
        try AgentSupport.checkLocalTarget(existing.path, force: true)
        try AgentSupport.writeLocalFile(Data("theirs".utf8), to: existing.path, force: true)
        #expect(try Data(contentsOf: existing) == Data("theirs".utf8))
        #expect(try mode(existing) == 0o600)

        let target = tmp.appendingPathComponent("target.txt")
        try Data("keep".utf8).write(to: target)
        let link = tmp.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        try AgentSupport.writeLocalFile(Data("new".utf8), to: link.path, force: true)
        #expect(try Data(contentsOf: target) == Data("keep".utf8))
        let type = try FileManager.default.attributesOfItem(atPath: link.path)[.type] as? FileAttributeType
        #expect(type == .typeRegular)
        #expect(try Data(contentsOf: link) == Data("new".utf8))
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: tmp.path)) == ["there.txt", "target.txt", "link.txt"])
    }

    /// A name as long as the folder allows (255 bytes) is replaced too: the temporary name is
    /// short, not derived from it.
    @Test func getFileWithForceReplacesALongName() throws {
        let tmp = try makeFolder()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let long = tmp.appendingPathComponent(String(repeating: "n", count: 251) + ".txt")
        try Data("old".utf8).write(to: long)
        try AgentSupport.writeLocalFile(Data("new".utf8), to: long.path, force: true)
        #expect(try Data(contentsOf: long) == Data("new".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: tmp.path) == [long.lastPathComponent])
    }

    /// The answer `nido act get-file` prints: ok only when the file was written; a write that
    /// fails turns it into a failure with the reason, and a failed answer writes nothing.
    @Test func getFileAnswerReflectsTheWrite() throws {
        let tmp = try makeFolder()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let answer = AgentAnswer(ok: true, bytes: 2)
        let fresh = tmp.appendingPathComponent("a.txt")
        #expect(AgentSupport.completeGetFile(answer, data: Data("hi".utf8), to: fresh.path, force: false) == answer)
        #expect(try Data(contentsOf: fresh) == Data("hi".utf8))
        let failed = AgentSupport.completeGetFile(answer, data: Data("yo".utf8), to: fresh.path, force: false)
        #expect(!failed.ok && failed.error == .internalError)
        #expect(failed.message == CLIError.localFileExists(fresh.path).errorDescription)
        // No file was written: the JSON states no size.
        #expect(failed.bytes == nil)
        #expect(try Data(contentsOf: fresh) == Data("hi".utf8))
        let refused = AgentAnswer.failure(.badRequest, "'x' does not exist in NidoTransfer")
        let other = tmp.appendingPathComponent("b.txt")
        #expect(AgentSupport.completeGetFile(refused, data: nil, to: other.path, force: false) == refused)
        #expect(!FileManager.default.fileExists(atPath: other.path))
        #expect(!AgentSupport.completeGetFile(answer, data: nil, to: other.path, force: false).ok)
        #expect(AgentSupport.json(answer) == #"{"bytes":2,"ok":true}"#)
    }

    @Test func checkpointParsing() throws {
        #expect(try AgentSupport.parseInvocation(["checkpoint", "--name", "before-brew"])
            == .send(.checkpoint(name: "before-brew"), output: nil))
        #expect(try AgentSupport.parseInvocation(["checkpoint"]) == .send(.checkpoint(name: nil), output: nil))
        #expect(try AgentSupport.parseInvocation(["rollback"]) == .send(.rollback(name: nil), output: nil))
        #expect(try AgentSupport.parseInvocation(["rollback", "x"]) == .send(.rollback(name: "x"), output: nil))
        #expect(try AgentSupport.parseInvocation(["checkpoints"]) == .send(.checkpoints, output: nil))
        #expect(throws: (any Error).self) { _ = try AgentSupport.parseInvocation(["checkpoint", "x"]) }
        #expect(throws: (any Error).self) { _ = try AgentSupport.parseInvocation(["checkpoint", "--name"]) }
        #expect(throws: (any Error).self) { _ = try AgentSupport.parseInvocation(["rollback", "x", "y"]) }
        #expect(throws: (any Error).self) { _ = try AgentSupport.parseInvocation(["rollback", "--name", "x"]) }
        #expect(throws: (any Error).self) { _ = try AgentSupport.parseInvocation(["checkpoints", "x"]) }
    }

    /// `nido act` prints the owner's checkpoint answers as one JSON line, like any other.
    @Test func checkpointAnswersPrintAsJSON() {
        let answer = AgentAnswer(ok: true, message: "checkpoint a1 saved in 3 s",
                                 checkpoint: AgentCheckpointInfo(name: "a1", createdAt: Date(timeIntervalSince1970: 0)))
        let line = AgentSupport.json(answer)
        #expect(!line.contains("\n"))
        // A time a person can read: ISO 8601, UTC.
        #expect(line.contains(#""checkpoint":{"createdAt":"1970-01-01T00:00:00Z","name":"a1"}"#))
    }

    @Test func uiTreeParsing() throws {
        #expect(try AgentSupport.parseInvocation(["ui-tree", "--max", "50"]) == .send(.uiTree(maxElements: 50), output: nil))
        #expect(try AgentSupport.parseInvocation(["ui-tree"]) == .send(.uiTree(maxElements: 300), output: nil))
        #expect(throws: (any Error).self) { _ = try AgentSupport.parseInvocation(["ui-tree", "--max", "0"]) }
        #expect(throws: (any Error).self) { _ = try AgentSupport.parseInvocation(["ui-tree", "--max", "1001"]) }
        #expect(throws: (any Error).self) { _ = try AgentSupport.parseInvocation(["ui-tree", "--output", "/x"]) }
        #expect(throws: (any Error).self) { _ = try AgentSupport.parseInvocation(["ui-tree", "5"]) }
    }

    @Test func zoomParsing() throws {
        #expect(try AgentSupport.parseInvocation(["zoom", "10", "20", "300", "200", "--max", "800"])
            == .send(.zoom(x: 10, y: 20, width: 300, height: 200, maxLongEdge: 800), output: nil))
        #expect(try AgentSupport.parseInvocation(["zoom", "1", "2", "3", "4", "--output", "/x/z.png"])
            == .send(.zoom(x: 1, y: 2, width: 3, height: 4, maxLongEdge: 1280), output: "/x/z.png"))
        #expect(throws: (any Error).self) { _ = try AgentSupport.parseInvocation(["zoom", "10", "20", "300"]) }
        #expect(throws: (any Error).self) { _ = try AgentSupport.parseInvocation(["zoom", "10", "20", "0", "200"]) }
        #expect(throws: (any Error).self) { _ = try AgentSupport.parseInvocation(["zoom", "-1", "20", "3", "200"]) }
        #expect(throws: (any Error).self) { _ = try AgentSupport.parseInvocation(["zoom", "1", "2", "3", "4", "--max", "63"]) }
        #expect(throws: (any Error).self) { _ = try AgentSupport.parseInvocation(["zoom", "1", "2", "3", "4", "--max", "4097"]) }
    }

    @Test func waitBounds() throws {
        #expect(try AgentSupport.waitMilliseconds(10000) == .milliseconds(10000))
        #expect(try AgentSupport.waitMilliseconds(0) == .zero)
        #expect(throws: (any Error).self) { _ = try AgentSupport.waitMilliseconds(10001) }
        #expect(throws: (any Error).self) { _ = try AgentSupport.waitMilliseconds(-1) }
        #expect(throws: (any Error).self) { _ = try AgentSupport.parseInvocation(["wait", "10001"]) }
        #expect(throws: (any Error).self) { _ = try AgentSupport.parseInvocation(["wait", "-1"]) }
    }

    @Test func actRefusedWithoutAgentAccess() throws {
        let (bundle, tmp) = try makeBundle(guest: .macos)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let config = try bundle.readConfig()
        #expect(throws: CLIError.agentAccessOff("vm")) { try AgentSupport.requireAgentAccess(config) }
        #expect(CLISupport.message(for: CLIError.agentAccessOff("vm"))
            == "L’accesso dell’agente è disattivato per vm: attivalo con nido agent enable vm")
        var on = config
        on.agentAccess = true
        try AgentSupport.requireAgentAccess(on)
    }

    @Test func enableRefusesLinux() throws {
        let (bundle, tmp) = try makeBundle(guest: .linux)
        defer { try? FileManager.default.removeItem(at: tmp) }
        #expect(throws: CLIError.agentNotForLinux) { _ = try AgentSupport.setAgentAccess(true, bundle: bundle) }
        #expect(try bundle.readConfig().agentAccess == nil)
        #expect(CLIError.agentNotForLinux.errorDescription == "L’accesso dell’agente è solo per le VM macOS.")
    }

    @Test func enableAndDisableWriteConfig() throws {
        let (bundle, tmp) = try makeBundle(guest: .macos)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let on = try AgentSupport.setAgentAccess(true, bundle: bundle)
        #expect(try bundle.readConfig().agentAccess == true)
        #expect(on == "L’accesso dell’agente è attivato per vm.")
        let off = try AgentSupport.setAgentAccess(false, bundle: bundle)
        #expect(try bundle.readConfig().agentAccess == false)
        #expect(off == "L’accesso dell’agente è disattivato per vm.")
    }

    /// Agent access is part of the saved state's configuration: changing it on a suspended VM
    /// says, as `nido share` does, that the saved state will be discarded at the next start.
    @Test func changingAccessOfASuspendedVMWarns() throws {
        let (bundle, tmp) = try makeBundle(guest: .macos)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let warning = "Attenzione: la VM è sospesa: al prossimo avvio lo stato salvato verrà scartato."
        #expect(!(try AgentSupport.setAgentAccess(true, bundle: bundle)).contains(warning))
        try Data("state".utf8).write(to: bundle.stateURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: bundle.stateURL.path)
        var config = try bundle.readConfig()
        config.suspendedConfigHash = config.stateHash()
        try bundle.writeConfig(config)

        // The same setting again: the saved state still resumes.
        #expect(!(try AgentSupport.setAgentAccess(true, bundle: bundle)).contains(warning))
        let off = try AgentSupport.setAgentAccess(false, bundle: bundle)
        #expect(off == "L’accesso dell’agente è disattivato per vm.\n" + warning)
    }

    @Test func enableWhileRunningSaysNextStart() throws {
        let (bundle, tmp) = try makeBundle(guest: .macos)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let lock = try BundleLock.acquire(bundle, owner: .cli)
        defer { lock.release() }
        let message = try AgentSupport.setAgentAccess(true, bundle: bundle)
        #expect(message == "L’accesso dell’agente è attivato per vm. Ha effetto dal prossimo avvio.")
        #expect(try bundle.readConfig().agentAccess == true)
    }

    /// `nido agent setup` before SSH: with FileVault on and nobody logged in, the guest's sshd is
    /// not up (or the guest has no address yet) and the helper is not ready: the hint says to log
    /// in through the window, not to turn on Remote Login.
    @Test func setupGateMatrix() {
        let notReady = AgentAnswer.failure(.notReady, "waiting for login or Nido Agent")
        let ready = AgentAnswer(ok: true, status: AgentStatus(
            helperVersion: "1.0.0", protocolVersion: 1, screenRecording: true, accessibility: true,
            screen: ScreenSize(width: 1, height: 1)))
        let absent = AgentAnswer.failure(.timeout, "slow")
        let unserved = AgentAnswer.failure(.notRunning, "restart it")

        let noAddress = AgentSupport.SSHReach.noAddress(.notOnNetwork("vm"))

        // A refusal means the guest's network is up: Remote Login, also on a first run where the
        // helper is not installed yet (notReady).
        #expect(AgentSupport.setupGate(helper: notReady, ssh: .refused) == .remoteLoginOff)
        #expect(AgentSupport.setupGate(helper: ready, ssh: .refused) == .remoteLoginOff)
        #expect(AgentSupport.setupGate(helper: absent, ssh: .refused) == .remoteLoginOff)
        // No SSH answer, or no address yet, while the helper is not ready: the login window.
        #expect(AgentSupport.setupGate(helper: notReady, ssh: .noAnswer) == .loginWindow)
        #expect(AgentSupport.setupGate(helper: notReady, ssh: noAddress) == .loginWindow)
        #expect(AgentSupport.setupGate(helper: notReady, ssh: .open) == .proceed)
        for helper in [ready, absent] {
            for ssh: AgentSupport.SSHReach in [.open, .noAnswer, noAddress] {
                #expect(AgentSupport.setupGate(helper: helper, ssh: ssh) == .proceed)
            }
        }
        for ssh: AgentSupport.SSHReach in [.open, .refused, .noAnswer, noAddress] {
            #expect(AgentSupport.setupGate(helper: unserved, ssh: ssh) == .notServed("restart it"))
        }
        #expect(CLIError.agentLoginWindow("vm").errorDescription
            == "vm potrebbe essere ferma alla finestra di login (FileVault): accedi dalla sua finestra, poi esegui di nuovo nido agent setup.")
    }

    /// FileVault on, nobody logged in: sshd answers but rejects the key. That is a login, not a key problem.
    @Test func keyRefusedBeforeLoginSaysLogIn() {
        let notReady = AgentAnswer.failure(.notReady, "waiting for login or Nido Agent")
        let hint = AgentSupport.loginHint(for: GuestSSHError.keyUnavailable("key"), helper: notReady, vm: "vm")
        #expect(hint?.errorDescription == CLIError.agentLoginWindow("vm").errorDescription)
    }

    @Test func keyRefusedWithReadyHelperStaysKeyError() {
        let ready = AgentAnswer(ok: true, status: AgentStatus(
            helperVersion: "1.0.0", protocolVersion: 1, screenRecording: true, accessibility: true,
            screen: ScreenSize(width: 1, height: 1)))
        #expect(AgentSupport.loginHint(for: GuestSSHError.keyUnavailable("key"), helper: ready, vm: "vm") == nil)
    }

    @Test func otherErrorsUntouched() {
        let notReady = AgentAnswer.failure(.notReady, "x")
        #expect(AgentSupport.loginHint(for: GuestSSHError.timeout, helper: notReady, vm: "vm") == nil)
    }

    /// The probe of `nido agent setup`: no address yet is kept for the gate; any other error of
    /// the SSH endpoint is thrown with its own message, never taken for a login window.
    @Test func setupProbeKeepsOtherErrors() throws {
        let endpoint = SSHEndpoint(host: "192.168.64.2", port: 22)
        let found: () throws -> SSHEndpoint = { endpoint }
        #expect(try AgentSupport.sshReach(resolve: found, probe: { _ in .open }) == .open)
        #expect(try AgentSupport.sshReach(resolve: found, probe: { _ in .refused }) == .refused)
        #expect(try AgentSupport.sshReach(resolve: found, probe: { _ in .noAnswer }) == .noAnswer)
        #expect(try AgentSupport.sshReach(resolve: { throw NidoError.notOnNetwork("vm") }, probe: { _ in .open })
            == .noAddress(.notOnNetwork("vm")))
        #expect(throws: NidoError.controlledNetworkInterrupted) {
            _ = try AgentSupport.sshReach(resolve: { throw NidoError.controlledNetworkInterrupted }, probe: { _ in .open })
        }
        #expect(throws: NidoError.notRunning("vm")) {
            _ = try AgentSupport.sshReach(resolve: { throw NidoError.notRunning("vm") }, probe: { _ in .open })
        }
        struct Other: Error, Equatable {}
        #expect(throws: Other()) {
            _ = try AgentSupport.sshReach(resolve: { throw Other() }, probe: { _ in .open })
        }
    }

    @Test func jsonIsOneLine() throws {
        let answer = AgentAnswer(
            ok: true, path: "/a/b.png", image: PixelSize(10, 20),
            screen: ScreenSize(width: 5, height: 6), message: "line1\nline2")
        let json = AgentSupport.json(answer)
        #expect(!json.contains("\n"))
        // A line break in a message is the guest's text too: a space.
        #expect(json == #"{"image":{"height":20,"width":10},"message":"line1 line2","ok":true,"path":"/a/b.png","screen":{"height":6,"width":5}}"#)
        #expect(AgentSupport.json(AgentAnswer(ok: true)) == #"{"ok":true}"#)
    }

    /// SECURITY: JSON escapes C0 controls but not C1 ones (U+009B is a CSI for some terminals):
    /// what the guest wrote in an answer is cleaned before it is encoded.
    @Test func guestTextIsCleanedBeforeJSON() throws {
        let dirty = "a\u{1B}]52;c;eA==\u{07}\u{9B}31m\u{85}b"
        let act = AgentSupport.json(AgentAnswer.failure(.internalError, dirty))
        let status = AgentSupport.statusJSON(agentAccess: true, running: true, helper: AgentAnswer(
            ok: true, status: AgentStatus(helperVersion: "1.0\u{9B}2J", protocolVersion: 1, screenRecording: true,
                                          accessibility: true, screen: ScreenSize(width: 1, height: 1)),
            message: dirty))
        for json in [act, status] {
            #expect(!json.unicodeScalars.contains { $0.properties.generalCategory == .control })
            #expect(!json.contains("\\u001b") && !json.contains("\\u0007"))
            #expect(json.contains("a ]52;c;eA== 31m b"))
        }
        #expect(status.contains(#""helperVersion":"1.0 2J""#))
    }

    @Test func statusReportIsSortedJSON() throws {
        let stopped = AgentSupport.statusJSON(agentAccess: true, running: false, helper: nil)
        #expect(stopped == #"{"agentAccess":true,"running":false}"#)
        let running = AgentSupport.statusJSON(
            agentAccess: true, running: true, helper: AgentAnswer.failure(.notReady, "x"))
        #expect(running == #"{"agentAccess":true,"helper":{"error":"notReady","message":"x","ok":false},"running":true}"#)
    }

    @Test func throwingClientStillYieldsStatusJSON() throws {
        struct Boom: Error {}
        let transport = AgentSupport.helperAnswer { throw AgentFailure(code: .internalError, message: "lost") }
        #expect(!transport.ok && transport.error == .internalError && transport.message == "lost")
        let other = AgentSupport.helperAnswer { throw Boom() }
        #expect(!other.ok && other.error == .internalError)
        let json = AgentSupport.statusJSON(agentAccess: true, running: true, helper: transport)
        #expect(json == #"{"agentAccess":true,"helper":{"error":"internalError","message":"lost","ok":false},"running":true}"#)
        #expect(AgentSupport.helperAnswer { AgentAnswer(ok: true) }.ok)
    }

    @Test func failedCopyTurnsScreenshotAnswerIntoFailure() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("nido-tests-agent-done-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let source = tmp.appendingPathComponent("s.png")
        try Data([9]).write(to: source)
        let existing = tmp.appendingPathComponent("there.png")
        try Data([1]).write(to: existing)
        let answer = AgentAnswer(ok: true, path: source.path)
        let failed = AgentSupport.completeScreenshot(answer, output: existing.path)
        #expect(!failed.ok && failed.error == .internalError && failed.path == source.path)
        #expect(failed.message?.contains("esiste già") == true)
        #expect(!AgentSupport.completeScreenshot(AgentAnswer(ok: true), output: existing.path).ok)
        let fresh = tmp.appendingPathComponent("new.png")
        #expect(AgentSupport.completeScreenshot(answer, output: fresh.path) == answer)
        #expect(try Data(contentsOf: fresh) == Data([9]))
        #expect(AgentSupport.completeScreenshot(answer, output: nil) == answer)
    }

    @Test func copyScreenshotRefusesToOverwrite() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("nido-tests-agent-copy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let source = tmp.appendingPathComponent("s.png")
        try Data([1, 2, 3]).write(to: source)
        let dest = tmp.appendingPathComponent("out.png")
        try AgentSupport.copyScreenshot(from: source.path, to: dest.path)
        #expect(try Data(contentsOf: dest) == Data([1, 2, 3]))
        let mode = try FileManager.default.attributesOfItem(atPath: dest.path)[.posixPermissions] as? Int
        #expect(((mode ?? 0) & 0o022) == 0)
        #expect(throws: CLIError.outputExists(dest.path)) {
            try AgentSupport.copyScreenshot(from: source.path, to: dest.path)
        }
        #expect(try Data(contentsOf: dest) == Data([1, 2, 3]))
    }

    // MARK: - An unusable stored password after a ready setup

    /// A store whose item is no usable password until `save` replaces it (or whose `save` fails).
    private final class UnusableStore: GuestPasswordStore, @unchecked Sendable {
        private let lock = NSLock()
        private var saved: GuestPassword?
        var readError: GuestPasswordStoreError? = .unusableItem
        var failsSave = false
        var stored: GuestPassword? { lock.withLock { saved } }
        func read(vm: UUID) throws -> GuestPassword? {
            try lock.withLock {
                if let saved { return saved }
                if let readError { throw readError }
                return nil
            }
        }
        func save(_ password: GuestPassword, vm: UUID) throws {
            try lock.withLock {
                if failsSave { throw GuestPasswordStoreError.keychain(-25308) }
                saved = password
            }
        }
        func delete(vm: UUID) throws {}
    }

    /// The key already works, so the setup never read the stored item: an unusable one is
    /// replaced with the password asked once at the terminal; without a terminal, a warning.
    @Test func unusableItemIsReplacedAfterAReadySetup() async throws {
        let id = UUID()
        let fresh = try #require(GuestPassword("fresh-one"))
        let store = UnusableStore()
        let asks = Mutex(0)
        let replaced = await AgentSupport.replaceUnusablePassword(vm: "mac", id: id, store: store, ask: {
            asks.withLock { $0 += 1 }
            return fresh
        })
        #expect(replaced == .replaced("La password salvata per mac è stata sostituita."))
        #expect(asks.withLock { $0 } == 1)
        #expect(store.stored == fresh)

        // No terminal, or nothing typed: the item's text, as a warning.
        let unusable = GuestPasswordStoreError.unusableItem.errorDescription ?? "?"
        #expect(await AgentSupport.replaceUnusablePassword(vm: "mac", id: id, store: UnusableStore(), ask: nil)
            == .warning(unusable))
        #expect(await AgentSupport.replaceUnusablePassword(vm: "mac", id: id, store: UnusableStore(), ask: { nil })
            == .warning(unusable))

        // The Keychain refuses the new one: said, not hidden.
        let refusing = UnusableStore()
        refusing.failsSave = true
        guard case .warning(let line) = await AgentSupport.replaceUnusablePassword(
            vm: "mac", id: id, store: refusing, ask: { fresh })
        else {
            Issue.record("expected a warning")
            return
        }
        #expect(line.hasPrefix("Non è stato possibile sostituire la password salvata per mac:"))
        #expect(line.contains("-25308"))

        // A usable item, none, or another Keychain error: nothing asked, nothing said.
        for readError in [nil, GuestPasswordStoreError.keychain(-25293)] as [GuestPasswordStoreError?] {
            let other = UnusableStore()
            other.readError = readError
            #expect(await AgentSupport.replaceUnusablePassword(vm: "mac", id: id, store: other, ask: {
                Issue.record("asked")
                return fresh
            }) == .unchanged)
        }
        let usable = UnusableStore()
        try usable.save(fresh, vm: id)
        #expect(await AgentSupport.replaceUnusablePassword(vm: "mac", id: id, store: usable, ask: nil) == .unchanged)
    }

    // MARK: nido agent log

    private func entry(_ time: Double, session: String = "aaaaaaaa-1111", client: String = "mcp", op: String = "click",
                       detail: [String: String] = [:], ok: Bool = true, error: String? = nil,
                       message: String? = nil, ms: Int = 12) -> AgentActivityEntry {
        AgentActivityEntry(
            v: 1, time: Date(timeIntervalSince1970: time), session: session, client: client, op: op, detail: detail,
            ok: ok, error: error, message: message, ms: ms, thumb: nil)
    }

    @Test func logTextOneLinePerEntryWithSessionSeparators() throws {
        let utc = try #require(TimeZone(identifier: "UTC"))
        let entries = [
            entry(1_700_000_000.123, detail: ["x": "10", "y": "20", "button": "left", "count": "1"]),
            entry(1_700_000_001, op: "type", detail: ["chars": "8"], ms: 3),
            entry(1_700_000_002, session: "bbbbbbbb-2222", client: "act", op: "uiTree", ok: false,
                  error: "notReady", message: "the screen is locked", ms: 40),
            entry(1_700_000_003, session: "bbbbbbbb-2222", client: "act", op: "key", ok: false, error: "badRequest"),
        ]
        let lines = AgentSupport.logLines(entries, timeZone: utc)
        #expect(lines == [
            "— sessione aaaaaaaa (mcp) —",
            "22:13:20.123 mcp click button=left count=1 x=10 y=20 ok (12 ms)",
            "22:13:21.000 mcp type chars=8 ok (3 ms)",
            "— sessione bbbbbbbb (act) —",
            "22:13:22.000 act uiTree notReady: the screen is locked (40 ms)",
            "22:13:23.000 act key badRequest (12 ms)",
        ])
        let rome = try #require(TimeZone(identifier: "Europe/Rome"))
        #expect(AgentSupport.logLines(entries, timeZone: rome)[1].hasPrefix("23:13:20.123 "))
    }

    @Test func logTextNeverPrintsControlCharacters() throws {
        let utc = try #require(TimeZone(identifier: "UTC"))
        let lines = AgentSupport.logLines(
            [entry(0, detail: ["app": "a\u{1B}[31mb\nc"], ok: false, error: "x\u{7}", message: "m\r\nn")], timeZone: utc)
        for line in lines { #expect(!line.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }) }
    }

    @Test func logJSONIsAnArrayOfEntries() throws {
        let entries = [entry(1_700_000_000.5, detail: ["x": "1"]), entry(1_700_000_001, op: "key", detail: ["combo": "cmd+a"])]
        let data = Data(AgentSupport.logJSON(entries).utf8)
        let back = try JSONDecoder().decode([AgentActivityEntry].self, from: data)
        #expect(back == entries)
        #expect(AgentSupport.logJSON([]) == "[]")
    }

    @Test func logLimitKeepsTheLastEntries() throws {
        let (bundle, tmp) = try makeBundle(guest: .macos, agentAccess: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        for i in 0..<5 {
            try AgentActivityLog.append(entry(1_700_000_000 + Double(i), detail: ["x": "\(i)"]), thumbnailPNG: nil, in: bundle)
        }
        let last = try AgentActivityLog.read(in: bundle, limit: 2)
        #expect(last.map { $0.detail["x"] } == ["3", "4"])
        #expect(throws: CLIError.agentLogLimitInvalid) { _ = try AgentSupport.logLimit("0") }
        #expect(throws: CLIError.agentLogLimitInvalid) { _ = try AgentSupport.logLimit("x") }
        #expect(throws: CLIError.agentLogLimitInvalid) { _ = try AgentSupport.logLimit("-3") }
        #expect(throws: CLIError.agentLogLimitInvalid) { _ = try AgentSupport.logLimit("99999999999999999999") }
        #expect(CLIError.agentLogLimitInvalid.errorDescription == "--limit deve essere un numero intero, almeno 1")
        #expect(try AgentSupport.logLimit("2") == 2)
        #expect(try AgentSupport.logLimit(nil) == 50)
        #expect(AgentSupport.defaultLogLimit == 50)
    }

    @Test func logClearRefusesLimitAndJSON() throws {
        #expect(throws: CLIError.agentLogClearConflict) { try AgentSupport.validateLogOptions(clear: true, limit: "2", json: false) }
        #expect(throws: CLIError.agentLogClearConflict) { try AgentSupport.validateLogOptions(clear: true, limit: nil, json: true) }
        try AgentSupport.validateLogOptions(clear: true, limit: nil, json: false)
        try AgentSupport.validateLogOptions(clear: false, limit: "2", json: true)
    }

    @Test func logYesNeedsClear() throws {
        #expect(throws: CLIError.agentLogYesWithoutClear) {
            try AgentSupport.validateLogOptions(clear: false, limit: nil, json: false, yes: true)
        }
        try AgentSupport.validateLogOptions(clear: true, limit: nil, json: false, yes: true)
        try AgentSupport.validateLogOptions(clear: false, limit: nil, json: false, yes: false)
    }

    @Test func emptyLogSaysSo() {
        #expect(AgentSupport.emptyLogMessage(vm: "agent-1") == "Nessuna attività dell’agente per agent-1.")
    }

    @Test func logClearNeedsYesOrATerminal() throws {
        let (bundle, tmp) = try makeBundle(guest: .macos, agentAccess: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try AgentActivityLog.append(entry(1_700_000_000), thumbnailPNG: nil, in: bundle)

        #expect(throws: CLIError.agentLogClearNeedsConfirmation) {
            _ = try AgentSupport.clearLog(bundle: bundle, yes: false, stdinIsTerminal: false, confirm: { _ in true })
        }
        #expect(try AgentActivityLog.read(in: bundle, limit: nil).count == 1)
        // A terminal that answers no: nothing is cleared.
        #expect(try AgentSupport.clearLog(bundle: bundle, yes: false, stdinIsTerminal: true, confirm: { _ in false }) == false)
        #expect(try AgentActivityLog.read(in: bundle, limit: nil).count == 1)
        // --yes needs no terminal and no question.
        #expect(try AgentSupport.clearLog(bundle: bundle, yes: true, stdinIsTerminal: false, confirm: { _ in
            Issue.record("asked although --yes"); return false }) == true)
        #expect(try AgentActivityLog.read(in: bundle, limit: nil).isEmpty)
        // A terminal that says yes.
        try AgentActivityLog.append(entry(1_700_000_000), thumbnailPNG: nil, in: bundle)
        #expect(try AgentSupport.clearLog(bundle: bundle, yes: false, stdinIsTerminal: true, confirm: { _ in true }))
        #expect(try AgentActivityLog.read(in: bundle, limit: nil).isEmpty)
    }
}
