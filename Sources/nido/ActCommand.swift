// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import Foundation
import NidoCLI
import NidoCore

/// `nido act <vm> <action>`: one action on the screen of a running macOS VM, through the
/// control socket of the process that runs it. Prints the answer as one line of JSON.
///
/// A plain `ParsableCommand`: `run()` blocks on the socket (`AgentControlClient.send`) and,
/// not being on the main actor, holds nothing that the wait could starve.
struct ActCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "act",
        abstract: L10n.string("Act on the screen of a running macOS VM: screenshot, click, type… Prints one line of JSON."),
        discussion: [
            L10n.string("Actions:"),
            "  status",
            "  screenshot [--max N] [--output PATH]",
            "  zoom X Y W H [--max N] [--output PATH]",
            "  click X Y [--right] [--count N]",
            "  drag X1 Y1 X2 Y2",
            "  scroll --dx DX --dy DY [--x X --y Y]",
            "  type TEXT",
            "  key COMBO",
            "  wait MS",
            "",
            L10n.string("Coordinates are in the pixels of the last screenshot. The VM must be running with agent access on (nido agent enable). The exit code is 0 when the action succeeded and 1 otherwise; --output saves a copy of the screenshot or zoom and never overwrites a file."),
        ].joined(separator: "\n")
    )

    @Argument(help: ArgumentHelp(L10n.string("VM name.")))
    var vm: String

    @Argument(
        parsing: .captureForPassthrough,
        help: ArgumentHelp(L10n.string("The action and its arguments, as listed below."), valueName: "action"))
    var action: [String] = []

    func run() throws {
        let invocation = try AgentSupport.parseInvocation(action)
        let (vmName, bundle) = try Terminal.openBundle(vm)
        let config = try bundle.readConfig()
        try AgentSupport.requireAgentAccess(config)

        switch invocation {
        case .wait(let milliseconds):
            Thread.sleep(forTimeInterval: Double(milliseconds) / 1000)
            print(AgentSupport.json(AgentAnswer(ok: true)))
        case .send(let agentAction, let output):
            if let output, FileManager.default.fileExists(atPath: output) {
                throw CLIError.outputExists(output)
            }
            let client = AgentSupport.client(bundle: bundle, config: config)
            let answer = AgentSupport.completeScreenshot(try client.send(agentAction), output: output)
            print(AgentSupport.json(answer))
            if !answer.ok { throw ExitCode(1) }
        }
    }
}
