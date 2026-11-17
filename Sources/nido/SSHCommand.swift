// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import Foundation
import NidoCLI
import NidoCore

struct SSHCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ssh",
        abstract: L10n.string("Open an SSH session in the VM (user nido; for macOS, the account given at creation).")
    )

    @Argument(help: ArgumentHelp(L10n.string("VM name.")))
    var name: String

    @Argument(parsing: .postTerminator, help: ArgumentHelp(L10n.string("Extra arguments for ssh, after --.")))
    var sshArguments: [String] = []

    func run() throws {
        let (_, bundle) = try Terminal.openBundle(name)
        let endpoint = try VMControl.resolveSSH(bundle: bundle, leasesURL: DHCPLeases.defaultURL)
        try VMControl.prepareKnownHosts(bundle: bundle)
        // macOS: port 22 probed once first, so Remote Login turned off is explained.
        let config = try bundle.readConfig()
        let argv = try CLISupport.sshArguments(
            config: config, endpoint: endpoint, knownHosts: bundle.knownHostsURL, extra: sshArguments)

        // A macOS VM: ssh runs as a child, so a refused key can be explained afterwards (the
        // FileVault login window) and, while the guest was never reached, its first success
        // recorded so the app's "Accesso da terminale" panel stops opening by itself.
        if config.guest == .macos {
            let exit = try CLISupport.runSSH(argv)
            if CLISupport.watchesSSHResult(config: config) {
                CLISupport.recordSSHResult(bundle: bundle, exit: exit, extra: sshArguments)
            }
            if let hint = CLISupport.loginWindowHint(config: config, exit: exit) {
                Terminal.error(hint)
            }
            throw ExitCode(exit.exitCode)
        }

        // Replace this process with ssh: no shell, absolute path, explicit argv.
        var cArguments: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
        defer { cArguments.forEach { free($0) } }
        execv("/usr/bin/ssh", &cArguments)
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ENOEXEC)
    }
}
