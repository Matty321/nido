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
            ActCommand.self, AgentCommand.self, MCPCommand.self, SkillCommand.self,
        ]
    )

    /// Parsing errors, help and explicit exit codes are handled by ArgumentParser (in English);
    /// every other error is printed once, in the UI language, as `Error: <msg>`.
    static func main() async {
        // stdout is line-buffered also into a pipe or a file (C's default there is a full buffer):
        // progress lines such as `nido agent setup`'s appear as they are printed, not at exit.
        // It stays the first statement: C allows `setvbuf` only before any output on the stream.
        // No automated test guards it (no command prints on stdout and then waits without a
        // running VM); checked by hand with `nido agent setup <vm> > file` on a real guest.
        setvbuf(stdout, nil, _IOLBF, 0)
        // ssh's askpass for `GuestSSH.authorizeNidoKey` (`NIDO_ASKPASS=1`): print the password
        // fetched from the one-shot socket and exit, before any argument parsing (argv[1] is
        // ssh's prompt) and without logging anything.
        if let code = Askpass.answer(
            environment: ProcessInfo.processInfo.environment, write: { try Askpass.writeAll($0) })
        {
            Foundation.exit(code)
        }
        // Never translated: a Rosetta process would see an Intel Mac and misreport the host.
        do {
            try HostChecks.refuseTranslated(isTranslated: HostChecks.isTranslatedProcess)
        } catch {
            Terminal.error(L10n.string("Error: \(CLISupport.message(for: error))"))
            exit(withError: ExitCode.failure)
        }
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
    /// A stderr that can't be written (closed by the client of `nido mcp`, with SIGPIPE ignored)
    /// loses the line: the throwing write never raises an Objective-C exception that would abort.
    static func error(_ message: String) {
        try? FileHandle.standardError.write(contentsOf: Data((message + "\n").utf8))
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
