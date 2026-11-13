// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import Darwin
import Foundation
import NidoCLI
import NidoCore

struct NetCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "net",
        abstract: L10n.string("Manage a VM’s controlled network: allowed domains and connection log."),
        discussion: L10n.string("Changes apply within seconds, even while the VM is running. Adding a domain asks for Touch ID or the Mac password; removing one doesn’t."),
        subcommands: [List.self, Log.self, Allow.self, Deny.self, Reset.self]
    )

    /// Touch ID can be asked only from a terminal someone is using.
    static var isInteractive: Bool { isatty(STDIN_FILENO) == 1 }

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "list", abstract: L10n.string("List a VM’s allowed domains."))

        @Argument(help: ArgumentHelp(L10n.string("VM name.")))
        var vm: String

        func run() throws {
            print(try CLISupport.netList(vm: vm, paths: try CLISupport.preparedPaths()))
        }
    }

    struct Log: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "log", abstract: L10n.string("Show a VM’s connection log (never what the connections carry)."))

        @Argument(help: ArgumentHelp(L10n.string("VM name.")))
        var vm: String

        @Flag(help: ArgumentHelp(L10n.string("Only blocks and cut connections.")))
        var blocked = false

        @Flag(help: ArgumentHelp(L10n.string("Include local noise (IPv6 multicast and link-local, broadcast), normally hidden.")))
        var all = false

        func run() throws {
            print(try CLISupport.netLog(
                vm: vm, paths: try CLISupport.preparedPaths(), blockedOnly: blocked, includeNoise: all))
        }
    }

    struct Allow: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "allow", abstract: L10n.string("Allow a domain for a VM (asks for Touch ID or the Mac password)."),
            discussion: L10n.string("example.com allows only that name; *.example.com also its subdomains. A broad wildcard (such as *.example.com or *.co.uk) asks for confirmation first."))

        @Argument(help: ArgumentHelp(L10n.string("VM name.")))
        var vm: String

        @Argument(help: ArgumentHelp(L10n.string("Domain, for example deb.debian.org or *.debian.org.")))
        var domain: String

        func run() async throws {
            print(try await CLISupport.netAllow(
                vm: vm, domain: domain, paths: try CLISupport.preparedPaths(), interactive: NetCommand.isInteractive,
                confirm: Terminal.confirm, authenticator: LocalOwnerAuthenticator()))
        }
    }

    struct Deny: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "deny", abstract: L10n.string("Remove a domain from a VM’s allowed domains; its open connections are cut."))

        @Argument(help: ArgumentHelp(L10n.string("VM name.")))
        var vm: String

        @Argument(help: ArgumentHelp(L10n.string("Domain, written as in nido net list.")))
        var domain: String

        func run() throws {
            print(try CLISupport.netDeny(vm: vm, domain: domain, paths: try CLISupport.preparedPaths()))
        }
    }

    struct Reset: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "reset",
            abstract: L10n.string("Reset a VM’s allowed domains to its system’s base list (asks for confirmation and Touch ID)."),
            discussion: L10n.string("Use it when egress.json is damaged: Nido doesn’t use the file and won’t overwrite it on its own."))

        @Argument(help: ArgumentHelp(L10n.string("VM name.")))
        var vm: String

        func run() async throws {
            print(try await CLISupport.netReset(
                vm: vm, paths: try CLISupport.preparedPaths(), interactive: NetCommand.isInteractive,
                confirm: Terminal.confirm, authenticator: LocalOwnerAuthenticator()))
        }
    }
}
