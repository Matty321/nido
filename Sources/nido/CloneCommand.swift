// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import NidoCLI
import NidoCore

struct CloneCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clone",
        abstract: L10n.string("Copy a stopped VM under a new name."),
        discussion: L10n.string("The copy gets a new network address and a new identity (Linux: cloud-init sets it up as a new machine, with its own host name and SSH host keys; macOS: a new machine identifier, and the command lists the steps to run once in the guest for SSH keys and names). Rosetta is copied; shared folders, snapshots and the suspended state are not (the copy starts without shared folders).")
    )

    @Argument(help: ArgumentHelp(L10n.string("Name of the VM to copy.")))
    var source: String

    @Argument(help: ArgumentHelp(L10n.string("Name of the new VM (letters, digits, '.', '_', '-').")))
    var name: String

    func run() async throws {
        print(try await CLISupport.cloneVM(source: source, target: name, paths: try CLISupport.preparedPaths()))
    }
}
