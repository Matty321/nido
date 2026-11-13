// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import NidoCLI
import NidoCore

struct DeleteCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: L10n.string("Delete a stopped VM and its disk.")
    )

    @Argument(help: ArgumentHelp(L10n.string("VM name.")))
    var name: String

    @Flag(help: ArgumentHelp(L10n.string("Delete without asking for confirmation.")))
    var yes = false

    func run() throws {
        let vmName = try VMName(name)
        let paths = try CLISupport.preparedPaths()
        _ = try VMBundle.open(vmName, paths: paths)  // fail before prompting if it does not exist
        guard yes || Terminal.confirm(L10n.string("Delete the VM \(vmName.rawValue) and its disk? [y/N] ")) else {
            Terminal.error(L10n.string("Deletion canceled."))
            throw ExitCode.failure
        }
        try VMControl.deleteVM(vmName, paths: paths, owner: .cliOperation)
        print(L10n.string("VM \(vmName.rawValue) deleted."))
    }
}
