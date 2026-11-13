// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import Foundation
import NidoCLI
import NidoCore

struct RosettaCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rosetta",
        abstract: L10n.string("Run x86_64 binaries in Linux VMs with Rosetta."),
        discussion: L10n.string("Rosetta is turned on for a stopped VM and takes effect at its next start. Installing it on the Mac is a system installation and only starts after you confirm. It doesn’t apply to macOS VMs: in macOS, Rosetta is installed inside the VM."),
        subcommands: [Status.self, Install.self, Enable.self, Disable.self]
    )

    struct Status: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "status", abstract: L10n.string("Show whether Rosetta for Linux is installed on this Mac."))

        func run() throws {
            print(CLISupport.rosettaStatus(.current))
        }
    }

    struct Install: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "install", abstract: L10n.string("Install Rosetta for Linux on this Mac (asks for confirmation)."))

        @Flag(name: [.customShort("y"), .long], help: ArgumentHelp(L10n.string("Don’t ask for confirmation.")))
        var yes = false

        func run() async throws {
            print(try await CLISupport.installRosetta(
                state: .current, assumeYes: yes, confirm: Terminal.confirm,
                install: RosettaSupport.install))
        }
    }

    struct Enable: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "enable", abstract: L10n.string("Turn on Rosetta for a stopped VM."))

        @Argument(help: ArgumentHelp(L10n.string("VM name.")))
        var vm: String

        func run() throws {
            print(try CLISupport.setRosetta(vm: vm, enabled: true, paths: try CLISupport.preparedPaths()))
        }
    }

    struct Disable: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "disable", abstract: L10n.string("Turn off Rosetta for a stopped VM."))

        @Argument(help: ArgumentHelp(L10n.string("VM name.")))
        var vm: String

        func run() throws {
            print(try CLISupport.setRosetta(vm: vm, enabled: false, paths: try CLISupport.preparedPaths()))
        }
    }
}
