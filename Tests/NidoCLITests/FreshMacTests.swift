// SPDX-License-Identifier: Apache-2.0
import Dispatch
import Foundation
import Synchronization
import Testing
@testable import NidoCLI
@testable import NidoCore

/// `nido mcp --fresh`'s clone, child and teardown, on temp roots with macOS bundles made by
/// `VMBundle.create` (no disk), a `FakeChild` for the session and `/bin/sh`, `/bin/sleep` for
/// `ProcessChild`.
@Suite(.italian) struct FreshMacTests {
    /// A child that records what it was asked; `ignoresInterrupt` keeps it running after SIGINT,
    /// `ignoredInterrupts` after that many (a VM still starting), `interruptDelay` makes
    /// `interrupt()` slow (to overlap two `end()` calls). `waitForExit` waits its whole timeout
    /// while the child runs.
    final class FakeChild: FreshChild {
        private struct State {
            var running = true
            var interrupts = 0
            var kills = 0
        }

        private let state = Mutex(State())
        private let ignoresInterrupt: Bool
        private let ignoredInterrupts: Int
        private let interruptDelay: Duration

        init(ignoresInterrupt: Bool = false, ignoredInterrupts: Int = 0, interruptDelay: Duration = .zero) {
            self.ignoresInterrupt = ignoresInterrupt
            self.ignoredInterrupts = ignoredInterrupts
            self.interruptDelay = interruptDelay
        }

        var isRunning: Bool { state.withLock { $0.running } }
        var interrupts: Int { state.withLock { $0.interrupts } }
        var kills: Int { state.withLock { $0.kills } }

        func interrupt() {
            if interruptDelay > .zero { Thread.sleep(forTimeInterval: Self.seconds(interruptDelay)) }
            state.withLock {
                $0.interrupts += 1
                if !ignoresInterrupt, $0.interrupts > ignoredInterrupts { $0.running = false }
            }
        }

        func kill() {
            state.withLock {
                $0.kills += 1
                $0.running = false
            }
        }

        func waitForExit(timeout: Duration) -> Bool {
            if isRunning { Thread.sleep(forTimeInterval: Self.seconds(timeout)) }
            return !isRunning
        }

        private static func seconds(_ duration: Duration) -> TimeInterval {
            let parts = duration.components
            return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
        }
    }

    /// Lines handed to `report`, from any thread.
    final class Lines: Sendable {
        private let lines = Mutex<[String]>([])
        var value: [String] { lines.withLock { $0 } }
        func add(_ line: String) { lines.withLock { $0.append(line) } }
    }

    private struct Env {
        let paths: NidoPaths
        let passwords = MemoryGuestPasswordStore()

        init() throws {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("nido-fresh-\(UUID().uuidString)", isDirectory: true)
            paths = NidoPaths(root: dir)
            try paths.ensureRoot()
        }

        func cleanup() { try? FileManager.default.removeItem(at: paths.root) }

        @discardableResult
        func makeVM(
            _ name: String, guest: GuestOS = .macos, isTemplate: Bool = false, agentAccess: Bool? = true,
            disposable: Bool? = nil
        ) throws -> (bundle: VMBundle, id: UUID) {
            let id = UUID()
            let config = VMConfig(
                id: id, name: try VMName(name), guest: guest, cpuCount: 2,
                memoryBytes: 2 << 30, diskBytes: 8 << 30, macAddress: "02:00:00:00:00:01",
                isTemplate: isTemplate, agentAccess: agentAccess, disposable: disposable)
            try passwords.save(try #require(GuestPassword("secret")), vm: id)
            return (try VMBundle.create(config: config, paths: paths), id)
        }

        func session(
            _ vm: (bundle: VMBundle, id: UUID), keep: Bool = false, child: FakeChild,
            stopGrace: Duration = FreshMac.stopGrace, lines: Lines
        ) throws -> FreshMacSession {
            FreshMacSession(
                clone: try vm.bundle.readConfig().name, base: try VMName("base"), bundle: vm.bundle,
                paths: paths, keep: keep, child: child, passwords: passwords, stopGrace: stopGrace,
                report: { lines.add($0) })
        }
    }

    // MARK: - names

    @Test func cloneNameKeepsTheBase() throws {
        #expect(FreshMac.cloneName(base: try VMName("agent"), suffix: "1a2b").rawValue == "agent-fresh-1a2b")

        let long = "b" + String(repeating: "x", count: 62)
        let name = FreshMac.cloneName(base: try VMName(long), suffix: "1a2b")
        #expect(name.rawValue.utf8.count == VMName.maxLength)
        #expect(name.rawValue.hasPrefix(String(long.prefix(52)) + "-fresh-1a2b"))
        #expect(try VMName(name.rawValue) == name)
    }

    @Test func randomSuffixIsFourLowercaseHex() {
        for _ in 0..<100 {
            #expect(FreshMac.randomSuffix().wholeMatch(of: /[0-9a-f]{4}/) != nil)
        }
    }

    // MARK: - checks

    @Test func checkBaseRefusals() throws {
        let env = try Env()
        defer { env.cleanup() }
        func refusal(_ name: String, requireStopped: Bool = true) throws -> String? {
            let bundle = try VMBundle.open(try VMName(name), paths: env.paths)
            do {
                try FreshMac.checkBase(try bundle.readConfig(), bundle: bundle, requireStopped: requireStopped)
                return nil
            } catch {
                return CLISupport.message(for: error)
            }
        }

        try env.makeVM("linux", guest: .linux)
        #expect(try refusal("linux") == CLISupport.message(for: CLIError.agentNotForLinux))
        try env.makeVM("modello", isTemplate: true)
        #expect(try refusal("modello") == CLISupport.message(for: NidoError.isTemplate("modello")))
        try env.makeVM("chiusa", agentAccess: nil)
        #expect(try refusal("chiusa") == CLISupport.message(for: CLIError.agentAccessOff("chiusa")))

        let running = try env.makeVM("attiva")
        let lock = try BundleLock.acquire(running.bundle, owner: .app)
        defer { lock.release() }
        #expect(try refusal("attiva") == CLISupport.message(for: NidoError.cloneNeedsStoppedVM("attiva")))
        #expect(try refusal("attiva", requireStopped: false) == nil)

        let suspended = try env.makeVM("sospesa")
        try Data("state".utf8).write(to: suspended.bundle.stateURL)
        #expect(try refusal("sospesa") == CLISupport.message(for: CLIError.freshBaseSuspended("sospesa")))

        try env.makeVM("usa-e-getta", disposable: true)
        #expect(try refusal("usa-e-getta") == CLISupport.message(for: CLIError.freshBaseIsFresh("usa-e-getta")))
        #expect(try refusal("usa-e-getta", requireStopped: false) != nil)

        try env.makeVM("pronta")
        #expect(try refusal("pronta") == nil)
    }

    @Test func checkLimitRefusesTheThird() throws {
        let env = try Env()
        defer { env.cleanup() }
        let first = try BundleLock.acquire(try env.makeVM("prima").bundle, owner: .cli)
        defer { first.release() }
        let maintenance = try BundleLock.acquire(try env.makeVM("manutenzione").bundle, owner: .cliOperation)
        defer { maintenance.release() }
        try FreshMac.checkLimit(paths: env.paths)

        let second = try BundleLock.acquire(try env.makeVM("seconda").bundle, owner: .app)
        defer { second.release() }
        #expect(throws: NidoError.macVMLimitReached) { try FreshMac.checkLimit(paths: env.paths) }
    }

    // MARK: - prepare

    /// The names a fake `clone` was asked for.
    final class Names: Sendable {
        private let names = Mutex<[String]>([])
        var value: [String] { names.withLock { $0 } }
        func add(_ name: VMName) { names.withLock { $0.append(name.rawValue) } }
    }

    @Test func prepareRetriesATakenName() async throws {
        let env = try Env()
        defer { env.cleanup() }
        try env.makeVM("base")
        let asked = Names()
        let paths = env.paths
        var suffixes = ["aaaa", "bbbb"].makeIterator()

        let bundle = try await FreshMac.prepare(
            base: try VMName("base"), paths: env.paths, keep: false,
            clone: { name in
                asked.add(name)
                if name.rawValue.hasSuffix("aaaa") { throw NidoError.alreadyExists(name.rawValue) }
                let config = VMConfig(
                    id: UUID(), name: name, guest: .macos, cpuCount: 2, memoryBytes: 2 << 30, diskBytes: 8 << 30,
                    macAddress: "02:00:00:00:00:02")
                return try VMBundle.create(config: config, paths: paths)
            },
            suffix: { suffixes.next()! })

        let config = try bundle.readConfig()
        #expect(asked.value == ["base-fresh-aaaa", "base-fresh-bbbb"])
        #expect(config.name.rawValue == "base-fresh-bbbb")
        #expect(config.agentAccess == true)
        #expect(config.disposable == true)
    }

    @Test func prepareWithKeepMakesAnOrdinaryVM() async throws {
        let env = try Env()
        defer { env.cleanup() }
        try env.makeVM("base")
        let paths = env.paths

        let bundle = try await FreshMac.prepare(
            base: try VMName("base"), paths: env.paths, keep: true,
            clone: { name in
                let config = VMConfig(
                    id: UUID(), name: name, guest: .macos, cpuCount: 2, memoryBytes: 2 << 30, diskBytes: 8 << 30,
                    macAddress: "02:00:00:00:00:03")
                return try VMBundle.create(config: config, paths: paths)
            },
            suffix: { "cccc" })

        let config = try bundle.readConfig()
        #expect(config.agentAccess == true)
        #expect(config.disposable == nil)
    }

    /// A fake `clone`: a new macOS VM named as asked.
    private static func fakeClone(_ paths: NidoPaths) -> @Sendable (VMName) async throws -> VMBundle {
        { name in
            let config = VMConfig(
                id: UUID(), name: name, guest: .macos, cpuCount: 2, memoryBytes: 2 << 30, diskBytes: 8 << 30,
                macAddress: "02:00:00:00:00:04")
            return try VMBundle.create(config: config, paths: paths)
        }
    }

    @Test func prepareRecordsTheBase() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let base = try env.makeVM("base")

        let bundle = try await FreshMac.prepare(
            base: try VMName("base"), paths: env.paths, keep: false, clone: Self.fakeClone(env.paths),
            suffix: { "dddd" })

        let config = try bundle.readConfig()
        #expect(config.disposable == true)
        #expect(config.freshBaseID == base.id)
        #expect(try base.bundle.readConfig().freshBaseID == nil)
    }

    /// The base is found in any case, as every other step finds it (`VMBundle.open`), also on a
    /// case-sensitive volume.
    @Test func prepareFindsTheBaseInAnyCase() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let base = try env.makeVM("base")

        let bundle = try await FreshMac.prepare(
            base: try VMName("Base"), paths: env.paths, keep: false, clone: Self.fakeClone(env.paths),
            suffix: { "ffff" })

        #expect(try bundle.readConfig().freshBaseID == base.id)
    }

    /// A kept copy is an ordinary VM: it never follows its base's list.
    @Test func keptCopyHasNoBase() async throws {
        let env = try Env()
        defer { env.cleanup() }
        try env.makeVM("base")

        let bundle = try await FreshMac.prepare(
            base: try VMName("base"), paths: env.paths, keep: true, clone: Self.fakeClone(env.paths),
            suffix: { "eeee" })

        let config = try bundle.readConfig()
        #expect(config.disposable == nil)
        #expect(config.freshBaseID == nil)
    }

    @Test func prepareGivesUpAfterFiveNames() async throws {
        let env = try Env()
        defer { env.cleanup() }
        try env.makeVM("base")
        let asked = Names()
        var count = 0

        await #expect(throws: NidoError.self) {
            try await FreshMac.prepare(
                base: try VMName("base"), paths: env.paths, keep: false,
                clone: { name in
                    asked.add(name)
                    throw NidoError.alreadyExists(name.rawValue)
                },
                suffix: {
                    count += 1
                    return String(format: "%04x", count)
                })
        }
        #expect(asked.value.count == 5)
    }

    // MARK: - ProcessChild

    private static func temporaryLog() throws -> (url: URL, handle: FileHandle) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nido-fresh-log-\(UUID().uuidString).log")
        #expect(FileManager.default.createFile(atPath: url.path, contents: nil))
        return (url, try FileHandle(forWritingTo: url))
    }

    @Test func childOutputGoesToTheLog() throws {
        let log = try Self.temporaryLog()
        defer { try? FileManager.default.removeItem(at: log.url) }
        let child = try ProcessChild.launch(
            executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "echo out; echo err >&2; cat"],
            output: log.handle)
        defer { if child.isRunning { child.kill() } }

        #expect(child.waitForExit(timeout: .seconds(2)))
        #expect(!child.isRunning)
        let text = try String(contentsOf: log.url, encoding: .utf8)
        #expect(text.contains("out"))
        #expect(text.contains("err"))
    }

    @Test func interruptEndsAChild() throws {
        let log = try Self.temporaryLog()
        defer { try? FileManager.default.removeItem(at: log.url) }
        let child = try ProcessChild.launch(
            executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], output: log.handle)
        defer { if child.isRunning { child.kill() } }
        #expect(child.isRunning)

        child.interrupt()

        #expect(child.waitForExit(timeout: .seconds(2)))
    }

    @Test func stubbornChildIsKilled() throws {
        let log = try Self.temporaryLog()
        defer { try? FileManager.default.removeItem(at: log.url) }
        let child = try ProcessChild.launch(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "trap \"\" INT; echo ready; exec /bin/sleep 30"], output: log.handle)
        defer { if child.isRunning { child.kill() } }
        // SIGINT before the trap is set would end the shell: wait for the line that follows it.
        let deadline = Date().addingTimeInterval(2)
        while (try? String(contentsOf: log.url, encoding: .utf8))?.contains("ready") != true, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }

        child.interrupt()
        #expect(!child.waitForExit(timeout: .milliseconds(500)))
        child.kill()

        #expect(child.waitForExit(timeout: .seconds(2)))
    }

    // MARK: - FreshMacSession.end

    @Test func endInterruptsThenDeletes() throws {
        let env = try Env()
        defer { env.cleanup() }
        let vm = try env.makeVM("base-fresh-0001", disposable: true)
        let child = FakeChild()
        let lines = Lines()

        try env.session(vm, child: child, lines: lines).end()

        #expect(child.interrupts == 1)
        #expect(child.kills == 0)
        #expect(!FileManager.default.fileExists(atPath: vm.bundle.url.path))
        #expect(try !env.passwords.contains(vm: vm.id))
        #expect(lines.value == [L10n.string("Fresh Mac \("base-fresh-0001") deleted.")])
    }

    @Test func endKillsAChildThatDoesNotStop() throws {
        let env = try Env()
        defer { env.cleanup() }
        let vm = try env.makeVM("base-fresh-0002", disposable: true)
        let child = FakeChild(ignoresInterrupt: true)
        let lines = Lines()

        try env.session(vm, child: child, stopGrace: .milliseconds(100), lines: lines).end()

        #expect(child.interrupts == 1)
        #expect(child.kills == 1)
        #expect(
            lines.value == [
                L10n.string("\("base-fresh-0002") didn’t stop within 60 seconds: its process was ended."),
                L10n.string("Fresh Mac \("base-fresh-0002") deleted."),
            ])
        #expect(!FileManager.default.fileExists(atPath: vm.bundle.url.path))
    }

    @Test func endInterruptsAgainUntilTheChildStops() throws {
        let env = try Env()
        defer { env.cleanup() }
        let vm = try env.makeVM("base-fresh-0008", disposable: true)
        let child = FakeChild(ignoredInterrupts: 1)
        let lines = Lines()
        let started = ContinuousClock.now

        try env.session(vm, child: child, lines: lines).end()

        #expect(child.interrupts == 2)
        #expect(child.kills == 0)
        #expect(ContinuousClock.now - started < .seconds(5))
        #expect(lines.value == [L10n.string("Fresh Mac \("base-fresh-0008") deleted.")])
    }

    @Test func endCountsACopyAlreadyGoneAsDeleted() throws {
        let env = try Env()
        defer { env.cleanup() }
        let vm = try env.makeVM("base-fresh-0009", disposable: true)
        let lines = Lines()
        let session = try env.session(vm, child: FakeChild(), lines: lines)
        // The child deleted its copy when its VM stopped.
        try DisposableVMs.delete(try VMName("base-fresh-0009"), paths: env.paths, passwords: env.passwords)

        session.end()

        #expect(lines.value == [L10n.string("Fresh Mac \("base-fresh-0009") deleted.")])
    }

    @Test func endWithKeepKeepsAnOrdinaryVM() throws {
        let env = try Env()
        defer { env.cleanup() }
        let vm = try env.makeVM("base-fresh-0003")
        let before = try Data(contentsOf: vm.bundle.configURL)
        let lines = Lines()

        try env.session(vm, keep: true, child: FakeChild(), lines: lines).end()

        #expect(try Data(contentsOf: vm.bundle.configURL) == before)
        #expect(try env.passwords.contains(vm: vm.id))
        #expect(lines.value == [L10n.string("Fresh Mac \("base-fresh-0003") stopped and kept: it is an ordinary VM now.")])
    }

    @Test func endNeverDeletesANonDisposable() throws {
        let env = try Env()
        defer { env.cleanup() }
        let vm = try env.makeVM("base-fresh-0004", disposable: true)
        try VMControl.editConfig(vm.bundle, owner: .cliOperation) { $0.disposable = nil }
        let lines = Lines()

        try env.session(vm, child: FakeChild(), lines: lines).end()

        #expect(FileManager.default.fileExists(atPath: vm.bundle.url.path))
        #expect(try env.passwords.contains(vm: vm.id))
        #expect(lines.value == [L10n.string("Fresh Mac \("base-fresh-0004") kept: it is no longer marked disposable.")])
    }

    @Test func endReportsAFailedDelete() throws {
        let env = try Env()
        defer { env.cleanup() }
        let vm = try env.makeVM("base-fresh-0006", disposable: true)
        let lines = Lines()
        let session = try env.session(vm, child: FakeChild(), lines: lines)
        let lock = try BundleLock.acquire(vm.bundle, owner: .app)
        defer { lock.release() }

        session.end()

        #expect(FileManager.default.fileExists(atPath: vm.bundle.url.path))
        let reason = CLISupport.message(for: NidoError.alreadyRunning(pid: getpid()))
        #expect(
            lines.value == [
                L10n.string(
                    "Couldn’t delete the fresh Mac \("base-fresh-0006"): \(reason). Delete it with nido delete \("base-fresh-0006").")
            ])
    }

    @Test func endRunsOnce() throws {
        let env = try Env()
        defer { env.cleanup() }
        let vm = try env.makeVM("base-fresh-0005", disposable: true)
        let child = FakeChild(interruptDelay: .milliseconds(300))
        let lines = Lines()
        let session = try env.session(vm, child: child, lines: lines)
        let linesAtReturn = Mutex<[Int]>([])

        let group = DispatchGroup()
        for _ in 0..<2 {
            DispatchQueue.global().async(group: group) {
                session.end()
                linesAtReturn.withLock { $0.append(lines.value.count) }
            }
        }
        #expect(group.wait(timeout: .now() + 5) == .success)

        #expect(child.interrupts == 1)
        #expect(lines.value.count == 1)
        #expect(linesAtReturn.withLock { $0 } == [1, 1])
    }

    // MARK: - childEndedReason

    @Test func childEndedReasonQuotesTheLastLogLine() throws {
        let env = try Env()
        defer { env.cleanup() }
        let vm = try env.makeVM("base-fresh-0007", disposable: true)
        let child = FakeChild()
        func writeLog(_ text: String) throws {
            let handle = try vm.bundle.openFreshStartLog()
            try handle.write(contentsOf: Data(text.utf8))
            try handle.close()
        }
        // As `nido mcp --fresh`: the log is made for the child before the session.
        try writeLog("")
        let session = try env.session(vm, child: child, lines: Lines())
        func expected(_ detail: String) -> String {
            L10n.string("the fresh Mac \("base-fresh-0007") stopped: \(detail)")
        }

        #expect(session.childEndedReason() == nil)
        child.kill()

        let error = "Error: \(NidoError.macVMLimitReached.localizedDescription)"
        try writeLog("x\n\(error)\n\n")
        #expect(session.childEndedReason() == expected(error))

        try writeLog("")
        #expect(session.childEndedReason() == expected(vm.bundle.freshStartLogURL.path))

        try writeLog("rosso \u{1B}[31m\n")
        let colored = try #require(session.childEndedReason())
        #expect(colored == expected("rosso \\u{1B}[31m"))

        try writeLog(String(repeating: "y", count: 300) + "\n")
        #expect(session.childEndedReason() == expected(String(repeating: "y", count: 200)))
    }

    @Test func childEndedReasonQuotesTheLogOfADeletedCopy() throws {
        let env = try Env()
        defer { env.cleanup() }
        let vm = try env.makeVM("base-fresh-0010", disposable: true)
        let handle = try vm.bundle.openFreshStartLog()
        let session = try env.session(vm, child: FakeChild(), lines: Lines())
        let error = "Error: \(NidoError.macVMLimitReached.localizedDescription)"
        try handle.write(contentsOf: Data("\(error)\n".utf8))
        try handle.close()

        // The child deleted its copy, the log with it, then ended.
        try DisposableVMs.delete(try VMName("base-fresh-0010"), paths: env.paths, passwords: env.passwords)
        session.end()

        #expect(session.childEndedReason() == L10n.string("the fresh Mac \("base-fresh-0010") stopped: \(error)"))
    }

    // MARK: - deleteAfterRun

    @Test func deleteAfterRunDeletesADisposableCopy() throws {
        let env = try Env()
        defer { env.cleanup() }
        let vm = try env.makeVM("base-fresh-0011", disposable: true)
        let lines = Lines()

        #expect(FreshMac.deleteAfterRun(
            try VMName("base-fresh-0011"), paths: env.paths, passwords: env.passwords, report: lines.add))

        #expect(!FileManager.default.fileExists(atPath: vm.bundle.url.path))
        #expect(try !env.passwords.contains(vm: vm.id))
        #expect(lines.value == [L10n.string("Fresh Mac \("base-fresh-0011") deleted.")])
    }

    @Test func deleteAfterRunKeepsAnOrdinaryVM() throws {
        let env = try Env()
        defer { env.cleanup() }
        let vm = try env.makeVM("base-fresh-0012")
        let lines = Lines()

        #expect(!FreshMac.deleteAfterRun(
            try VMName("base-fresh-0012"), paths: env.paths, passwords: env.passwords, report: lines.add))

        #expect(FileManager.default.fileExists(atPath: vm.bundle.url.path))
        #expect(try env.passwords.contains(vm: vm.id))
        #expect(lines.value.isEmpty)
    }

    @Test func deleteAfterRunNeverDeletesARunningVM() throws {
        let env = try Env()
        defer { env.cleanup() }
        let vm = try env.makeVM("base-fresh-0013", disposable: true)
        let lines = Lines()
        let lock = try BundleLock.acquire(vm.bundle, owner: .app)
        defer { lock.release() }

        #expect(!FreshMac.deleteAfterRun(
            try VMName("base-fresh-0013"), paths: env.paths, passwords: env.passwords, report: lines.add))

        #expect(FileManager.default.fileExists(atPath: vm.bundle.url.path))
        let reason = CLISupport.message(for: NidoError.alreadyRunning(pid: getpid()))
        #expect(
            lines.value == [
                L10n.string(
                    "Couldn’t delete the fresh Mac \("base-fresh-0013"): \(reason). Delete it with nido delete \("base-fresh-0013").")
            ])
    }

    // MARK: - status note

    @Test func statusNoteSaysWhatHappensAtTheEnd() {
        #expect(
            FreshMac.statusNote(clone: "base-fresh-1a2b", base: "base", keep: false)
                == "This Mac is base-fresh-1a2b, a fresh copy of base: it is deleted when this session ends.")
        #expect(
            FreshMac.statusNote(clone: "base-fresh-1a2b", base: "base", keep: true)
                == "This Mac is base-fresh-1a2b, a fresh copy of base: it is kept, stopped, when this session ends.")
    }
}
