// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import Foundation
import NidoCLI
import NidoCore

struct SnapshotCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "snapshot",
        abstract: L10n.string("Manage a VM’s snapshots: disk and NVRAM (and state, when the app takes them while the VM runs)."),
        discussion: L10n.string("From the command line, snapshots are created, restored and deleted only while the VM is stopped; a VM running in the app is snapshotted from the app."),
        subcommands: [List.self, Create.self, Restore.self, Delete.self]
    )

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "list", abstract: L10n.string("List a VM’s snapshots."))

        @Argument(help: ArgumentHelp(L10n.string("VM name.")))
        var vm: String

        func run() throws {
            print(try CLISupport.listSnapshots(vm: vm, paths: try CLISupport.preparedPaths()))
        }
    }

    struct Create: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "create", abstract: L10n.string("Take a snapshot of a stopped VM."))

        @Argument(help: ArgumentHelp(L10n.string("VM name.")))
        var vm: String

        @Argument(help: ArgumentHelp(L10n.string("Snapshot name (letters, digits, '.', '_', '-').")))
        var name: String

        func run() async throws {
            print(try await CLISupport.createSnapshot(vm: vm, name: name, paths: try CLISupport.preparedPaths()))
        }
    }

    struct Restore: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "restore", abstract: L10n.string("Restore a stopped VM to a snapshot."))

        @Argument(help: ArgumentHelp(L10n.string("VM name.")))
        var vm: String

        @Argument(help: ArgumentHelp(L10n.string("Snapshot name or ID (as in `nido snapshot list`).")))
        var snapshot: String

        @Flag(help: ArgumentHelp(L10n.string("Restore without asking for confirmation.")))
        var yes = false

        func run() throws {
            let paths = try CLISupport.preparedPaths()
            let (bundle, found) = try CLISupport.findSnapshot(vm: vm, reference: snapshot, paths: paths)
            let suspended = (try? bundle.readConfig()).map { bundle.hasSuspendedState($0) } ?? false
            guard yes || Terminal.confirm(
                CLISupport.restoreQuestion(vm: vm, snapshot: found.name, suspended: suspended))
            else {
                Terminal.error(L10n.string("Restore canceled."))
                throw ExitCode.failure
            }
            print(try CLISupport.restoreSnapshot(vm: vm, reference: found.id.uuidString, paths: paths))
        }
    }

    struct Delete: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "delete", abstract: L10n.string("Delete a snapshot of a stopped VM."))

        @Argument(help: ArgumentHelp(L10n.string("VM name.")))
        var vm: String

        @Argument(help: ArgumentHelp(L10n.string("Snapshot name or ID (as in `nido snapshot list`).")))
        var snapshot: String

        @Flag(help: ArgumentHelp(L10n.string("Delete without asking for confirmation.")))
        var yes = false

        func run() throws {
            let paths = try CLISupport.preparedPaths()
            let (_, found) = try CLISupport.findSnapshot(vm: vm, reference: snapshot, paths: paths)
            guard yes || Terminal.confirm(L10n.string("Delete the snapshot \(found.name) of \(vm)? [y/N] ")) else {
                Terminal.error(L10n.string("Deletion canceled."))
                throw ExitCode.failure
            }
            print(try CLISupport.deleteSnapshot(vm: vm, reference: found.id.uuidString, paths: paths))
        }
    }
}
