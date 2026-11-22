// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation
import NidoAgentKit
import NidoCore

/// The testable half of `nido act` and `nido agent`: the arguments of an action turned into an
/// `AgentAction`, the one-line JSON the commands print, and the switch that turns agent access on
/// or off in a VM's `config.json`.
public enum AgentSupport {
    /// The password stored for the VM's account, after the Mac's owner confirmed (Touch ID or the
    /// Mac password). `.noStoredPassword` when there is none (checked first: nothing to unlock);
    /// `.passwordAuthenticationFailed` when the owner did not confirm. A Keychain error is thrown as is.
    public static func storedPassword(
        config: VMConfig, store: any GuestPasswordStore, owner: any OwnerAuthenticator
    ) async throws -> String {
        let name = config.name.rawValue
        guard let password = try store.read(vm: config.id) else { throw CLIError.noStoredPassword(name) }
        let reason = L10n.string("show the password of \(config.sshUser ?? "nido") in \(name)")
        guard await owner.authenticate(reason: reason) else { throw CLIError.passwordAuthenticationFailed }
        return password.value
    }

    /// What `replaceUnusablePassword` did.
    public enum PasswordRepair: Equatable, Sendable {
        /// The stored item is usable, missing, or unreadable for another reason: nothing to say.
        case unchanged
        /// The unusable item was replaced: the line for standard output.
        case replaced(String)
        /// The item stays unusable (no terminal, nothing typed, the Keychain refused the new
        /// one): the line for standard error.
        case warning(String)
    }

    /// After `nido agent setup` ended ready. A key that already works means the setup never read
    /// the stored password, so an unusable item would stay unnoticed: it is replaced with the
    /// password `ask` gets (once, at the terminal; nil without one). The password is never
    /// printed. A setup that worked stays a success whatever this says.
    public static func replaceUnusablePassword(
        vm: String, id: UUID, store: any GuestPasswordStore,
        ask: (@Sendable () async -> GuestPassword?)?
    ) async -> PasswordRepair {
        do {
            _ = try store.read(vm: id)
            return .unchanged
        } catch GuestPasswordStoreError.unusableItem {
            let unusable = GuestPasswordStoreError.unusableItem.errorDescription ?? ""
            guard let ask, let password = await ask() else { return .warning(unusable) }
            do {
                try store.save(password, vm: id)
            } catch {
                return .warning(L10n.string("The password stored for \(vm) couldn’t be replaced: \(CLISupport.message(for: error))"))
            }
            return .replaced(L10n.string("The password stored for \(vm) was replaced."))
        } catch {
            return .unchanged
        }
    }

    /// What `nido act <vm> …` does: send an action to the VM's owner (and maybe copy the
    /// screenshot it saved), sleep on this side, or copy a file between the Mac and the guest's
    /// `~/NidoTransfer`.
    public enum Invocation: Equatable, Sendable {
        case send(AgentAction, output: String?)
        case wait(milliseconds: Int)
        /// `put-file LOCAL GUEST-PATH`.
        case putFile(local: String, guestPath: String)
        /// `get-file GUEST-PATH LOCAL [--force]`.
        case getFile(guestPath: String, local: String, force: Bool)
    }

    /// The longest a `wait` may take, in milliseconds (the same as the MCP tool's).
    public static let maxWaitMilliseconds = AgentProtocol.maxWaitMilliseconds

    /// The range `--max` accepts (the long edge of the screenshot, in pixels; the same as the
    /// MCP tool's).
    public static let maxLongEdgeRange = AgentProtocol.maxLongEdgeRange

    /// The action in `args` (`["click", "10", "20", "--right"]`), as `nido act <vm>` takes it.
    /// `wait`, `put-file` and `get-file` are not one action of the helper and have no value
    /// here: they throw a usage error.
    public static func parseAction(_ args: [String]) throws -> AgentAction {
        switch try parseInvocation(args) {
        case .send(let action, _): return action
        case .wait: throw CLIError.agentUsage("wait MS")
        case .putFile: throw CLIError.agentUsage(putFileUsage)
        case .getFile: throw CLIError.agentUsage(getFileUsage)
        }
    }

    private static let putFileUsage = "put-file LOCAL GUEST-PATH"
    private static let getFileUsage = "get-file GUEST-PATH LOCAL [--force]"

    /// `args` as an `Invocation`: the action name, then its arguments; unknown options, missing or
    /// extra arguments and out-of-range values throw (`CLIError`, `KeyMapError` for a bad combo).
    public static func parseInvocation(_ args: [String]) throws -> Invocation {
        guard let name = args.first else {
            throw CLIError.agentUsage(
                "status | screenshot | zoom | ui-tree | click | drag | scroll | type | key | wait | checkpoint | rollback | checkpoints | put-file | get-file | files")
        }
        let rest = Array(args.dropFirst())
        switch name {
        case "status":
            _ = try Parsed(rest, usage: "status", flags: [], options: [], positionals: 0)
            return .send(.status, output: nil)
        case "screenshot":
            let p = try Parsed(rest, usage: "screenshot [--max N] [--output PATH]", flags: [],
                               options: ["--max", "--output"], positionals: 0)
            var maxLongEdge = AgentProtocol.defaultMaxLongEdge
            if let value = p.options["--max"] {
                maxLongEdge = try integer(value, name: "--max", in: maxLongEdgeRange)
            }
            return .send(.screenshot(maxLongEdge: maxLongEdge), output: p.options["--output"])
        case "zoom":
            let usage = "zoom X Y W H [--max N] [--output PATH]"
            let p = try Parsed(rest, usage: usage, flags: [], options: ["--max", "--output"], positionals: 4)
            var maxLongEdge = AgentProtocol.defaultMaxLongEdge
            if let value = p.options["--max"] {
                maxLongEdge = try integer(value, name: "--max", in: maxLongEdgeRange)
            }
            let x = try number(p.positionals[0], name: "X"), y = try number(p.positionals[1], name: "Y")
            let width = try number(p.positionals[2], name: "W"), height = try number(p.positionals[3], name: "H")
            guard x >= 0, y >= 0, width >= 1, height >= 1 else { throw CLIError.agentUsage(usage) }
            return .send(.zoom(x: x, y: y, width: width, height: height, maxLongEdge: maxLongEdge),
                         output: p.options["--output"])
        case "ui-tree":
            let p = try Parsed(rest, usage: "ui-tree [--max N]", flags: [], options: ["--max"], positionals: 0)
            var maxElements = AgentProtocol.defaultUITreeElements
            if let value = p.options["--max"] {
                maxElements = try integer(value, name: "--max", in: AgentProtocol.uiTreeElementsRange)
            }
            return .send(.uiTree(maxElements: maxElements), output: nil)
        case "click":
            let usage = "click X Y [--right] [--count N]"
            let p = try Parsed(rest, usage: usage, flags: ["--right"], options: ["--count"], positionals: 2)
            let count = try p.options["--count"].map { try integer($0, name: "--count", in: 1...3) } ?? 1
            return .send(.click(
                x: try number(p.positionals[0], name: "X"), y: try number(p.positionals[1], name: "Y"),
                button: p.flags.contains("--right") ? .right : .left, count: count), output: nil)
        case "drag":
            let p = try Parsed(rest, usage: "drag X1 Y1 X2 Y2", flags: [], options: [], positionals: 4)
            return .send(.drag(
                fromX: try number(p.positionals[0], name: "X1"), fromY: try number(p.positionals[1], name: "Y1"),
                toX: try number(p.positionals[2], name: "X2"), toY: try number(p.positionals[3], name: "Y2")),
                output: nil)
        case "scroll":
            let usage = "scroll --dx DX --dy DY [--x X --y Y]"
            let p = try Parsed(rest, usage: usage, flags: [], options: ["--dx", "--dy", "--x", "--y"], positionals: 0)
            guard p.options["--dx"] != nil || p.options["--dy"] != nil else { throw CLIError.agentUsage(usage) }
            // A point needs both coordinates.
            guard (p.options["--x"] == nil) == (p.options["--y"] == nil) else { throw CLIError.agentUsage(usage) }
            return .send(.scroll(
                dx: try p.options["--dx"].map { try number($0, name: "--dx") } ?? 0,
                dy: try p.options["--dy"].map { try number($0, name: "--dy") } ?? 0,
                x: try p.options["--x"].map { try number($0, name: "--x") },
                y: try p.options["--y"].map { try number($0, name: "--y") }), output: nil)
        case "type":
            // The text is taken as it is, even when it starts with "--".
            guard rest.count == 1 else { throw CLIError.agentUsage("type TEXT") }
            return .send(.type(text: rest[0]), output: nil)
        case "key":
            guard rest.count == 1 else { throw CLIError.agentUsage("key COMBO") }
            try KeyMap.validateCombo(rest[0])
            return .send(.key(combo: rest[0]), output: nil)
        case "checkpoint":
            let p = try Parsed(rest, usage: "checkpoint [--name N]", flags: [], options: ["--name"], positionals: 0)
            return .send(.checkpoint(name: p.options["--name"]), output: nil)
        case "rollback":
            // NAME is optional: at most one positional.
            let p = try Parsed(rest, usage: "rollback [NAME]", flags: [], options: [], positionals: min(rest.count, 1))
            return .send(.rollback(name: p.positionals.first), output: nil)
        case "checkpoints":
            _ = try Parsed(rest, usage: "checkpoints", flags: [], options: [], positionals: 0)
            return .send(.checkpoints, output: nil)
        case "put-file":
            let p = try Parsed(rest, usage: putFileUsage, flags: [], options: [], positionals: 2)
            return .putFile(local: p.positionals[0], guestPath: p.positionals[1])
        case "get-file":
            let p = try Parsed(rest, usage: getFileUsage, flags: ["--force"], options: [], positionals: 2)
            return .getFile(guestPath: p.positionals[0], local: p.positionals[1], force: p.flags.contains("--force"))
        case "files":
            // GUEST-PATH is optional: at most one positional.
            let p = try Parsed(rest, usage: "files [GUEST-PATH]", flags: [], options: [], positionals: min(rest.count, 1))
            return .send(.listFiles(path: p.positionals.first), output: nil)
        case "wait":
            guard rest.count == 1 else { throw CLIError.agentUsage("wait MS") }
            let ms = try integer(rest[0], name: "MS", in: 0...maxWaitMilliseconds)
            _ = try waitMilliseconds(ms)
            return .wait(milliseconds: ms)
        default:
            throw CLIError.unknownAgentAction(name)
        }
    }

    /// `ms` as a duration; 0…10000 only.
    public static func waitMilliseconds(_ ms: Int) throws -> Duration {
        guard (0...maxWaitMilliseconds).contains(ms) else {
            throw CLIError.agentOutOfRange("MS", 0, maxWaitMilliseconds)
        }
        return .milliseconds(ms)
    }

    /// `answer` as one line of JSON with sorted keys and unescaped slashes (a path stays readable),
    /// a checkpoint's time in ISO 8601 (UTC). What the guest wrote in it is cleaned first
    /// (`AgentAnswer.cleaned`).
    public static func json(_ answer: AgentAnswer) -> String { encode(answer.cleaned) }

    /// The JSON `nido agent status` prints: `agentAccess`, `running` and, only when the helper was
    /// asked, its `status` answer (cleaned) as `helper`. Sorted keys, one line.
    public static func statusJSON(agentAccess: Bool, running: Bool, helper: AgentAnswer?) -> String {
        encode(StatusReport(agentAccess: agentAccess, running: running, helper: helper?.cleaned))
    }

    /// The helper's `status` answer for `nido agent status`: what `send` returns, or, when it throws
    /// (transport error, no socket), a failed answer carrying the error's code and message, so the
    /// report is always printed.
    public static func helperAnswer(_ send: () throws -> AgentAnswer) -> AgentAnswer {
        do {
            return try send()
        } catch let failure as AgentFailure {
            return .failure(failure.code, failure.message)
        } catch {
            return .failure(.internalError, CLISupport.message(for: error))
        }
    }

    /// The answer `nido act` prints for a screenshot with `--output`: when the answer is ok, the PNG
    /// is copied first, and a copy that fails turns the answer into a failure (`ok` false, with the
    /// copy's error), so the JSON never says ok while the command fails. Other answers pass through.
    public static func completeScreenshot(_ answer: AgentAnswer, output: String?) -> AgentAnswer {
        guard answer.ok, let output else { return answer }
        do {
            guard let path = answer.path else { throw CLIError.noScreenshotFile }
            try copyScreenshot(from: path, to: output)
            return answer
        } catch {
            var failed = answer
            failed.ok = false
            failed.error = .internalError
            failed.message = CLISupport.message(for: error)
            return failed
        }
    }

    /// How the guest's SSH answered `nido agent setup`'s probe.
    public typealias SSHReach = MacAgentSetup.SSHReach

    /// `nido agent setup`'s probe (see `MacAgentSetup.sshReach`).
    public static func sshReach(
        resolve: () throws -> SSHEndpoint, probe: (SSHEndpoint) -> PortProbe.Result
    ) throws -> SSHReach {
        try MacAgentSetup.sshReach(resolve: resolve, probe: probe)
    }

    /// What `nido agent setup` does before it uses SSH.
    public typealias SetupGate = MacAgentSetup.Gate

    /// The decision of `nido agent setup` before SSH (see `MacAgentSetup.gate`).
    public static func setupGate(helper: AgentAnswer, ssh: SSHReach) -> SetupGate {
        MacAgentSetup.gate(helper: helper, ssh: ssh)
    }

    /// What to tell the user when the first SSH command of `nido agent setup` fails with the key
    /// refused before the FileVault login (see `MacAgentSetup.loginHint`).
    public static func loginHint(for error: any Error, helper: AgentAnswer, vm: String) -> CLIError? {
        MacAgentSetup.loginHint(for: error, helper: helper, vm: vm).map(cliError)
    }

    /// The `CLIError` that prints what `error` says (the same messages).
    public static func cliError(_ error: MacAgentSetupError) -> CLIError {
        switch error {
        case .notForLinux: .agentNotForLinux
        case .notServed(let message): .agentNotServed(message)
        case .loginWindow(let vm): .agentLoginWindow(vm)
        case .remoteLoginOff: .remoteLoginOff
        case .guestLoginNeeded(let vm): .guestLoginNeeded(vm)
        case .accessOff(let vm): .agentAccessOff(vm)
        case .passwordNeeded(let vm): .agentPasswordNeeded(vm)
        case .askpassMissing: .agentAskpassMissing
        }
    }

    /// Who talks to the owner, as the activity log records it.
    public enum Caller: Sendable {
        /// `nido act`: each call joins the last `act` session when it is recent.
        case act
        /// `nido mcp`: one session for the whole run.
        case mcp
        /// `nido agent status`: Nido's own check, not recorded.
        case nido
    }

    /// The client of `bundle`'s control socket for `nido act`, `nido mcp` and `nido agent`,
    /// naming `caller` to the owner (an MCP client gets a new session of its own). A VM that runs
    /// (bundle lock held) with agent access on in its configuration but has no socket file is
    /// told to restart, not to start.
    public static func client(bundle: VMBundle, config: VMConfig, for caller: Caller) -> AgentControlClient {
        switch caller {
        case .act:
            AgentControlClient.forVM(bundle: bundle, config: config, client: AgentCommand.Client.act)
        case .mcp:
            AgentControlClient.forVM(
                bundle: bundle, config: config, client: AgentCommand.Client.mcp, session: UUID().uuidString.lowercased())
        case .nido:
            AgentControlClient.forVM(bundle: bundle, config: config, client: AgentCommand.Client.nido)
        }
    }

    /// The `mcpServers` entry of `nido mcp` for `vm`, as one line of JSON: `nido-<vm>` running
    /// `mcp <vm>`, or with `fresh` `nido-fresh-<vm>` running `mcp --fresh [--keep] <vm>`.
    public static func mcpConfigSnippet(vm: String, executable: String, fresh: Bool, keep: Bool) -> String {
        let key = fresh ? "nido-fresh-\(vm)" : "nido-\(vm)"
        let args = ["mcp"] + (fresh ? ["--fresh"] : []) + (fresh && keep ? ["--keep"] : []) + [vm]
        let object: [String: Any] = ["mcpServers": [key: ["command": executable, "args": args]]]
        let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data ?? Data("{}".utf8), as: UTF8.self)
    }

    /// Throws `CLIError.agentAccessOff` unless the VM's agent access is on.
    public static func requireAgentAccess(_ config: VMConfig) throws {
        guard config.agentAccess == true else { throw CLIError.agentAccessOff(config.name.rawValue) }
    }

    /// Opens the named VM for an agent or MCP command. On a Mac without Apple silicon it refuses
    /// first (`needsAppleSilicon`): no path is prepared and no bundle is read. `paths` is the data
    /// root of the process unless a test gives one.
    public static func openBundle(
        _ name: String, paths: NidoPaths? = nil, host: HostPlatform = .current
    ) throws -> (VMName, VMBundle) {
        try HostChecks.requireMacGuests(host)
        let vmName = try VMName(name)
        let paths = try paths ?? CLISupport.preparedPaths()
        return (vmName, try VMBundle.open(vmName, paths: paths))
    }

    /// `nido agent enable|disable`: refused on this host first, then `setAgentAccess`.
    public static func switchAgentAccess(
        _ on: Bool, vm: String, paths: NidoPaths? = nil, host: HostPlatform = .current
    ) throws -> String {
        let (_, bundle) = try openBundle(vm, paths: paths, host: host)
        return try setAgentAccess(on, bundle: bundle)
    }

    /// `nido act`: refused on this host first, then the action is parsed and the VM opened with
    /// agent access checked.
    public static func openForAct(
        vm: String, action: [String], paths: NidoPaths? = nil, host: HostPlatform = .current
    ) throws -> (invocation: Invocation, name: VMName, bundle: VMBundle, config: VMConfig) {
        try HostChecks.requireMacGuests(host)
        let invocation = try parseInvocation(action)
        let (name, bundle) = try openBundle(vm, paths: paths, host: host)
        let config = try bundle.readConfig()
        try requireAgentAccess(config)
        return (invocation, name, bundle, config)
    }

    /// `nido mcp --fresh`: refused on this host first, then the base VM is opened and checked.
    public static func openFreshBase(
        vm: String, requireStopped: Bool, paths: NidoPaths? = nil, host: HostPlatform = .current
    ) throws -> (VMName, VMBundle, NidoPaths) {
        try HostChecks.requireMacGuests(host)
        let resolved = try paths ?? CLISupport.preparedPaths()
        let (base, bundle) = try openBundle(vm, paths: resolved, host: host)
        try FreshMac.checkBase(try bundle.readConfig(), bundle: bundle, requireStopped: requireStopped)
        return (base, bundle, resolved)
    }

    /// Turns agent access on (macOS VMs only) or off in `config.json` and returns the message to
    /// print. The running VM's owner reads the setting before every command, so turning it off is
    /// immediate; turning it on needs a start, because the socket device exists only in a VM
    /// started with it. Agent access is part of the configuration a saved state was made with: on
    /// a suspended VM whose next start would no longer resume, a second line says the saved state
    /// will be discarded, as `nido share` does.
    public static func setAgentAccess(_ on: Bool, bundle: VMBundle) throws -> String {
        let config = try bundle.updateConfig { config in
            if on && config.guest != .macos { throw CLIError.agentNotForLinux }
            config.agentAccess = on
        }
        let name = config.name.rawValue
        let message: String
        if !on {
            message = L10n.string("Agent access is off for \(name).")
        } else if BundleLock.holder(bundle) != nil {
            message = L10n.string("Agent access is on for \(name). It takes effect at the next start.")
        } else {
            message = L10n.string("Agent access is on for \(name).")
        }
        return ([message] + CLISupport.suspendedWarning(bundle, config)).joined(separator: "\n")
    }

    /// Copies the PNG at `source` to `destination`, which must not exist (checked by the create
    /// itself, so no race). The copy is a file the user asked for: 0666 minus the umask, not the
    /// 0600 of the original.
    public static func copyScreenshot(from source: String, to destination: String) throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: source))
        let fd = Darwin.open(destination, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard fd >= 0 else {
            if errno == EEXIST { throw CLIError.outputExists(destination) }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { _ = Darwin.close(fd) }
        var offset = 0
        try data.withUnsafeBytes { raw in
            while offset < raw.count {
                let n = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else {
                    _ = Darwin.unlink(destination)
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                offset += n
            }
        }
    }

    // MARK: Files (`put-file`, `get-file`)

    /// The largest file `put-file` and `get-file` copy, in bytes (16 MiB, Nido Agent's own bound).
    public static let maxFileBytes = AgentProtocol.maxTransferBytes

    /// The bytes of the local file `path` for `put-file`: a regular file only, opened with
    /// `O_NOFOLLOW` (a link is refused, never followed) and without waiting on a FIFO; more than
    /// `AgentProtocol.maxTransferBytes` is refused (`agentFileTooLarge`), also when the file grows
    /// while it is read.
    public static func readLocalFile(_ path: String) throws -> Data {
        let fd = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ELOOP { throw CLIError.notARegularFile(path) }
            throw CLIError.localFileUnreadable(path, String(cString: strerror(errno)))
        }
        defer { _ = Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard info.st_mode & S_IFMT == S_IFREG else { throw CLIError.notARegularFile(path) }
        let limit = maxFileBytes
        guard info.st_size <= limit else { throw CLIError.agentFileTooLarge }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1 << 16)
        while true {
            let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!, $0.count) }
            if n < 0 && errno == EINTR { continue }
            guard n >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            if n == 0 { return data }
            data.append(contentsOf: buffer[..<n])
            guard data.count <= limit else { throw CLIError.agentFileTooLarge }
        }
    }

    /// Before `get-file` asks for anything: without `force`, a local path that exists (a file, a
    /// folder, a link, even one to nothing) is refused (`localFileExists`), so nothing is copied
    /// for a file that would not be written.
    public static func checkLocalTarget(_ path: String, force: Bool) throws {
        guard !force else { return }
        var info = stat()
        if lstat(path, &info) == 0 { throw CLIError.localFileExists(path) }
    }

    /// Writes `data` to the local `path` with mode 0600. Without `force` the file is created
    /// with `O_CREAT | O_EXCL | O_NOFOLLOW`: whatever is at `path` (a file, a link) stays as it is
    /// and is refused (`localFileExists`). With `force` it is written to a temporary file in the
    /// same folder, then renamed over `path`: a link at `path` is replaced as an entry, its
    /// target never written, and a reader never sees half a file.
    public static func writeLocalFile(_ data: Data, to path: String, force: Bool) throws {
        guard force else {
            try createLocalFile(data, at: path) { CLIError.localFileExists(path) }
            return
        }
        // A short name, not derived from the target's: a target named with the longest name the
        // folder allows still gets a temporary file beside it.
        let folder = URL(fileURLWithPath: path).deletingLastPathComponent()
        var temporary = ""
        var created = false
        for _ in 0..<4 where !created {
            temporary = folder.appendingPathComponent(".nido-\(String(UUID().uuidString.lowercased().prefix(8))).tmp").path
            do {
                try createLocalFile(data, at: temporary) { POSIXError(.EEXIST) }
                created = true
            } catch let error as POSIXError where error.code == .EEXIST {
                continue
            }
        }
        guard created else { throw POSIXError(.EEXIST) }
        guard Darwin.rename(temporary, path) == 0 else {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            _ = Darwin.unlink(temporary)
            throw error
        }
    }

    /// A new file at `path` holding `data`, 0600 whatever the umask; `exists` is thrown when
    /// something is already there. A failed write leaves nothing behind.
    private static func createLocalFile(_ data: Data, at path: String, exists: () -> any Error) throws {
        let fd = Darwin.open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            if errno == EEXIST { throw exists() }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var failure: POSIXError?
        if fchmod(fd, 0o600) != 0 { failure = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        data.withUnsafeBytes { raw in
            var offset = 0
            while failure == nil, offset < raw.count {
                let n = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else {
                    failure = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    break
                }
                offset += n
            }
        }
        if Darwin.close(fd) != 0, failure == nil { failure = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        if let failure {
            _ = Darwin.unlink(path)
            throw failure
        }
    }

    /// The answer `nido act get-file` prints: when the answer is ok, the bytes are written to
    /// `local` first (`writeLocalFile`), and a write that fails (or no bytes) turns the answer into
    /// a failure with the reason and no `bytes`, so the JSON never says ok, nor a size, while no
    /// file was written. A failed answer passes through and nothing is written.
    public static func completeGetFile(_ answer: AgentAnswer, data: Data?, to local: String, force: Bool) -> AgentAnswer {
        guard answer.ok else { return answer }
        guard let data else { return .failure(.internalError, L10n.string("could not read the copied file")) }
        do {
            try writeLocalFile(data, to: local, force: force)
            return answer
        } catch {
            var failed = answer
            failed.ok = false
            failed.error = .internalError
            failed.message = CLISupport.message(for: error)
            failed.bytes = nil
            return failed
        }
    }

    // MARK: - Helpers

    private struct StatusReport: Encodable {
        var agentAccess: Bool
        var running: Bool
        var helper: AgentAnswer?
    }

    // MARK: Activity log (`nido agent log`)

    /// Entries `nido agent log` shows when `--limit` is not given.
    public static let defaultLogLimit = 50

    /// `--limit`: a whole number of at least 1, or `defaultLogLimit` when not given.
    public static func logLimit(_ text: String?) throws -> Int? {
        guard let text else { return defaultLogLimit }
        guard let value = Int(text), value >= 1 else { throw CLIError.agentLogLimitInvalid }
        return value
    }

    /// `--clear` stands alone: with `--limit` or `--json` it would do something else than asked.
    /// `--yes` only answers `--clear`'s question, so without it it is a mistake.
    public static func validateLogOptions(clear: Bool, limit: String?, json: Bool, yes: Bool = false) throws {
        if clear && (limit != nil || json) { throw CLIError.agentLogClearConflict }
        if yes && !clear { throw CLIError.agentLogYesWithoutClear }
    }

    /// What `nido agent log` says on standard error when there is nothing to show.
    public static func emptyLogMessage(vm: String) -> String {
        L10n.string("No agent activity for \(printable(vm)).")
    }

    /// The log as text, oldest first: one line per entry,
    /// `HH:mm:ss.SSS <client> <op> <detail> ok|<error>[: <message>] (<ms> ms)`, the time in
    /// `timeZone` (the Mac's by default), `detail` as sorted `key=value`. A line
    /// `— session <first 8 characters of the id> (<client>) —` opens each run. Control characters
    /// never reach the terminal.
    public static func logLines(_ entries: [AgentActivityEntry], timeZone: TimeZone = .current) -> [String] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm:ss.SSS"
        var lines: [String] = []
        var session: String?
        for entry in entries {
            if entry.session != session {
                session = entry.session
                let id = printable(String(entry.session.prefix(8)))
                lines.append(L10n.string("— session \(id) (\(printable(entry.client))) —"))
            }
            var parts = [formatter.string(from: entry.time), printable(entry.client), printable(entry.op)]
            for key in entry.detail.keys.sorted() {
                parts.append("\(printable(key))=\(printable(entry.detail[key] ?? ""))")
            }
            if entry.ok {
                parts.append("ok")
            } else {
                let code = printable(entry.error ?? "error")
                parts.append(entry.message.map { "\(code): \(printable($0))" } ?? code)
            }
            parts.append("(\(entry.ms) ms)")
            lines.append(parts.joined(separator: " "))
        }
        return lines
    }

    /// The entries as one JSON array (sorted keys, unescaped slashes); `[]` when there are none.
    public static func logJSON(_ entries: [AgentActivityEntry]) -> String { encode(entries) }

    /// Empties the VM's log. Without `yes` it asks (`confirm`) on a terminal and refuses without
    /// one. Returns false when the user said no.
    public static func clearLog(
        bundle: VMBundle, yes: Bool, stdinIsTerminal: Bool, confirm: (String) -> Bool
    ) throws -> Bool {
        if !yes {
            guard stdinIsTerminal else { throw CLIError.agentLogClearNeedsConfirmation }
            guard confirm(L10n.string("Clear the agent activity log of this VM? [y/N] ")) else { return false }
        }
        try AgentActivityLog.clear(in: bundle)
        return true
    }

    /// `text` with every control character (line breaks, escapes, DEL) turned into a space.
    private static func printable(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.map {
            $0.value < 0x20 || (0x7F...0x9F).contains($0.value) ? " " : $0
        }))
    }

    private static func encode(_ value: some Encodable) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // Only checkpoints carry a `Date` (an activity entry writes its own time).
        encoder.dateEncodingStrategy = .iso8601
        return String(decoding: (try? encoder.encode(value)) ?? Data("{}".utf8), as: UTF8.self)
    }

    private static func number(_ text: String, name: String) throws -> Double {
        guard let value = Double(text), value.isFinite else { throw CLIError.agentNotANumber(name) }
        return value
    }

    private static func integer(_ text: String, name: String, in range: ClosedRange<Int>) throws -> Int {
        guard let value = Int(text), range.contains(value) else {
            throw CLIError.agentOutOfRange(name, range.lowerBound, range.upperBound)
        }
        return value
    }

    /// The arguments of one action: known `--flag`s, known `--option value`s and positionals.
    /// A negative number is a positional, not an option: only `--` words are options.
    private struct Parsed {
        var flags: Set<String> = []
        var options: [String: String] = [:]
        var positionals: [String] = []

        init(_ args: [String], usage: String, flags knownFlags: Set<String>, options knownOptions: Set<String>,
             positionals count: Int) throws {
            var i = 0
            while i < args.count {
                let arg = args[i]
                i += 1
                if arg.hasPrefix("--") {
                    if knownFlags.contains(arg) {
                        flags.insert(arg)
                    } else if knownOptions.contains(arg), i < args.count, options[arg] == nil {
                        options[arg] = args[i]
                        i += 1
                    } else {
                        throw CLIError.agentUsage(usage)
                    }
                } else {
                    positionals.append(arg)
                }
            }
            guard positionals.count == count else { throw CLIError.agentUsage(usage) }
        }
    }
}
