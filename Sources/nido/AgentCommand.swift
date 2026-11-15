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
        subcommands: [Enable.self, Disable.self, Setup.self, Password.self, Status.self]
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
            do {
                let setup = try MacAgentSetup.live(
                    bundle: bundle, config: config, surface: .cli, describe: { CLISupport.message(for: $0) },
                    askPassword: isatty(0) != 0 ? Self.terminalPassword(user: config.sshUser ?? "nido", vm: name) : nil)
                ready = try await setup.run { event in
                    switch event {
                    case .error(let line): Terminal.error(line)
                    default: print(event.line(vm: name))
                    }
                }
            } catch let error as MacAgentSetupError {
                throw AgentSupport.cliError(error)
            }
            if !ready { throw ExitCode.failure }
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
                let client = AgentSupport.client(bundle: bundle, config: config)
                helper = AgentSupport.helperAnswer { try client.send(.status) }
            }
            print(AgentSupport.statusJSON(agentAccess: access, running: running, helper: helper))
        }
    }
}
