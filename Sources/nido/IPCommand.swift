// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import NidoCLI
import NidoCore

struct IPCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ip",
        abstract: L10n.string("Show the VM’s IP address.")
    )

    @Argument(help: ArgumentHelp(L10n.string("VM name.")))
    var name: String

    func run() throws {
        let (_, bundle) = try Terminal.openBundle(name)
        print(try CLISupport.ipDescription(bundle: bundle, leasesURL: DHCPLeases.defaultURL))
    }
}
