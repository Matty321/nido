// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import Foundation
import NidoCLI
import NidoCore

@main
struct Nido: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "nido",
        abstract: L10n.string("Nido: a virtual machine manager for macOS."),
        discussion: L10n.string("NIDO_ROOT (the absolute path of an existing directory) replaces the default VM folder.")
            + "\n\n"
            + L10n.string("NIDO_LANGUAGE (en, it, de, es or fr) sets the language of nido’s messages; without it, nido follows the Mac’s language."),
        version: NidoVersion.current,
        subcommands: [
            CreateCommand.self, ListCommand.self, StartCommand.self, StopCommand.self,
            IPCommand.self, SSHCommand.self, DeleteCommand.self, ShareCommand.self, RosettaCommand.self,
            SnapshotCommand.self, CloneCommand.self, TemplateCommand.self, NetCommand.self, ImageCommand.self,
        ]
    )

    /// Parsing errors, help and explicit exit codes are handled by ArgumentParser (in English);
    /// every other error is printed once, in the UI language, as `Error: <msg>`.
    static func main() async {
        let command: any ParsableCommand
        do {
            command = try parseAsRoot()
        } catch {
            exit(withError: error)
        }
        do {
            if var asyncCommand = command as? any AsyncParsableCommand {
                try await asyncCommand.run()
            } else {
                var syncCommand = command
                try syncCommand.run()
            }
        } catch {
            // ExitCode, CleanExit, ValidationError and ArgumentParser's internal help/parse
            // errors (also thrown from `run()`, e.g. by the built-in help command).
            if String(reflecting: type(of: error)).hasPrefix("ArgumentParser.") {
                exit(withError: error)
            }
            Terminal.error(L10n.string("Error: \(CLISupport.message(for: error))"))
            exit(withError: ExitCode.failure)
        }
    }
}

/// Terminal I/O helpers: diagnostics and prompts go to stderr, results to stdout.
enum Terminal {
    static func error(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    /// Prints `question` on stderr and reads one line from stdin; EOF counts as "no".
    static func confirm(_ question: String) -> Bool {
        FileHandle.standardError.write(Data(question.utf8))
        return CLISupport.isAffirmative(readLine(strippingNewline: true))
    }

    /// Resolves the data root (`NIDO_ROOT` or default) and opens the named bundle.
    static func openBundle(_ name: String) throws -> (VMName, VMBundle) {
        let vmName = try VMName(name)
        let paths = try CLISupport.preparedPaths()
        return (vmName, try VMBundle.open(vmName, paths: paths))
    }
}
