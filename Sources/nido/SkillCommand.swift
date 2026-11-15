// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import Foundation
import NidoCore

/// `nido skill install|get`: the `nido-agent` skill for Claude Code.
struct SkillCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "skill",
        abstract: L10n.string("Install or print the nido-agent skill, which teaches an AI agent to drive a macOS VM."),
        discussion: L10n.string("The skill is for Claude Code and works with the MCP server of nido mcp."),
        subcommands: [Install.self, Get.self]
    )

    struct Install: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "install",
            abstract: L10n.string("Write the skill to ~/.claude/skills/nido-agent (or --dir) and print the file’s path."))

        @Option(help: ArgumentHelp(L10n.string("Folder to install into, instead of ~/.claude/skills/nido-agent."), valueName: "path"))
        var dir: String?

        @Flag(help: ArgumentHelp(L10n.string("Replace an existing SKILL.md that nido did not write.")))
        var force = false

        func run() throws {
            let directory = dir.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
                ?? AgentSkill.defaultDirectory()
            print(try AgentSkill.install(dir: directory, force: force).path)
        }
    }

    /// Prints the installed text exactly, marker line included: `nido skill get > SKILL.md`
    /// gives the file `install` writes.
    struct Get: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "get", abstract: L10n.string("Print the skill text on standard output."))

        func run() throws {
            print(AgentSkill.text, terminator: "")
        }
    }
}
