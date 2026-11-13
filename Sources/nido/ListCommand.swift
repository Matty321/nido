// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import NidoCLI
import NidoCore

struct ListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: L10n.string("List the VMs with their state, system, CPUs and memory.")
    )

    func run() throws {
        let rows = try CLISupport.listVMs(paths: CLISupport.preparedPaths())
        if rows.isEmpty {
            print(L10n.string("No VMs."))
        } else {
            print(CLISupport.formatList(rows))
        }
    }
}
