// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import Foundation
import NidoCLI
import NidoCore

struct ShareCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "share",
        abstract: L10n.string("Share Mac folders with a VM (in /mnt/nido/<name>)."),
        discussion: L10n.string("Folders are read only unless you pass --rw. They can be changed only while the VM is stopped and take effect at its next start."),
        subcommands: [List.self, Add.self, Remove.self]
    )

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "list", abstract: L10n.string("List a VM’s shared folders."))

        @Argument(help: ArgumentHelp(L10n.string("VM name.")))
        var vm: String

        func run() throws {
            print(try CLISupport.listShares(vm: vm, paths: try CLISupport.preparedPaths()))
        }
    }

    struct Add: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "add", abstract: L10n.string("Share a Mac folder with a stopped VM."))

        @Argument(help: ArgumentHelp(L10n.string("VM name.")))
        var vm: String

        @Argument(help: ArgumentHelp(L10n.string("Absolute path of the folder on the Mac.")))
        var path: String

        @Option(help: ArgumentHelp(L10n.string("Name of the folder in /mnt/nido (default: the folder’s own name).")))
        var name: String?

        @Flag(help: ArgumentHelp(L10n.string("Read & write: the VM can change and delete the folder’s files.")))
        var rw = false

        func run() throws {
            print(try CLISupport.addShare(
                vm: vm, path: path, name: name, readWrite: rw, paths: try CLISupport.preparedPaths()))
        }
    }

    struct Remove: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "remove", abstract: L10n.string("Stop sharing a folder with a stopped VM."))

        @Argument(help: ArgumentHelp(L10n.string("VM name.")))
        var vm: String

        @Argument(help: ArgumentHelp(L10n.string("Name of the shared folder (as in `nido share list`).")))
        var name: String

        func run() throws {
            print(try CLISupport.removeShare(vm: vm, name: name, paths: try CLISupport.preparedPaths()))
        }
    }
}
