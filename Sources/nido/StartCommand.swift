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
        discussion: L10n.string("A macOS VM starts without a window. One created with its account (macOS 27) logs in by itself at the first start and, with agent access on, Nido sets up Nido Agent in it; otherwise complete Setup Assistant in Nido first. Then use it with nido ssh.")
    )

    @Argument(help: ArgumentHelp(L10n.string("VM name.")))
    var name: String

    @Flag(help: ArgumentHelp(L10n.string("Also show the serial console in the terminal (with escape sequences removed); console.log records it either way. Linux VMs only.")))
    var console = false

    /// The process that started this run (`nido mcp --fresh`): when it ends, even killed, the VM
    /// stops as with Ctrl-C. Not for users.
    @Option(name: .customLong("parent-pid"), help: ArgumentHelp(visibility: .hidden))
    var parentPid: Int32?

    func validate() throws {
        if let parentPid, parentPid <= 1 {
            throw ValidationError(L10n.string("--parent-pid needs a process ID greater than 1"))
        }
    }

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
        let startConfig = try bundle.readConfig()
        // A VM made for another architecture: refused before the lock, with the bundle untouched.
        try ArchitectureGate.check(startConfig, host: .current)
        try CLISupport.checkConsoleFlag(console, guest: startConfig.guest)
        // Lock first: a second start fails here without touching the bundle.
        let lock = try BundleLock.acquire(bundle, owner: .cli)
        // The last thing the run does, after every other `defer`: the lock goes, and a fresh
        // Mac's run (--parent-pid) deletes its copy if it is still disposable, whatever ended it.
        defer {
            lock.release()
            if parentPid != nil {
                FreshMac.deleteAfterRun(
                    vmName, paths: NidoPaths(root: bundle.url.deletingLastPathComponent()),
                    report: { Terminal.error($0) })
            }
        }
        // A start by the user: a fresh Mac left by a session becomes an ordinary VM, never
        // deleted later.
        if parentPid == nil { try DisposableVMs.claim(bundle) }
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
        let (shown, pid) = (vmName.rawValue, String(getpid()))
        // Every session of the run (a new one after an agent's rollback) is made and wired by it.
        let wiring = StartWiring(bundle: bundle, name: shown, console: console, notices: notices)
        let session = try wiring.makeSession()
        let noticeTimer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        noticeTimer.schedule(deadline: .now() + 2, repeating: 2, leeway: .milliseconds(500))
        // Sendable: runs on a utility queue, not on the main actor of `run()`.
        noticeTimer.setEventHandler { @Sendable in
            for line in notices.flush(now: Date()) { Terminal.error(CLISupport.networkNoticeLine(line)) }
        }
        noticeTimer.resume()
        defer { noticeTimer.cancel() }
        // The run keeps the lock across an agent's rollback; one coordinator serves every session
        // (a macOS VM with agent access on only).
        let run = StartRun(
            session: session, wiring: wiring, bundle: bundle, lock: lock, vm: shown, pid: pid,
            checkpoints: StartRun<StartWiring>.offersCheckpoints(try? bundle.readConfig()))
        wiring.run = run
        // Its warnings, and Ctrl-C / `nido stop --suspend` for it.
        wiring.attach(session)
        defer { wiring.stopper?.cancel() }
        // --parent-pid: the end of that process stops the VM as Ctrl-C does.
        if let parentPid { wiring.watchParent(parentPid) }
        defer { wiring.endParentWatch() }
        // --console: the guest's output, sanitised (no escape sequences reach the terminal). Linux
        // VMs only, which have no rollback: the first session's console is the only one.
        let mirror: ConsoleMirror? = console ? session.serialConsole.map { ConsoleMirror(output: $0.output) } : nil
        defer { run.session.serialConsole?.close() }

        for line in StartSupport.startLines(try await session.startOrResume(), vm: shown, pid: pid) {
            Terminal.error(line)
        }

        // The owner serves the agent socket (macOS VM with agent access on); a failure, also of
        // reading config.json, is a warning.
        wiring.serve(session, checkpoints: run.checkpointHandling)
        defer { wiring.agentServer?.stop() }

        // A start that sent the guest its account: say so, and with agent access on set Nido Agent
        // up in a child task (waiting for Remote Login, up to 10 minutes) while the VM runs on.
        wiring.setupTask = Self.followProvisionedStart(session: session, bundle: bundle, vm: shown)
        defer { wiring.setupTask?.cancel() }

        // Until the session stops, also the one an agent's rollback started.
        let end = await run.waitForEnd()
        let final = run.session
        // The setup has nothing to do any more: cancelled and waited for (bounded), so it prints
        // nothing after the VM is gone.
        _ = await CLISupport.cancelAndWait(wiring.setupTask, within: CLISupport.setupTaskStopLimit)
        wiring.agentServer?.stop()
        // The machine is gone: the relay delivers its last events (stderr lines, egress.log)
        // before the process exits, waited for off the main actor.
        if let relay = final.egressRelay {
            await Task.detached { relay.shutdownAndWait() }.value
        }
        // The machine is gone: read what is left in the console pipe into console.log, end the
        // console and let the mirror print what it already read, for at most 2 s.
        await final.serialConsole?.closeAndWait()
        if let mirror, !(await mirror.finish(within: ConsoleMirror.finishTimeout)) {
            // stdout does not drain (a pipe nobody reads, a terminal stopped with Ctrl-S): do not
            // keep the lock, nor write more to the terminal (stderr may be blocked as well).
            lock.release()
            Foundation.exit(end == .ended(.stopped) ? 0 : 1)
        }
        switch end {
        case .ended(.error(let reason)):
            throw CLIError.vmFailed(reason)
        case .rollbackFailed(let checkpoint, let reason):
            // The VM is stopped (`waitForEnd`): the error is printed and the process exits 1.
            throw CLIError.rollbackFailed(checkpoint: checkpoint, reason: reason)
        case .ended:
            break
        }
        // Decided by the suspend's own result: the VM reports stopped before the suspend returns.
        let suspended = await wiring.stopper?.suspendOutcome() ?? false
        Terminal.error(suspended ? L10n.string("VM \(shown) suspended.") : L10n.string("VM \(shown) stopped."))
    }

    /// After a start that sent provisioning (`VMSession.sentProvisioning`): the follow-up line and,
    /// with agent access on, the setup task (nil otherwise). It never blocks the VM; an error is one
    /// line. The caller cancels and awaits it when the VM stops (`CLISupport.cancelAndWait`): once
    /// cancelled it prints nothing.
    @MainActor
    private static func followProvisionedStart(session: VMSession, bundle: VMBundle, vm: String) -> Task<Void, Never>? {
        let config = try? bundle.readConfig()
        switch CLISupport.provisionedStartFollowUp(
            sentProvisioning: session.sentProvisioning, agentAccess: config?.agentAccess)
        {
        case .none:
            return nil
        case .loggedIn:
            print(L10n.string("\(vm) was set up with its account: it logs in by itself."))
            return nil
        case .setUpAgent:
            guard let config else { return nil }
            print(L10n.string("Setting up Nido Agent in \(vm)…"))
            return Task {
                do {
                    let setup = try MacAgentSetup.live(
                        bundle: bundle, config: config, surface: .cli, describe: { CLISupport.message(for: $0) },
                        waitForRemoteLogin: .seconds(600))
                    _ = try await setup.run { event in
                        // Cancelled: the VM stopped, nothing more to say.
                        guard !Task.isCancelled else { return }
                        switch event {
                        case .error(let line): Terminal.error(line)
                        // A warning: the setup goes on.
                        case .passwordNotSaved: Terminal.error(event.line(vm: vm))
                        default: print(event.line(vm: vm))
                        }
                    }
                } catch is CancellationError {
                    return
                } catch where Task.isCancelled {
                    // Stopped with the VM (e.g. ssh killed): not a failure of the setup.
                    return
                } catch let error as MacAgentSetupError {
                    Terminal.error(AgentSupport.cliError(error).localizedDescription)
                } catch {
                    Terminal.error(CLISupport.message(for: error))
                }
            }
        }
    }
}

/// `nido start`'s wiring of each session of its run (`StartRun`): the first one, and the one an
/// agent's rollback starts.
@MainActor
private final class StartWiring: StartRunWiring {
    private let bundle: VMBundle
    private let name: String
    private let console: Bool
    private let notices: EgressNoticeMerger
    /// Set right after the run is made: a stop signal between two sessions goes to it.
    weak var run: StartRun<StartWiring>?
    /// The signal handling of the current session.
    private(set) var stopper: SignalStopper?
    /// The agent socket of the current session.
    private(set) var agentServer: AgentControlServer?
    /// The first session's Nido Agent setup, if any.
    var setupTask: Task<Void, Never>?
    /// The watch on `--parent-pid`'s process.
    private var parentWatch: ParentExitWatch?
    /// Asks for the stop again every second once the parent ended, until a stopper takes it.
    private var parentExitTimer: (any DispatchSourceTimer)?

    init(bundle: VMBundle, name: String, console: Bool, notices: EgressNoticeMerger) {
        self.bundle = bundle
        self.name = name
        self.console = console
        self.notices = notices
    }

    func makeSession() throws -> VMSession {
        let notices = notices
        return try VMSession(bundle: bundle, mirrorsConsole: console, egressEvents: { event in
            guard !event.isLocalNoise else { return }
            for line in notices.lines(for: event, now: Date()) { Terminal.error(CLISupport.networkNoticeLine(line)) }
        })
    }

    func attach(_ session: VMSession) {
        for warning in session.warnings { Terminal.error(L10n.string("Warning: \(ConsoleSanitizer.escapingControls(warning))")) }
        // The new handling is installed before the previous one goes: no signal falls in between.
        let previous = stopper
        let next = SignalStopper(
            session: session, bundle: bundle, name: name,
            takeStop: { [weak self] in self?.run?.takeStopBetweenSessions() ?? false },
            noteStop: { [weak self] in self?.run?.noteStop() },
            noteSuspend: { [weak self] in self?.run?.noteSuspend($0) },
            holdForCheckpoint: { [weak self] request, carryOut in
                self?.run?.holdForCheckpoint(request, then: carryOut) ?? false
            })
        next.install()
        stopper = next
        previous?.cancel()
    }

    func serve(_ session: VMSession, checkpoints: (any AgentCheckpointHandling)?) {
        agentServer?.stop()
        agentServer = AgentHost.readConfig(bundle, onWarning: { Terminal.error($0) }).flatMap { config in
            AgentHost.startIfEnabled(
                session: session, bundle: bundle, config: config, checkpoints: checkpoints,
                onWarning: { Terminal.error($0) })
        }
    }

    func detach(_ session: VMSession) async {
        _ = await CLISupport.cancelAndWait(setupTask, within: CLISupport.setupTaskStopLimit)
        setupTask = nil
        agentServer?.stop()
        agentServer = nil
        if let relay = session.egressRelay {
            await Task.detached { relay.shutdownAndWait() }.value
        }
        await session.serialConsole?.closeAndWait()
    }

    func report(_ line: String) {
        Terminal.error(line)
    }

    /// When the process `pid` ends, the VM stops as with Ctrl-C.
    func watchParent(_ pid: Int32) {
        let watch = ParentExitWatch(pid: pid, queue: .main) { [weak self] in
            MainActor.assumeIsolated { self?.parentExited(pid) }
        }
        parentWatch = watch
        watch.start()
    }

    /// The end of the run: no more watch or retries.
    func endParentWatch() {
        parentWatch?.cancel()
        parentWatch = nil
        parentExitTimer?.cancel()
        parentExitTimer = nil
    }

    /// Asked every second, of the stopper of the current session (a new one after a rollback): a
    /// VM that does not accept a stop yet gets the request again.
    private func parentExited(_ pid: Int32) {
        guard parentExitTimer == nil else { return }
        Terminal.error(L10n.string("The process \(String(pid)) that started this VM ended: stopping the VM."))
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: 1)
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.stopper?.stopForParentExit() == true else { return }
                self.parentExitTimer?.cancel()
                self.parentExitTimer = nil
            }
        }
        parentExitTimer = timer
        timer.resume()
    }
}

/// Turns the first SIGINT/SIGTERM/SIGHUP into a graceful `VMSession.stop`, and
/// `VMControl.suspendSignal` (`nido stop --suspend`) into `VMSession.suspend`: the VM stops with
/// its state saved and the process exits. When it cannot suspend, the process answers the waiting
/// `nido stop --suspend` (`VMControl.writeSuspendResult`) at once. A stop asked during a suspend
/// is kept and carried out if the suspend fails. During an agent's rollback a stop goes to the
/// run when no session runs (`takeStop`), and every stop is noted so no rollback starts after it
/// (`noteStop`); a suspend in progress is noted as well (`noteSuspend`), so no checkpoint or
/// rollback races with its save. A stop or a suspend asked while an agent takes a checkpoint
/// waits for it (`holdForCheckpoint`), then is carried out as usual.
@MainActor
private final class SignalStopper {
    private let session: VMSession
    private let bundle: VMBundle
    private let name: String
    private let takeStop: () -> Bool
    private let noteStop: () -> Void
    private let noteSuspend: (Bool) -> Void
    private let holdForCheckpoint: (TerminalRequest, @escaping @MainActor () -> Void) -> Bool
    private var sources: [any DispatchSourceSignal] = []
    private var requested = false
    /// A stop signal that arrived while suspending.
    private var stopAfterSuspend = false
    private var suspendTask: Task<Bool, Never>?
    /// A suspend waiting for an agent's checkpoint to end.
    private var suspendHeld = false

    init(
        session: VMSession, bundle: VMBundle, name: String, takeStop: @escaping () -> Bool,
        noteStop: @escaping () -> Void, noteSuspend: @escaping (Bool) -> Void,
        holdForCheckpoint: @escaping (TerminalRequest, @escaping @MainActor () -> Void) -> Bool
    ) {
        self.session = session
        self.bundle = bundle
        self.name = name
        self.takeStop = takeStop
        self.noteStop = noteStop
        self.noteSuspend = noteSuspend
        self.holdForCheckpoint = holdForCheckpoint
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

    /// The process that started this run ended (`--parent-pid`): a stop on the path of SIGINT.
    /// True once the stop is taken, held for an agent's checkpoint or queued behind a suspend;
    /// false when the VM does not accept a stop yet (the caller asks again).
    func stopForParentExit() -> Bool {
        requestStop()
        return requested || stopAfterSuspend
    }

    /// True when the VM was suspended (waits for a suspend in progress to finish).
    func suspendOutcome() async -> Bool {
        guard let suspendTask else { return false }
        return await suspendTask.value
    }

    private func requestSuspend() {
        guard suspendTask == nil, !suspendHeld else { return }
        // An agent's checkpoint in progress (the VM paused, its state being saved): the suspend
        // waits for it, the waiting `nido stop --suspend` with it. Checked before the state: the
        // checkpoint passes through pausing and resuming.
        if !requested, holdForCheckpoint(.suspend, { [weak self] in self?.carryOutHeldSuspend() }) {
            suspendHeld = true
            return
        }
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
        // Marked before the task runs: a rollback accepted meanwhile does not stop the VM.
        noteSuspend(true)
        suspendTask = Task {
            do {
                try await session.suspend()
                return true
            } catch {
                let reason = CLISupport.message(for: error)
                Terminal.error(L10n.string("Error: \(reason). \(stateAfterFailure())"))
                answer(reason)
                suspendTask = nil
                // The VM is still there (running, paused or stopped): checkpoints and rollbacks
                // are possible again where it runs.
                noteSuspend(false)
                if stopAfterSuspend { requestStop() }
                return false
            }
        }
    }

    /// The suspend held for an agent's checkpoint, now that it ended. Refused then (the VM is no
    /// longer running), a stop asked while it waited is carried out.
    private func carryOutHeldSuspend() {
        suspendHeld = false
        requestSuspend()
        if suspendTask == nil, stopAfterSuspend {
            stopAfterSuspend = false
            requestStop()
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
        // A stop in the middle of a suspend would race with the saved state: kept for after it
        // (also a suspend still waiting for an agent's checkpoint).
        if suspendTask != nil || suspendHeld {
            if !stopAfterSuspend {
                stopAfterSuspend = true
                Terminal.error(L10n.string("Stop requested: if the suspend fails, the VM stops after it."))
            }
            return
        }
        guard !requested else { return }
        // A rollback between two sessions: the run takes it, nothing more is restored or started.
        if takeStop() {
            requested = true
            Terminal.error(L10n.string("Stopping the VM…"))
            return
        }
        // An agent's checkpoint in progress has paused the VM: stopped now, it would be powered
        // off at once (no graceful shutdown) and the checkpoint would fail. Carried out after it;
        // meanwhile a suspend is refused as for a stop in progress.
        if holdForCheckpoint(.stop, { [weak self] in self?.carryOutHeldStop() }) {
            requested = true
            return
        }
        // Nothing to stop yet (or any more): the request is not consumed, a later signal still
        // works. A resume from the suspended state in progress does accept it (R-M3A-22).
        guard session.acceptsStop else {
            if session.state == .stopped {
                Terminal.error(L10n.string("The VM hasn’t started yet: try stopping it again shortly."))
            }
            return
        }
        requested = true
        noteStop()
        Terminal.error(L10n.string("Stopping the VM…"))
        Task { await session.stop(gracePeriod: .seconds(30)) }
    }

    /// The stop held for an agent's checkpoint, now that it ended: carried out as a new one,
    /// unless the VM is already gone (the run ends with it).
    private func carryOutHeldStop() {
        guard !StartSupport.isFinal(session.state) else { return }
        requested = false
        requestStop()
    }
}
