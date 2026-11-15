// SPDX-License-Identifier: Apache-2.0
import Foundation
import NidoAgentKit

/// What FileVault and automatic login look like in a macOS guest, read by
/// `MacAgentInstaller.loginStateScript`. Nido only reads and explains these settings: it never
/// changes FileVault or the login settings of a guest.
public struct MacLoginState: Equatable, Sendable {
    /// FileVault is on (true), off (false) or could not be told (nil).
    public var fileVaultOn: Bool?
    /// The account that logs in by itself at start, if any.
    public var autoLoginUser: String?

    public init(fileVaultOn: Bool? = nil, autoLoginUser: String? = nil) {
        self.fileVaultOn = fileVaultOn
        self.autoLoginUser = autoLoginUser
    }

    /// What to tell the user when FileVault is on (nil otherwise): the guest blocks every agent
    /// action until someone logs in through the VM's window.
    public var advice: String? {
        guard fileVaultOn == true else { return nil }
        return L10n.string("FileVault is on in this VM: an agent can use it only after you log in through its window at each start. To start it headless, turn off FileVault and turn on automatic login in the VM.")
    }
}

/// `nido agent setup`: copies `NidoAgent.app` into a macOS guest over SSH, opens it, and waits for
/// the user to grant the permissions in the guest. Every command sent to the guest is a constant
/// script (`GuestCommand`); the app travels as a tar archive on stdin, and no path of the Mac is
/// ever shared with the guest. No script uses `sudo`: everything happens as the guest's user.
public enum MacAgentInstaller {
    /// Extracts the archive on stdin under a fresh `mktemp -d` in `~/Library/Caches` (same volume
    /// as `~/Applications`, so the last `mv` is an atomic rename), checks the code signature and the
    /// identifier of the extracted app, quits a running helper and swaps the new app in. The old one
    /// is kept aside as `.old` until the new one is in place and put back if the swap fails.
    ///
    /// The helper is stopped with `pkill -x NidoAgent` (SIGTERM, only this user's process): it works
    /// without a window server, whereas `osascript ... to quit` would first *launch* an app that
    /// is not running. A running helper is no obstacle to the swap (the old bundle stays valid for
    /// the process until it ends). Prints the installed `CFBundleShortVersionString`.
    static let installScript = #"""
        set -eu
        umask 022
        app="$HOME/Applications/NidoAgent.app"
        mkdir -p "$HOME/Library/Caches" "$HOME/Applications"
        tmp=$(mktemp -d "$HOME/Library/Caches/nido-agent.XXXXXX")
        trap 'rm -rf "$tmp"' EXIT
        tar -x -C "$tmp" -f -
        new="$tmp/NidoAgent.app"
        if [ ! -d "$new" ] || [ -L "$new" ]; then
            echo "NidoAgent.app is missing from the archive" >&2
            exit 1
        fi
        codesign --verify --strict "$new"
        if ! codesign -dv "$new" 2>&1 | grep -q '^Identifier=io.gitlab.pichierri.Nido.Agent$'; then
            echo "NidoAgent.app has an unexpected identifier" >&2
            exit 1
        fi
        pkill -U "$(id -u)" -x NidoAgent || true
        rm -rf "$app.old"
        if [ -e "$app" ] || [ -L "$app" ]; then
            mv "$app" "$app.old"
        fi
        if ! mv "$new" "$app"; then
            if [ -e "$app.old" ]; then mv "$app.old" "$app"; fi
            exit 1
        fi
        rm -rf "$app.old"
        /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist"
        """#

    /// Opens the installed helper in the background (`-g`). It needs a session of that user in the
    /// guest: when no one is logged in, `open` fails.
    static let openScript = #"open -g "$HOME/Applications/NidoAgent.app""#

    /// Prints `filevault=on|off|unknown` (from `fdesetup status`, which needs no privileges) and
    /// `autologin=<account or empty>` (the login window's setting).
    static let loginStateScript = #"""
        set -u
        status=$(fdesetup status 2>/dev/null || true)
        case "$status" in
            *"FileVault is On"*) filevault=on ;;
            *"FileVault is Off"*) filevault=off ;;
            *) filevault=unknown ;;
        esac
        printf 'filevault=%s\n' "$filevault"
        printf 'autologin=%s\n' "$(defaults read /Library/Preferences/com.apple.loginwindow autoLoginUser 2>/dev/null || true)"
        """#

    /// The scripts' output as a `MacLoginState`; anything unexpected is "unknown" (nil).
    public static func parseLoginState(_ stdout: String) -> MacLoginState {
        var state = MacLoginState()
        for line in stdout.split(whereSeparator: \.isNewline) {
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals]
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "filevault":
                state.fileVaultOn = value == "on" ? true : value == "off" ? false : nil
            case "autologin":
                let user = GuestSSH.sanitize(value, limit: 64)
                state.autoLoginUser = user.isEmpty ? nil : user
            default:
                break
            }
        }
        return state
    }

    /// The version `installScript` printed, safe to show (control characters dropped, 32 characters).
    public static func installedVersion(_ stdout: String) -> String {
        GuestSSH.sanitize(stdout, limit: 32)
    }

    // MARK: - Payload

    /// `/usr/bin/tar -c -C <parent> NidoAgent.app`, in memory (the app is small). `--no-mac-metadata --no-xattrs`
    /// leaves out the `._` files and extended attributes (`ProcessRunner` gives the child a fixed
    /// environment, so `COPYFILE_DISABLE` cannot be set). Throws `macAgentUnavailable` for a
    /// directory not called `NidoAgent.app`.
    public static func payload(app: URL, runner: ProcessRunner = SystemProcessRunner()) throws -> Data {
        guard app.lastPathComponent == "NidoAgent.app" else { throw NidoError.macAgentUnavailable }
        let result = try runner.run(
            executable: URL(fileURLWithPath: "/usr/bin/tar"),
            arguments: ["--no-mac-metadata", "--no-xattrs", "-c", "-C", app.deletingLastPathComponent().path, "NidoAgent.app"],
            stdin: nil, timeout: 120, maxOutput: 256 << 20)
        guard result.status == 0, !result.timedOut else {
            throw NidoError.processFailed(executable: "/usr/bin/tar", status: result.status)
        }
        return result.stdout
    }

    // MARK: - Versions

    /// Compares dotted numeric versions (`1.10` is newer than `1.2`; missing parts count as 0, a
    /// part's non-digit tail is ignored): negative, 0 or positive.
    public static func compareVersions(_ a: String, _ b: String) -> Int {
        func parts(_ text: String) -> [Int] {
            text.split(separator: ".", omittingEmptySubsequences: false).map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        }
        let (x, y) = (parts(a), parts(b))
        for index in 0..<max(x.count, y.count) {
            let (l, r) = (index < x.count ? x[index] : 0, index < y.count ? y[index] : 0)
            if l != r { return l < r ? -1 : 1 }
        }
        return 0
    }


    /// What to do about the helper already in the guest, from its `status` answer.
    public enum InstallDecision: Equatable, Sendable {
        /// Absent (no answer, `notReady`, any failure), older than the bundled one, or unable to
        /// speak this Nido's protocol (`versionMismatch`).
        case install
        /// The same version as the bundled one.
        case current
        /// Newer than the bundled one and answering normally: never downgraded.
        case newer
    }

    public static func installDecision(helper: AgentAnswer, bundledVersion: String) -> InstallDecision {
        guard helper.ok, let version = helper.status?.helperVersion else { return .install }
        let order = compareVersions(version, bundledVersion)
        return order < 0 ? .install : order == 0 ? .current : .newer
    }

    // MARK: - Waiting for the permissions

    public enum Outcome: Equatable, Sendable {
        /// The helper answers and both permissions are granted.
        case ready
        /// The deadline passed without that.
        case timedOut
        /// The VM stopped while waiting.
        case stopped
        /// Agent access was turned off while waiting.
        case accessOff
        /// The helper cannot speak this Nido's protocol (the message was printed).
        case versionMismatch
        /// The calling task was cancelled: the wait stopped at once.
        case cancelled
    }

    /// One step of the wait, before it is put into words (`awaitReady` prints them, the app shows
    /// its own).
    public enum WaitEvent: Equatable, Sendable {
        /// The helper answers and both permissions are granted.
        case ready
        /// The helper answers without both permissions: the user has to allow it.
        case grantPermissions
        /// The helper stopped answering: it is opened again.
        case reopening
        /// No helper answers and no session opens it: the user has to log in.
        case logIn
        /// The helper answered with an error (the guest's message).
        case helperError(String)
        /// The deadline passed.
        case timedOut

        /// The line for the event in VM `vm`: what `nido agent setup` prints, or with `.app` the
        /// app's Agent pane (the timeout then names its button, not the command).
        public func line(vm: String, on surface: MacAgentSetup.Surface = .cli) -> String {
            switch self {
            case .timedOut where surface == .app:
                L10n.string("Timed out waiting for Nido Agent in \(vm): grant the permissions, then click Install Nido Agent again.")
            case .ready: L10n.string("Nido Agent is ready in \(vm).")
            case .grantPermissions:
                L10n.string("In the VM, allow Nido Agent in Screen Recording and Accessibility (System Settings › Privacy & Security).")
            case .reopening: L10n.string("Nido Agent stopped: opening it again.")
            case .logIn: L10n.string("Log in to \(vm) in its window.")
            case .helperError(let message): L10n.string("Nido Agent answered with an error: \(message)")
            case .timedOut:
                L10n.string("Timed out waiting for Nido Agent in \(vm): grant the permissions, then run nido agent setup \(vm) again.")
            }
        }
    }

    /// How long to wait for the permissions, and how long a `notReady` right after the helper was
    /// opened is taken for its start-up rather than for a missing login.
    public static let waitLimit: Duration = .seconds(600)
    public static let loginGrace: Duration = .seconds(15)
    /// How many times one wait opens the helper again (`reopen`).
    public static let maxReopens = 3

    /// Polls `status` (the helper's `status` through the control socket) until `timeout` has passed
    /// on `now`, calling `sleep` between polls (2 s in `nido agent setup`), and reports progress through `emit` one line at a
    /// time. The permission hint is printed once, when the helper first answers without both
    /// permissions; the first other unexpected error once. `versionMismatch` ends the wait with
    /// its message, `notRunning` and `agentAccessOff` end it silently (the caller reports them).
    ///
    /// `notReady` means no helper answers. Right after `open` the helper is usually not listening
    /// yet, so for `loginGrace` it is only waited for. A helper that answered and then stops
    /// answering has stopped (on macOS 26, allowing Screen Recording in System Settings asks to
    /// quit the app, and the helper was seen not to come back), so `reopen` (the guest's `open`)
    /// runs at once. A helper still silent `loginGrace` after an `open` gets one
    /// more `reopen`; only when that fails (no session for `open`) or the helper is still silent
    /// `loginGrace` later is the login hint printed, once. `reopen` runs at most `maxReopens`
    /// times. The clock, the sleep, the status and `reopen` are injected so tests run at once; a
    /// slow `status` cannot push the end past the deadline by more than one call.
    public static func awaitReady(
        vm: String, timeout: Duration = waitLimit, loginGrace: Duration = loginGrace,
        now: () -> ContinuousClock.Instant = { ContinuousClock.now },
        status: () -> AgentAnswer, reopen: () async -> Bool, sleep: () async -> Void, emit: (String) -> Void
    ) async -> Outcome {
        await awaitReadyEvents(
            timeout: timeout, loginGrace: loginGrace, now: now, status: status, reopen: reopen, sleep: sleep,
            emit: { emit($0.line(vm: vm)) })
    }

    /// `awaitReady` reporting `WaitEvent`s instead of lines. A cancelled calling task ends the wait
    /// at the next poll (`.cancelled`): `sleep` should return when cancelled, as `Task.sleep` does.
    public static func awaitReadyEvents(
        timeout: Duration = waitLimit, loginGrace: Duration = loginGrace,
        now: () -> ContinuousClock.Instant = { ContinuousClock.now },
        status: () -> AgentAnswer, reopen: () async -> Bool, sleep: () async -> Void,
        emit: (WaitEvent) -> Void
    ) async -> Outcome {
        let start = now()
        let deadline = start.advanced(by: timeout)
        var saidLogin = false
        var saidPermissions = false
        var saidError = false
        // When `open` last ran, whether the helper answered since, whether the retry after a
        // silent `loginGrace` was used, and how many `reopen` ran.
        var opened = start
        var answeredSinceOpen = false
        var retried = false
        var reopens = 0
        func sayLogin() {
            guard !saidLogin else { return }
            saidLogin = true
            emit(.logIn)
        }
        while true {
            if Task.isCancelled { return .cancelled }
            // The guest wrote `message`: cleaned before any of it is printed.
            let answer = status().cleaned
            if answer.ok, let status = answer.status {
                answeredSinceOpen = true
                if status.screenRecording && status.accessibility {
                    emit(.ready)
                    return .ready
                }
                if !saidPermissions {
                    saidPermissions = true
                    emit(.grantPermissions)
                }
            } else {
                switch answer.error {
                case .notReady:
                    if answeredSinceOpen && reopens < maxReopens {
                        emit(.reopening)
                        reopens += 1
                        if !(await reopen()) { sayLogin() }
                        (opened, answeredSinceOpen, retried) = (now(), false, false)
                    } else if opened.duration(to: now()) >= loginGrace {
                        if !retried && reopens < maxReopens {
                            retried = true
                            reopens += 1
                            if await reopen() { opened = now() } else { sayLogin() }
                        } else {
                            sayLogin()
                        }
                    }
                case .notRunning:
                    return .stopped
                case .agentAccessOff:
                    return .accessOff
                case .versionMismatch:
                    emit(.helperError(answer.message ?? ""))
                    return .versionMismatch
                default:
                    if !saidError {
                        saidError = true
                        emit(.helperError(answer.message ?? ""))
                    }
                }
            }
            if now() >= deadline { break }
            await sleep()
        }
        emit(.timedOut)
        return .timedOut
    }
}
