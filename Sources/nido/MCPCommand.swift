// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import Foundation
import NidoCLI
import NidoCore

/// `nido mcp <vm>`: a Model Context Protocol server on stdio for one macOS VM, started by the MCP
/// client (Claude Code, …) as a subprocess. Each tool call goes to the control socket of the
/// process that runs the VM; this command never starts a VM. Stdout carries only protocol lines.
///
/// A plain `ParsableCommand`: the loop blocks on stdin and on the socket, on the calling thread.
struct MCPCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mcp",
        abstract: L10n.string("Serve a running macOS VM to an AI agent as an MCP server on stdin/stdout."),
        discussion: L10n.string("An MCP client starts this command itself; use --config to print the entry to add to its configuration. The VM must be running with agent access on (nido agent enable).")
    )

    @Argument(help: ArgumentHelp(L10n.string("VM name.")))
    var vm: String

    @Flag(help: ArgumentHelp(L10n.string("Print the MCP client configuration for this VM and exit.")))
    var config = false

    func run() throws {
        let (vmName, bundle) = try Terminal.openBundle(vm)
        let vmConfig = try bundle.readConfig()
        try AgentSupport.requireAgentAccess(vmConfig)

        if config {
            print(Self.configSnippet(vm: vmName.rawValue, executable: Self.executablePath()))
            return
        }
        let client = AgentSupport.client(bundle: bundle, config: vmConfig)
        MCPServer(vmName: vmName.rawValue, actions: client)
            .run(input: .standardInput, output: .standardOutput)
    }

    /// The `mcpServers` entry for `vm`, as one line of JSON.
    static func configSnippet(vm: String, executable: String) -> String {
        let object: [String: Any] = [
            "mcpServers": ["nido-\(vm)": ["command": executable, "args": ["mcp", vm]]]
        ]
        let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data ?? Data("{}".utf8), as: UTF8.self)
    }

    /// The path the user ran this command by, made absolute but not resolved through symlinks (so
    /// `~/.local/bin/nido` stays as it is): a word with a `/` is taken against the current
    /// directory, a bare name is looked up in `PATH`.
    static func executablePath() -> String {
        let argument = CommandLine.arguments.first ?? "nido"
        if argument.hasPrefix("/") { return URL(fileURLWithPath: argument).standardizedFileURL.path }
        if argument.contains("/") {
            return URL(fileURLWithPath: argument, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
                .standardizedFileURL.path
        }
        let search = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
        for directory in search {
            let candidate = "\(directory)/\(argument)"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate).standardizedFileURL.path
            }
        }
        return Bundle.main.executablePath ?? argument
    }
}
