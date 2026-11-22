// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import Foundation
import NidoCLI
import NidoCore

struct AgentCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "agent",
        abstract: L10n.string("Let an AI agent see and drive a macOS VM (agent access)."),
        discussion: L10n.string("Agent access is off by default. When it is on, a program on this Mac running as you can take screenshots of the VM and use its keyboard and mouse through nido act."),
        subcommands: [Enable.self, Disable.self, Setup.self, Password.self, Status.self, Log.self]
    )

    struct Enable: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "enable", abstract: L10n.string("Turn agent access on for a macOS VM (from its next start)."))

        @Argument(help: ArgumentHelp(L10n.string("VM name.")))
        var vm: String

        func run() throws {
            let (_, bundle) = try Terminal.openBundle(vm)
            print(try AgentSupport.setAgentAccess(true, bundle: bundle))
        }
    }

    struct Disable: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "disable", abstract: L10n.string("Turn agent access off for a VM (at once, also while it runs)."))

        @Argument(help: ArgumentHelp(L10n.string("VM name.")))
        var vm: String

        func run() throws {
            let (_, bundle) = try Terminal.openBundle(vm)
            print(try AgentSupport.setAgentAccess(false, bundle: bundle))
        }
    }

    struct Setup: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "setup",
            abstract: L10n.string("Install Nido Agent in a running macOS VM over SSH and wait until you have allowed it."),
            discussion: L10n.string("Needs agent access on, the VM running and Remote Login on in the guest. Nido only reads FileVault and login settings and explains them: it never changes them."))

        @Argument(help: ArgumentHelp(L10n.string("VM name.")))
        var vm: String

        func run() async throws {
            let (vmName, bundle) = try Terminal.openBundle(vm)
            let config = try bundle.readConfig()
            let name = vmName.rawValue
            let ready: Bool
            let askPassword = isatty(0) != 0 ? Self.terminalPassword(user: config.sshUser ?? "nido", vm: name) : nil
            do {
                let setup = try MacAgentSetup.live(
                    bundle: bundle, config: config, surface: .cli, describe: { CLISupport.message(for: $0) },
                    askPassword: askPassword)
                ready = try await setup.run { event in
                    switch event {
                    case .error(let line): Terminal.error(line)
                    // A warning: the setup goes on.
                    case .passwordNotSaved: Terminal.error(event.line(vm: name))
                    default: print(event.line(vm: name))
                    }
                }
            } catch let error as MacAgentSetupError {
                throw AgentSupport.cliError(error)
            }
            if !ready { throw ExitCode.failure }
            // A key that already worked: the setup never read the stored password. An unusable
            // item is replaced now (asked once at the terminal), or told; the setup stays a success.
            switch await AgentSupport.replaceUnusablePassword(
                vm: name, id: config.id, store: KeychainGuestPasswordStore(), ask: askPassword)
            {
            case .unchanged: break
            case .replaced(let line): print(line)
            case .warning(let line): Terminal.error(line)
            }
        }

        /// Asks for the account's password on the terminal (no echo; `readpassphrase` reads from
        /// /dev/tty). A password `GuestPassword` refuses is told, not taken for none. The buffer is
        /// zeroed after use.
        static func terminalPassword(user: String, vm: String) -> @Sendable () async -> GuestPassword? {
            {
                let prompt = L10n.string("Password of \(user) in \(vm): ")
                guard let typed = CLISupport.readPassphrase(prompt: prompt) else { return nil }
                if typed.isEmpty { return nil }
                guard let password = GuestPassword(typed) else {
                    Terminal.error(L10n.string("That password can’t be used: it has a line break or is longer than 1023 bytes."))
                    return nil
                }
                return password
            }
        }
    }

    struct Password: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "password",
            abstract: L10n.string("Show the password of the account Nido created in a macOS VM."),
            discussion: L10n.string("Nido asks for Touch ID or the Mac password first. The password goes to standard output only."))

        @Argument(help: ArgumentHelp(L10n.string("VM name.")))
        var vm: String

        func run() async throws {
            let (_, bundle) = try Terminal.openBundle(vm)
            let config = try bundle.readConfig()
            print(try await AgentSupport.storedPassword(
                config: config, store: KeychainGuestPasswordStore(), owner: LocalOwnerAuthenticator()))
        }
    }

    struct Status: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "status",
            abstract: L10n.string("Show a VM’s agent access and, if it runs, the state of Nido Agent in it, as JSON."))

        @Argument(help: ArgumentHelp(L10n.string("VM name.")))
        var vm: String

        func run() throws {
            let (vmName, bundle) = try Terminal.openBundle(vm)
            let config = try bundle.readConfig()
            let running = BundleLock.holder(bundle) != nil
            let access = config.agentAccess == true
            var helper: AgentAnswer?
            if running && access {
                let client = AgentSupport.client(bundle: bundle, config: config, for: .nido)
                helper = AgentSupport.helperAnswer { try client.send(.status) }
            }
            print(AgentSupport.statusJSON(agentAccess: access, running: running, helper: helper))
        }
    }

    struct Log: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "log",
            abstract: L10n.string("Show what an agent did in a VM, oldest first."),
            discussion: L10n.string("Nido records each action an agent takes: which one, with what numbers, when and how it ended. It never records typed text (only how many characters), the clipboard or the text of the UI tree; screenshots and zooms keep a small thumbnail."))

        @Argument(help: ArgumentHelp(L10n.string("VM name.")))
        var vm: String

        @Option(help: ArgumentHelp(L10n.string("Show only the last N entries (default 50).")))
        var limit: String?

        @Flag(help: ArgumentHelp(L10n.string("Print the entries as a JSON array.")))
        var json = false

        @Flag(help: ArgumentHelp(L10n.string("Delete the log of this VM.")))
        var clear = false

        @Flag(help: ArgumentHelp(L10n.string("Clear without asking for confirmation.")))
        var yes = false

        func run() throws {
            try AgentSupport.validateLogOptions(clear: clear, limit: limit, json: json, yes: yes)
            let (vmName, bundle) = try Terminal.openBundle(vm)
            if clear {
                guard try AgentSupport.clearLog(
                    bundle: bundle, yes: yes, stdinIsTerminal: isatty(0) != 0, confirm: Terminal.confirm)
                else {
                    Terminal.error(L10n.string("Not cleared."))
                    throw ExitCode.failure
                }
                print(L10n.string("Agent activity log cleared."))
                return
            }
            let entries = try AgentActivityLog.read(in: bundle, limit: try AgentSupport.logLimit(limit))
            if json {
                print(AgentSupport.logJSON(entries))
            } else if entries.isEmpty {
                Terminal.error(AgentSupport.emptyLogMessage(vm: vmName.rawValue))
            } else {
                for line in AgentSupport.logLines(entries) { print(line) }
            }
        }
    }
}
