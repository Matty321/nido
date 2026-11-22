// SPDX-License-Identifier: Apache-2.0
import Darwin
import Dispatch
import Foundation
import NidoCore
import Synchronization

/// `nido mcp --fresh <base>`: a disposable copy of a stopped macOS VM for one agent session, run
/// by a child `nido start <copy> --parent-pid <pid>` and stopped when the session ends
/// (`FreshMacSession`); the child deletes it when its VM stops (`deleteAfterRun`). The base is
/// only read, by `VMCloner`, under its lock. Nothing here writes to stdout: the MCP server's
/// stdout carries only protocol lines.
public enum FreshMac {
    /// Apple's limit of macOS VMs running at once on a Mac.
    public static let maxRunningMacs = 2
    /// How long the copy has, from the child's launch, to answer Nido Agent's `status`.
    public static let readinessLimit: Duration = .seconds(180)
    /// How long the child has to stop after SIGINT before it gets SIGKILL.
    public static let stopGrace: Duration = .seconds(60)
    /// SIGINT is sent again at this interval until the child stops: `nido start` ignores a stop
    /// while its VM is still starting.
    static let interruptInterval: Duration = .seconds(1)

    /// Names tried when the one drawn is taken (`NidoError.alreadyExists`).
    static let maxNameTries = 5
    /// What follows the base in a copy's name, before the suffix.
    static let nameInfix = "-fresh-"
    /// The base's bytes kept in a copy's name: room for `-fresh-` and 4 hex digits.
    static let baseBytesInName = VMName.maxLength - 11

    /// 4 random lowercase hex digits.
    public static func randomSuffix() -> String {
        String(format: "%04x", UInt16.random(in: .min ... .max))
    }

    /// `<base>-fresh-<suffix>`, the base cut to its first 52 bytes (names are ASCII). `suffix` is
    /// 4 lowercase hex digits (`randomSuffix`), which keeps the name valid.
    public static func cloneName(base: VMName, suffix: String) -> VMName {
        let kept = String(decoding: base.rawValue.utf8.prefix(baseBytesInName), as: UTF8.self)
        // A prefix of a valid name starts with its alphanumeric and holds no "..": still valid
        // with `-fresh-` and hex digits after it.
        return try! VMName(kept + nameInfix + suffix)
    }

    /// Refuses a base that can't be served fresh: Linux, a template, agent access off, a fresh
    /// Mac of a session (deleted when that session ends or by a sweep) and, with
    /// `requireStopped`, a running VM or one with a saved state (its copy would boot from a disk
    /// in the middle of a session).
    public static func checkBase(_ config: VMConfig, bundle: VMBundle, requireStopped: Bool) throws {
        let name = config.name.rawValue
        guard config.guest == .macos else { throw CLIError.agentNotForLinux }
        guard !config.isTemplate else { throw NidoError.isTemplate(name) }
        guard config.agentAccess == true else { throw CLIError.agentAccessOff(name) }
        guard config.disposable != true else { throw CLIError.freshBaseIsFresh(name) }
        guard requireStopped else { return }
        if BundleLock.holder(bundle) != nil { throw NidoError.cloneNeedsStoppedVM(name) }
        var info = stat()
        if lstat(bundle.stateURL.path, &info) == 0 { throw CLIError.freshBaseSuspended(name) }
    }

    /// Refuses a third macOS VM: Apple allows `maxRunningMacs` at once.
    public static func checkLimit(paths: NidoPaths) throws {
        if RunningVMs.macOSCount(paths: paths) >= maxRunningMacs { throw NidoError.macVMLimitReached }
    }

    /// Makes the copy: `clone` under a new name (another suffix when the name is taken, at most
    /// `maxNameTries` names), then marks it `agentAccess` and, unless `keep`, `disposable` with
    /// the base's `id` (`freshBaseID`: the base's allow/deny reaches it). A kept copy is an
    /// ordinary VM from the start: nothing ever deletes it and it never follows its base. A copy
    /// whose marks can't be written is deleted again. Production passes
    /// `{ try await VMCloner(…).clone(base, as: $0, owner: .cliOperation) }`.
    public static func prepare(
        base: VMName, paths: NidoPaths, keep: Bool, clone: @Sendable (VMName) async throws -> VMBundle,
        suffix: () -> String = FreshMac.randomSuffix
    ) async throws -> VMBundle {
        let baseID = try VMBundle.open(base, paths: paths).readConfig().id
        let (name, bundle) = try await cloneUnderFreeName(base: base, clone: clone, suffix: suffix)
        do {
            try VMControl.editConfig(bundle, owner: .cliOperation) {
                $0.agentAccess = true
                if !keep {
                    $0.disposable = true
                    $0.freshBaseID = baseID
                }
            }
        } catch {
            try? VMControl.deleteVM(name, paths: paths, owner: .cliOperation)
            throw error
        }
        return bundle
    }

    private static func cloneUnderFreeName(
        base: VMName, clone: @Sendable (VMName) async throws -> VMBundle, suffix: () -> String
    ) async throws -> (VMName, VMBundle) {
        var tries = 1
        while true {
            let name = cloneName(base: base, suffix: suffix())
            do {
                return (name, try await clone(name))
            } catch NidoError.alreadyExists(_) where tries < maxNameTries {
                tries += 1
            }
        }
    }

    /// The end of a `nido start --parent-pid` run, its bundle lock released: the VM stopped, for
    /// whatever reason (the parent ended, a signal, the guest shut down, the start failed). A copy
    /// still marked disposable is deleted (`DisposableVMs.delete`: never another VM, never one
    /// that runs) and the outcome is one line to `report` (`fresh-start.log`, deleted with the
    /// copy). False when the VM was not deleted.
    @discardableResult
    public static func deleteAfterRun(
        _ name: VMName, paths: NidoPaths, passwords: any GuestPasswordStore = KeychainGuestPasswordStore(),
        report: (String) -> Void
    ) -> Bool {
        do {
            guard try DisposableVMs.delete(name, paths: paths, passwords: passwords) else { return false }
            report(L10n.string("Fresh Mac \(name.rawValue) deleted."))
            return true
        } catch {
            let reason = CLISupport.message(for: error)
            report(L10n.string(
                "Couldn’t delete the fresh Mac \(name.rawValue): \(reason). Delete it with nido delete \(name.rawValue)."))
            return false
        }
    }

    /// The note `status` adds for the model (English, like the MCP `instructions`).
    public static func statusNote(clone: String, base: String, keep: Bool) -> String {
        keep
            ? "This Mac is \(clone), a fresh copy of \(base): it is kept, stopped, when this session ends."
            : "This Mac is \(clone), a fresh copy of \(base): it is deleted when this session ends."
    }
}

/// The process that runs the copy (`nido start <copy> --parent-pid <pid>`), or a fake in tests.
public protocol FreshChild: AnyObject, Sendable {
    var isRunning: Bool { get }
    /// SIGINT: `nido start` stops its VM and exits.
    func interrupt()
    /// SIGKILL.
    func kill()
    /// True when the process has ended within `timeout` (at once if it already had).
    func waitForExit(timeout: Duration) -> Bool
}

/// A `FreshChild` run with Foundation's `Process`: stdin `/dev/null`, stdout and stderr both to
/// `output`, the environment inherited unchanged.
public final class ProcessChild: FreshChild, @unchecked Sendable {
    // @unchecked: `process` is only read for its identifier after launch; the exit is tracked by
    // `exited`, a DispatchGroup left once by the termination handler.
    private let process: Process
    private let exited: DispatchGroup

    private init(process: Process, exited: DispatchGroup) {
        self.process = process
        self.exited = exited
    }

    public static func launch(executable: URL, arguments: [String], output: FileHandle) throws -> ProcessChild {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = output
        let exited = DispatchGroup()
        exited.enter()
        process.terminationHandler = { _ in exited.leave() }
        do {
            try process.run()
        } catch {
            // Never launched: no termination handler will leave the group.
            exited.leave()
            throw error
        }
        return ProcessChild(process: process, exited: exited)
    }

    public var isRunning: Bool { exited.wait(timeout: .now()) == .timedOut }

    public func interrupt() { signal(SIGINT) }

    public func kill() { signal(SIGKILL) }

    public func waitForExit(timeout: Duration) -> Bool {
        exited.wait(timeout: .now() + timeout.timeInterval) == .success
    }

    /// Only while running: an ended child's PID may belong to another process by now.
    private func signal(_ number: Int32) {
        guard isRunning else { return }
        _ = Darwin.kill(process.processIdentifier, number)
    }
}

/// One `nido mcp --fresh` session's copy and its child: `end()` stops the child, which deletes
/// the copy itself when its VM stops (`FreshMac.deleteAfterRun`), then deletes what the child
/// could not (killed, or ended before it could). A `keep` copy is an ordinary VM from the start
/// and stays. Every human line goes to `report`.
public final class FreshMacSession: Sendable {
    /// Bytes read from the end of `fresh-start.log` for `childEndedReason`.
    static let logTailBytes = 4096
    /// Characters of the log line quoted by `childEndedReason`.
    static let quotedLineLength = 200

    private let clone: VMName
    private let base: VMName
    private let bundle: VMBundle
    private let paths: NidoPaths
    private let keep: Bool
    private let child: any FreshChild
    private let passwords: any GuestPasswordStore
    private let stopGrace: Duration
    private let report: @Sendable (String) -> Void
    /// True once `end()` has done its work; held while it does it.
    private let ended = Mutex(false)
    /// `fresh-start.log`, opened read-only by `init`: its last line can still be read once the
    /// child has deleted the copy, the log with it. -1 when it couldn't be opened then.
    private let log: Int32

    public init(
        clone: VMName, base: VMName, bundle: VMBundle, paths: NidoPaths, keep: Bool, child: any FreshChild,
        passwords: any GuestPasswordStore = KeychainGuestPasswordStore(), stopGrace: Duration = FreshMac.stopGrace,
        report: @escaping @Sendable (String) -> Void
    ) {
        self.clone = clone
        self.base = base
        self.bundle = bundle
        self.paths = paths
        self.keep = keep
        self.child = child
        self.passwords = passwords
        self.stopGrace = stopGrace
        self.report = report
        log = Self.openLog(bundle.freshStartLogURL)
    }

    deinit {
        if log >= 0 { Darwin.close(log) }
    }

    /// Stops the child (SIGINT, again every `FreshMac.interruptInterval`, SIGKILL after
    /// `stopGrace`), then, unless `keep`, deletes the copy if the child has not. Runs once: a
    /// concurrent caller waits until the first one is done.
    public func end() {
        ended.withLock { done in
            guard !done else { return }
            defer { done = true }
            stopChild()
            if keep {
                report(L10n.string("Fresh Mac \(clone.rawValue) stopped and kept: it is an ordinary VM now."))
            } else {
                deleteClone()
            }
        }
    }

    /// Nil while the child runs; otherwise why the copy is gone, quoting the last line of
    /// `fresh-start.log` (or naming the log when it has none).
    public func childEndedReason() -> String? {
        guard !child.isRunning else { return nil }
        let url = bundle.freshStartLogURL
        let detail = (log >= 0 ? Self.lastLine(fd: log) : Self.lastLine(of: url)) ?? url.path
        return L10n.string("the fresh Mac \(clone.rawValue) stopped: \(detail)")
    }

    /// SIGINT until the child ends: one sent while its VM is still starting is not taken.
    private func stopChild() {
        guard child.isRunning else { return }
        let deadline = ContinuousClock.now + stopGrace
        child.interrupt()
        while !child.waitForExit(timeout: min(FreshMac.interruptInterval, max(.zero, deadline - .now))) {
            guard ContinuousClock.now < deadline else {
                child.kill()
                _ = child.waitForExit(timeout: .seconds(10))
                report(L10n.string("\(clone.rawValue) didn’t stop within 60 seconds: its process was ended."))
                return
            }
            child.interrupt()
        }
    }

    /// What the child left: a copy it could not delete (killed, say). Gone already counts as
    /// deleted.
    private func deleteClone() {
        let name = clone.rawValue
        do {
            if try DisposableVMs.delete(clone, paths: paths, passwords: passwords) {
                report(L10n.string("Fresh Mac \(name) deleted."))
            } else {
                report(L10n.string("Fresh Mac \(name) kept: it is no longer marked disposable."))
            }
        } catch NidoError.notFound(_) {
            report(L10n.string("Fresh Mac \(name) deleted."))
        } catch {
            let reason = CLISupport.message(for: error)
            report(L10n.string("Couldn’t delete the fresh Mac \(name): \(reason). Delete it with nido delete \(name)."))
        }
    }

    /// The last non-blank line in the last `logTailBytes` of `url`, controls escaped, cut to
    /// `quotedLineLength` characters; nil when there is none or the file isn't a regular file.
    static func lastLine(of url: URL) -> String? {
        let fd = openLog(url)
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }
        return lastLine(fd: fd)
    }

    /// `lastLine(of:)` on an open descriptor, read with `pread` (no shared offset).
    static func lastLine(fd: Int32) -> String? {
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        let start = max(0, Int64(info.st_size) - Int64(logTailBytes))
        var data = [UInt8](repeating: 0, count: logTailBytes)
        let count = data.withUnsafeMutableBytes { pread(fd, $0.baseAddress, logTailBytes, off_t(start)) }
        guard count >= 0 else { return nil }
        let line = String(decoding: data.prefix(count), as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty }
        guard let line else { return nil }
        return String(ConsoleSanitizer.escapingControls(line).prefix(quotedLineLength))
    }

    /// `url` opened read-only; -1 when it can't be. O_NOFOLLOW: never a link; O_NONBLOCK: never
    /// hang on a FIFO.
    static func openLog(_ url: URL) -> Int32 {
        Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    }
}

extension Duration {
    /// Seconds, for Dispatch's timeouts.
    fileprivate var timeInterval: TimeInterval {
        let parts = components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }
}
