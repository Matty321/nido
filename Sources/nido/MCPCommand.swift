// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import Foundation
import NidoCLI
import NidoCore

/// `nido mcp <vm>`: a Model Context Protocol server on stdio for one macOS VM, started by the MCP
/// client (Claude Code, …) as a subprocess. Each tool call goes to the control socket of the
/// process that runs the VM; this command never starts a VM. Stdout carries only protocol lines.
///
/// `nido mcp --fresh <base>`: the same server on a disposable copy of the stopped VM `<base>`,
/// run by a child `nido start <copy> --parent-pid <pid>` and stopped and deleted when the session
/// ends (`FreshMac`, `FreshMacSession`); `initialize` is answered at once and each tool call waits
/// for the copy's boot (`FreshMacActions`).
///
/// An `AsyncParsableCommand` for the copy (`VMCloner` is async); the server's loop blocks on stdin
/// and on the socket, so it runs on a thread of its own, never on a cooperative thread.
struct MCPCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mcp",
        abstract: L10n.string("Serve a macOS VM to an AI agent as an MCP server on stdin/stdout."),
        discussion: L10n.string("An MCP client starts this command itself; use --config to print the entry to add to its configuration. Without --fresh the VM must be running with agent access on (nido agent enable); with --fresh the command makes a new copy of the stopped VM for the session and deletes it at the end.")
    )

    @Argument(help: ArgumentHelp(L10n.string("VM name.")))
    var vm: String

    @Flag(help: ArgumentHelp(L10n.string("Print the MCP client configuration for this VM and exit.")))
    var config = false

    @Flag(help: ArgumentHelp(L10n.string("Serve a new copy of this stopped macOS VM, deleted when the session ends.")))
    var fresh = false

    @Flag(help: ArgumentHelp(L10n.string("With --fresh: keep the copy, stopped, when the session ends.")))
    var keep = false

    func validate() throws {
        if keep && !fresh { throw ValidationError(L10n.string("--keep works only with --fresh")) }
    }

    func run() async throws {
        if fresh {
            try await runFresh()
            return
        }
        let (vmName, bundle) = try AgentSupport.openBundle(vm)
        let vmConfig = try bundle.readConfig()
        try AgentSupport.requireAgentAccess(vmConfig)

        if config {
            print(AgentSupport.mcpConfigSnippet(vm: vmName.rawValue, executable: Self.executablePath(), fresh: false, keep: false))
            return
        }
        let client = AgentSupport.client(bundle: bundle, config: vmConfig, for: .mcp)
        let name = vmName.rawValue
        let network = AgentNetworkReport(bundle: bundle, hintVM: name)
        await Self.onOwnThread {
            MCPServer(vmName: name, actions: client, network: network).run(input: .standardInput, output: .standardOutput)
        }
    }

    /// `--fresh`: checks the base and the limit before anything is cloned or started, clones,
    /// launches the child, then serves the copy until EOF or a signal, and ends the session.
    private func runFresh() async throws {
        // A client gone mid-answer must not kill the process before the copy is torn down.
        signal(SIGPIPE, SIG_IGN)
        let (base, _, paths) = try AgentSupport.openFreshBase(vm: vm, requireStopped: !config)

        if config {
            print(AgentSupport.mcpConfigSnippet(vm: base.rawValue, executable: Self.executablePath(), fresh: true, keep: keep))
            return
        }
        try FreshMac.checkLimit(paths: paths)
        for name in DisposableVMs.sweep(paths: paths) {
            Terminal.error(L10n.string("Deleted \(name.rawValue), a fresh Mac left by an earlier session."))
        }
        let cloner = VMCloner(paths: paths, runner: SystemProcessRunner(), passwords: KeychainGuestPasswordStore())
        let bundle = try await FreshMac.prepare(base: base, paths: paths, keep: keep) {
            try await cloner.clone(base, as: $0, owner: .cliOperation)
        }
        let clone = try VMName(bundle.displayName)

        let child: ProcessChild
        let cloneConfig: VMConfig
        do {
            let log = try bundle.openFreshStartLog()
            cloneConfig = try bundle.readConfig()
            child = try ProcessChild.launch(
                executable: Self.runningExecutable(),
                arguments: ["start", clone.rawValue, "--parent-pid", String(getpid())], output: log)
        } catch {
            _ = try? DisposableVMs.delete(clone, paths: paths)
            throw error
        }
        // Readiness counts from the launch: the copy's boot is waited for only inside tool calls.
        let deadline = ContinuousClock.now + FreshMac.readinessLimit
        Terminal.error(L10n.string(
            "Fresh Mac \(clone.rawValue), a copy of \(base.rawValue): starting without a window (log: \(bundle.freshStartLogURL.path))."))

        let session = FreshMacSession(
            clone: clone, base: base, bundle: bundle, paths: paths, keep: keep, child: child,
            report: { Terminal.error($0) })
        // A signal ends the session, then the process. The teardown takes up to 70 seconds and
        // holds the session's lock: it runs on a Dispatch queue, never on a cooperative thread.
        var sources: [any DispatchSourceSignal] = []
        for signalNumber in [SIGINT, SIGTERM, SIGHUP] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .global(qos: .utility))
            source.setEventHandler {
                session.end()
                Foundation.exit(0)
            }
            source.resume()
            sources.append(source)
        }

        let hint = L10n.string(
            "the fresh Mac \(clone.rawValue) isn’t ready after 180 seconds: \(base.rawValue) must log in by itself and have Nido Agent set up (nido agent setup \(base.rawValue))")
        let actions = FreshMacActions(
            inner: AgentSupport.client(bundle: bundle, config: cloneConfig, for: .mcp), deadline: deadline,
            childEnded: { session.childEndedReason() }, notReadyHint: hint)
        let note = FreshMac.statusNote(clone: clone.rawValue, base: base.rawValue, keep: keep)
        let name = clone.rawValue
        let network = AgentNetworkReport(bundle: bundle, hintVM: base.rawValue)
        await Self.onOwnThread {
            MCPServer(vmName: name, actions: actions, note: note, network: network).run(input: .standardInput, output: .standardOutput)
            session.end()
        }
        withExtendedLifetime(sources) {}
    }

    /// Runs `body` on a thread of its own (the main thread's 8 MiB of stack) and waits for it
    /// without holding a thread of the cooperative pool.
    private static func onOwnThread(_ body: @escaping @Sendable () -> Void) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let thread = Thread {
                body()
                continuation.resume()
            }
            thread.stackSize = 8 << 20
            thread.start()
        }
    }

    /// The `nido` that runs now, for the child `nido start`.
    private static func runningExecutable() -> URL {
        Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
    }

    /// The path the user ran this command by, made absolute but not resolved through symlinks (so
    /// `~/.local/bin/nido` stays as it is): a word with a `/` is taken against the current
    /// directory, a bare name is looked up in `PATH`.
    static func executablePath() -> String {
        let argument = CommandLine.arguments.first ?? "nido"
        if argument.hasPrefix("/") { return URL(fileURLWithPath: argument).standardizedFileURL.path }
        if argument.contains("/") {
            return URL(fileURLWithPath: argument, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
                .standardizedFileURL.path
        }
        let search = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
        for directory in search {
            let candidate = "\(directory)/\(argument)"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate).standardizedFileURL.path
            }
        }
        return Bundle.main.executablePath ?? argument
    }
}
