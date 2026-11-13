// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import Dispatch
import Foundation
import NidoCLI
import NidoCore

struct StartCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "start",
        abstract: L10n.string("Start a VM in the foreground (Ctrl-C stops it); a suspended VM resumes."),
        discussion: L10n.string("A macOS VM starts without a window: use it with nido ssh once you’ve completed Setup Assistant in Nido.")
    )

    @Argument(help: ArgumentHelp(L10n.string("VM name.")))
    var name: String

    @Flag(help: ArgumentHelp(L10n.string("Also show the serial console in the terminal (with escape sequences removed); console.log records it either way. Linux VMs only.")))
    var console = false

    @MainActor
    func run() async throws {
        // A closed stdout/stderr (e.g. the terminal went away) must not kill the VM process.
        signal(SIGPIPE, SIG_IGN)
        // `nido stop --suspend` may signal as soon as the lock names this process: its default
        // action would kill the process before the VM is even created.
        signal(VMControl.suspendSignal, SIG_IGN)
        // gvproxy left by a Nido killed with -9 (its lock is free) keeps its SSH port on 127.0.0.1:
        // ended now, whatever VM starts, not only at the next controlled start.
        GvproxyProcess.sweepOrphans()
        let (vmName, bundle) = try Terminal.openBundle(name)
        // A macOS guest has no serial console: refused before anything is touched.
        try CLISupport.checkConsoleFlag(console, guest: try bundle.readConfig().guest)
        // Lock first: a second start fails here without touching the bundle.
        let lock = try BundleLock.acquire(bundle, owner: .cli)
        defer { lock.release() }
        // An interrupted snapshot restore is finished or undone first; refused if it left files.
        try SnapshotStore(bundle: bundle).recoverBeforeUse()
        // Guest memory against the Mac's RAM: a warning only, the VM starts anyway.
        if let config = try? bundle.readConfig() {
            let headroom = MemoryHeadroom.check(
                starting: bundle, memoryBytes: config.memoryBytes,
                paths: NidoPaths(root: bundle.url.deletingLastPathComponent()))
            if let warning = headroom.warning {
                Terminal.error(L10n.string("Warning: \(warning) (\(headroom.detail))."))
            }
        }

        // Controlled network: one line per block, merged per destination and port for 10 s; the
        // count of merged repeats is printed when their window is over (never hidden). Cuts
        // always print. Local noise (IPv6 multicast, broadcast: `EgressEvent.isLocalNoise`) is
        // not printed, as the app does not notify it. Every block is also in the VM's egress.log.
        let notices = EgressNoticeMerger()
        let session = try VMSession(bundle: bundle, mirrorsConsole: console, egressEvents: { event in
            guard !event.isLocalNoise else { return }
            for line in notices.lines(for: event, now: Date()) { Terminal.error(CLISupport.networkNoticeLine(line)) }
        })
        let noticeTimer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        noticeTimer.schedule(deadline: .now() + 2, repeating: 2, leeway: .milliseconds(500))
        // Sendable: runs on a utility queue, not on the main actor of `run()`.
        noticeTimer.setEventHandler { @Sendable in
            for line in notices.flush(now: Date()) { Terminal.error(CLISupport.networkNoticeLine(line)) }
        }
        noticeTimer.resume()
        defer { noticeTimer.cancel() }
        for warning in session.warnings { Terminal.error(L10n.string("Warning: \(ConsoleSanitizer.escapingControls(warning))")) }
        // --console: the guest's output, sanitised (no escape sequences reach the terminal).
        let mirror: ConsoleMirror? = console ? session.serialConsole.map { ConsoleMirror(output: $0.output) } : nil
        defer { session.serialConsole?.close() }
        let stopper = SignalStopper(session: session, bundle: bundle, name: vmName.rawValue)
        stopper.install()
        defer { stopper.cancel() }

        let (shown, pid) = (vmName.rawValue, String(getpid()))
        switch try await session.startOrResume() {
        case .coldStart:
            Terminal.error(L10n.string("VM \(shown) started (pid \(pid)). Press Ctrl-C to stop it."))
        case .resumed:
            Terminal.error(L10n.string("VM \(shown) resumed from its saved state (pid \(pid)). Press Ctrl-C to stop it."))
        case .discarded(let warning):
            // May carry Virtualization.framework's reason: printed without control characters.
            // A period ends the sentence alike in the five languages.
            Terminal.error(L10n.string("Warning: \(ConsoleSanitizer.escapingControls(warning) + ".")"))
            Terminal.error(L10n.string("VM \(shown) started from a cold boot (pid \(pid)). Press Ctrl-C to stop it."))
        case .stoppedWhileResuming:
            Terminal.error(L10n.string("Stop requested while resuming: the VM \(shown) wasn’t resumed and its saved state was discarded."))
        }

        let final: VMRunState = await withCheckedContinuation { continuation in
            if Self.isFinal(session.state) {
                continuation.resume(returning: session.state)
                return
            }
            session.onStateChange = { [weak session] state in
                guard Self.isFinal(state) else { return }
                session?.onStateChange = nil
                continuation.resume(returning: state)
            }
        }
        // The machine is gone: the relay delivers its last events (stderr lines, egress.log)
        // before the process exits, waited for off the main actor.
        if let relay = session.egressRelay {
            await Task.detached { relay.shutdownAndWait() }.value
        }
        // The machine is gone: read what is left in the console pipe into console.log, end the
        // console and let the mirror print what it already read, for at most 2 s.
        await session.serialConsole?.closeAndWait()
        if let mirror, !(await mirror.finish(within: ConsoleMirror.finishTimeout)) {
            // stdout does not drain (a pipe nobody reads, a terminal stopped with Ctrl-S): do not
            // keep the lock, nor write more to the terminal (stderr may be blocked as well).
            lock.release()
            Foundation.exit(final == .stopped ? 0 : 1)
        }
        if case .error(let reason) = final {
            throw CLIError.vmFailed(reason)
        }
        // Decided by the suspend's own result: the VM reports stopped before the suspend returns.
        let suspended = await stopper.suspendOutcome()
        Terminal.error(suspended ? L10n.string("VM \(shown) suspended.") : L10n.string("VM \(shown) stopped."))
    }

    private static func isFinal(_ state: VMRunState) -> Bool {
        switch state {
        case .stopped, .error: true
        case .starting, .running, .pausing, .paused, .resuming, .stopping: false
        }
    }
}

/// Turns the first SIGINT/SIGTERM/SIGHUP into a graceful `VMSession.stop`, and
/// `VMControl.suspendSignal` (`nido stop --suspend`) into `VMSession.suspend`: the VM stops with
/// its state saved and the process exits. When it cannot suspend, the process answers the waiting
/// `nido stop --suspend` (`VMControl.writeSuspendResult`) at once. A stop asked during a suspend
/// is kept and carried out if the suspend fails.
@MainActor
private final class SignalStopper {
    private let session: VMSession
    private let bundle: VMBundle
    private let name: String
    private var sources: [any DispatchSourceSignal] = []
    private var requested = false
    /// A stop signal that arrived while suspending.
    private var stopAfterSuspend = false
    private var suspendTask: Task<Bool, Never>?

    init(session: VMSession, bundle: VMBundle, name: String) {
        self.session = session
        self.bundle = bundle
        self.name = name
    }

    func install() {
        for signalNumber in [SIGINT, SIGTERM, SIGHUP] {
            // Default disposition would kill the process before the guest can shut down.
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.requestStop() }
            }
            source.resume()
            sources.append(source)
        }
        signal(VMControl.suspendSignal, SIG_IGN)
        let suspendSource = DispatchSource.makeSignalSource(signal: VMControl.suspendSignal, queue: .main)
        suspendSource.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.requestSuspend() }
        }
        suspendSource.resume()
        sources.append(suspendSource)
    }

    func cancel() {
        sources.forEach { $0.cancel() }
        sources.removeAll()
    }

    /// True when the VM was suspended (waits for a suspend in progress to finish).
    func suspendOutcome() async -> Bool {
        guard let suspendTask else { return false }
        return await suspendTask.value
    }

    private func requestSuspend() {
        guard suspendTask == nil else { return }
        let refusal: CLISupport.SuspendRefusal? = if requested {
            .alreadyStopping
        } else if session.state == .stopped, session.acceptsStop {
            // The saved state is being restored: answered at once (no deferred suspend).
            .resuming
        } else if session.state != .running && session.state != .paused {
            .notRunningYet
        } else {
            nil
        }
        if let refusal {
            Terminal.error(refusal.line)
            // A code, not text: `nido stop --suspend` shows it in its own language.
            answer(refusal.rawValue)
            return
        }
        Terminal.error(L10n.string("Suspending the VM…"))
        suspendTask = Task {
            do {
                try await session.suspend()
                return true
            } catch {
                let reason = CLISupport.message(for: error)
                Terminal.error(L10n.string("Error: \(reason). \(stateAfterFailure())"))
                answer(reason)
                suspendTask = nil
                if stopAfterSuspend { requestStop() }
                return false
            }
        }
    }

    /// What the VM does after a failed suspend, and how to stop it.
    private func stateAfterFailure() -> String {
        switch session.state {
        case .running: L10n.string("The VM keeps running.")
        case .paused: L10n.string("The VM is paused: stop it with Ctrl-C or nido stop \(name).")
        case .stopped: L10n.string("The VM is stopped.")
        default: L10n.string("The VM is in an unexpected state: stop it with Ctrl-C or nido stop \(name).")
        }
    }

    /// Tells `nido stop --suspend` why the VM is not suspended (best effort).
    private func answer(_ reason: String) {
        do {
            try VMControl.writeSuspendResult(bundle: bundle, reason: reason)
        } catch {
            Terminal.error(L10n.string("Couldn’t answer nido stop --suspend: \(CLISupport.message(for: error))."))
        }
    }

    private func requestStop() {
        // A stop in the middle of a suspend would race with the saved state: kept for after it.
        if suspendTask != nil {
            if !stopAfterSuspend {
                stopAfterSuspend = true
                Terminal.error(L10n.string("Stop requested: if the suspend fails, the VM stops after it."))
            }
            return
        }
        guard !requested else { return }
        // Nothing to stop yet (or any more): the request is not consumed, a later signal still
        // works. A resume from the suspended state in progress does accept it (R-M3A-22).
        guard session.acceptsStop else {
            if session.state == .stopped {
                Terminal.error(L10n.string("The VM hasn’t started yet: try stopping it again shortly."))
            }
            return
        }
        requested = true
        Terminal.error(L10n.string("Stopping the VM…"))
        Task { await session.stop(gracePeriod: .seconds(30)) }
    }
}
