// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import Foundation
import NidoCLI
import NidoCore

struct StopCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stop",
        abstract: L10n.string("Ask a running VM to stop, or suspend it with --suspend.")
    )

    @Flag(help: ArgumentHelp(L10n.string("Suspend the VM: save its state to state.vzvmsave and stop it; the next nido start resumes from there. Only for VMs started with nido start.")))
    var suspend = false

    @Argument(help: ArgumentHelp(L10n.string("VM name.")))
    var name: String

    /// How long `--suspend` waits for the `nido start` process to save the state and exit.
    static let suspendTimeout: TimeInterval = 300

    func run() throws {
        let (vmName, bundle) = try Terminal.openBundle(name)
        guard suspend else {
            try VMControl.requestStop(bundle: bundle, name: vmName)
            print(L10n.string("Stop requested."))
            return
        }
        // An answer left by an earlier request must not be taken for this one's.
        VMControl.clearSuspendResult(bundle: bundle)
        try VMControl.requestSuspend(bundle: bundle, name: vmName)
        Terminal.error(L10n.string("Suspend requested: waiting for the VM to save its state…"))
        let report = CLISupport.waitForSuspend(bundle: bundle, timeout: Self.suspendTimeout)
        guard report == .suspended else { throw CLIError.suspendNotCompleted(report.message(vm: vmName.rawValue)) }
        print(report.message(vm: vmName.rawValue))
    }
}
