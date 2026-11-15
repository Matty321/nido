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

    /// What `nido act <vm> …` does: send an action to the VM's owner (and maybe copy the
    /// screenshot it saved), or sleep on this side.
    public enum Invocation: Equatable, Sendable {
        case send(AgentAction, output: String?)
        case wait(milliseconds: Int)
    }

    /// The longest a `wait` may take, in milliseconds (the same as the MCP tool's).
    public static let maxWaitMilliseconds = AgentProtocol.maxWaitMilliseconds

    /// The range `--max` accepts (the long edge of the screenshot, in pixels; the same as the
    /// MCP tool's).
    public static let maxLongEdgeRange = AgentProtocol.maxLongEdgeRange

    /// The action in `args` (`["click", "10", "20", "--right"]`), as `nido act <vm>` takes it.
    /// `wait` is not an action of the helper and has no value here: it throws a usage error.
    public static func parseAction(_ args: [String]) throws -> AgentAction {
        guard case .send(let action, _) = try parseInvocation(args) else {
            throw CLIError.agentUsage("wait MS")
        }
        return action
    }

    /// `args` as an `Invocation`: the action name, then its arguments; unknown options, missing or
    /// extra arguments and out-of-range values throw (`CLIError`, `KeyMapError` for a bad combo).
    public static func parseInvocation(_ args: [String]) throws -> Invocation {
        guard let name = args.first else { throw CLIError.agentUsage("status | screenshot | click | drag | scroll | type | key | wait") }
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

    /// `answer` as one line of JSON with sorted keys and unescaped slashes (a path stays readable).
    /// What the guest wrote in it is cleaned first (`AgentAnswer.cleaned`).
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

    /// The client of `bundle`'s control socket for `nido act`, `nido mcp` and `nido agent`. A VM
    /// that runs (bundle lock held) with agent access on in its configuration but has no socket
    /// file is told to restart, not to start.
    public static func client(bundle: VMBundle, config: VMConfig) -> AgentControlClient {
        AgentControlClient.forVM(bundle: bundle, config: config)
    }

    /// Throws `CLIError.agentAccessOff` unless the VM's agent access is on.
    public static func requireAgentAccess(_ config: VMConfig) throws {
        guard config.agentAccess == true else { throw CLIError.agentAccessOff(config.name.rawValue) }
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

    // MARK: - Helpers

    private struct StatusReport: Encodable {
        var agentAccess: Bool
        var running: Bool
        var helper: AgentAnswer?
    }

    private static func encode(_ value: some Encodable) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
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
