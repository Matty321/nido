// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import Foundation
import NidoCLI
import NidoCore

struct ImageCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "image",
        abstract: L10n.string("Manage the catalog’s cloud images in the cache: list them and get new builds."),
        discussion: L10n.string("A new VM starts from the image in the cache. Debian and Ubuntu publish new builds (security fixes): check compares the cache with the published checksum list, update downloads the current build. Existing VMs don’t change."),
        subcommands: [List.self, Check.self, Update.self, Reset.self]
    )

    static func makeStore() -> ImageStore {
        ImageStore(cacheRoot: ImageStore.defaultCacheRoot(), session: ImageStore.makeDownloadSession())
    }

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "list", abstract: L10n.string("List the catalog images and which are downloaded (no network)."))

        func run() async throws {
            let store = ImageCommand.makeStore()
            var rows: [(image: CloudImage, cached: Bool)] = []
            for image in CloudImageCatalog.all { rows.append((image, await store.isCached(image))) }
            CLISupport.imageListLines(rows).forEach { print($0) }
        }
    }

    struct Check: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "check",
            abstract: L10n.string("Check whether the catalog publishes a newer build than the one in the cache."),
            discussion: L10n.string("Downloads only the checksum list of images already in the cache, never the image."))

        @Argument(help: ArgumentHelp(L10n.string("Image ID (all images if omitted).")))
        var id: String?

        func run() async throws {
            let images = try id.map { [try CLISupport.catalogImage(id: $0)] } ?? CloudImageCatalog.all
            let store = ImageCommand.makeStore()
            var failed = false
            for image in images {
                do {
                    let status = try await store.checkForUpdate(image)
                    print(CLISupport.imageStatusLine(image, status: status, build: await store.acceptedBuild(image)))
                } catch {
                    failed = true
                    Terminal.error(L10n.string("\(image.id): check failed: \(CLISupport.message(for: error))"))
                }
            }
            if failed { throw ExitCode.failure }
        }
    }

    struct Update: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "update",
            abstract: L10n.string("Download the current build of an image if it differs from the one in the cache."))

        @Argument(help: ArgumentHelp(L10n.string("Image ID.")))
        var id: String

        @Flag(help: ArgumentHelp(L10n.string("Confirm the download without asking.")))
        var yes = false

        func run() async throws {
            let image = try CLISupport.catalogImage(id: id)
            let store = ImageCommand.makeStore()
            let status = try await store.checkForUpdate(image)
            guard status != .current else {
                print(CLISupport.imageUpdateMessage(image, status: status))
                return
            }
            let assumeYes = yes
            let line = ProgressLine()
            defer { line.finish() }
            _ = try await store.ensureImage(
                image, refresh: status == .updateAvailable,
                confirm: { image in assumeYes || Terminal.confirm(CLISupport.downloadQuestion(image)) },
                progress: { progress in line.show(progress) })
            line.finish()
            print(CLISupport.imageUpdateMessage(image, status: status, build: await store.acceptedBuild(image)))
        }
    }

    struct Reset: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "reset",
            abstract: L10n.string("Forget the build and signature already accepted for an image."),
            discussion: L10n.string("Nido refuses a checksum list older than the last one it accepted (it may be an old copy served again). If the refusal persists when you try again later, reset makes Nido accept the next list as if for the first time. It downloads nothing and leaves the image in the cache alone."))

        @Argument(help: ArgumentHelp(L10n.string("Image ID.")))
        var id: String

        @Flag(help: ArgumentHelp(L10n.string("Confirm without asking.")))
        var yes = false

        func run() async throws {
            let image = try CLISupport.catalogImage(id: id)
            guard yes || Terminal.confirm(L10n.string(
                "Forget the accepted build and signature of \(image.id)? The next check can’t recognize an old list served again. [y/N] "))
            else {
                Terminal.error(L10n.string("Reset canceled."))
                throw ExitCode.failure
            }
            let removed = try await ImageCommand.makeStore().forgetAccepted(image)
            print(CLISupport.imageResetMessage(image, removed: removed.count))
        }
    }
}
