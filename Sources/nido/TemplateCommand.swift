// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import NidoCLI
import NidoCore

struct TemplateCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "template",
        abstract: L10n.string("Manage VM templates: save a stopped VM as a template, or make it startable again."),
        discussion: L10n.string("A template can’t be started or cloned: create new VMs from it with nido create --from-template."),
        subcommands: [Save.self, Edit.self]
    )

    struct Save: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "save", abstract: L10n.string("Save a stopped VM as a template (its snapshots are kept)."))

        @Argument(help: ArgumentHelp(L10n.string("VM name.")))
        var vm: String

        func run() throws {
            print(try CLISupport.saveTemplate(vm: vm, paths: try CLISupport.preparedPaths()))
        }
    }

    struct Edit: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "edit", abstract: L10n.string("Make a template startable again, to update it."))

        @Argument(help: ArgumentHelp(L10n.string("Template name.")))
        var vm: String

        func run() throws {
            print(try CLISupport.editTemplate(vm: vm, paths: try CLISupport.preparedPaths()))
        }
    }
}
