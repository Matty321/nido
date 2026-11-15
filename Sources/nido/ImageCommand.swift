// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import Foundation
import NidoCLI
import NidoCore
import Synchronization

struct ImageCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "image",
        abstract: L10n.string("Manage the cloud images in the cache (list them, get new builds) and see or download the macOS image Apple offers."),
        discussion: L10n.string("A new VM starts from the image in the cache. Debian and Ubuntu publish new builds (security fixes): check compares the cache with the published checksum list, update downloads the current build. Existing VMs don’t change. macOS (for nido create --ipsw) is different: Nido downloads it from Apple only when you ask, with image macos --download."),
        subcommands: [List.self, Check.self, Update.self, Macos.self, Reset.self]
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

    struct Macos: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "macos",
            abstract: L10n.string("Show the macOS image Apple offers this Mac, or download it."),
            discussion: L10n.string("Asking goes online (one request to Apple); nothing is downloaded without --download. The download resumes if interrupted (run the same command again) and is kept only if macOS accepts it as the build Apple announced. Use the file with nido create <name> --ipsw <path>."))

        @Flag(help: ArgumentHelp(L10n.string("Download the image from Apple (asks first).")))
        var download = false

        @Option(help: ArgumentHelp(L10n.string("Where to save the image (a new file; with --download)."), valueName: "path"))
        var output: String?

        @Flag(help: ArgumentHelp(L10n.string("Confirm the download without asking.")))
        var yes = false

        func validate() throws {
            try CLISupport.validateMacImageOptions(download: download, hasOutput: output != nil, yes: yes)
        }

        func run() async throws {
            let downloader = MacImageDownloader()
            // --output is checked before anything goes online.
            let chosen = try output.map { try downloader.outputDestination(URL(fileURLWithPath: $0)) }
            let offer = try await LiveMacImageCatalog().latestSupported()
            // The size is part of the same ask (one HEAD request to Apple); unknown if it fails.
            let size = try? await downloader.remoteSize(of: offer)
            let destination = try chosen ?? downloader.destination(for: offer, output: nil)
            let partial = downloader.partialBytes(for: destination)
            guard download else {
                print(CLISupport.macImageOfferLine(offer, size: size))
                let complete = FileManager.default.fileExists(atPath: destination.path)
                if let state = CLISupport.macImageStateLine(path: destination.path, complete: complete, partial: partial) {
                    print(state)
                } else {
                    print(CLISupport.macImageDownloadHint())
                }
                for file in downloader.otherCachedFiles(besides: destination) {
                    print(CLISupport.macImageOtherFileLine(path: file.path, bytes: file.bytes))
                }
                return
            }
            // An image for a newer macOS than this Mac's, or over the size cap, is refused before
            // anything is downloaded and then deleted.
            try MacImageDownloader.checkOffer(offer, size: size)
            guard yes || Terminal.confirm(CLISupport.macImageDownloadQuestion(offer, size: size)) else {
                Terminal.error(L10n.string("download canceled"))
                throw ExitCode.failure
            }
            let line = ProgressLine()
            defer { line.finish() }
            // Ctrl-C (and SIGTERM, SIGHUP) cancel the download: the partial file stays and the
            // same command resumes it.
            let cancelled = Mutex(false)
            let task = Task { try await downloader.download(offer, to: destination) { line.show($0) } }
            var sources: [any DispatchSourceSignal] = []
            for signalNumber in [SIGINT, SIGTERM, SIGHUP] {
                signal(signalNumber, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .global())
                source.setEventHandler {
                    cancelled.withLock { $0 = true }
                    task.cancel()
                }
                source.resume()
                sources.append(source)
            }
            defer { sources.forEach { $0.cancel() } }
            do {
                let url = try await task.value
                line.finish()
                CLISupport.macImageDownloadedLines(path: url.path).forEach { print($0) }
            } catch {
                line.finish()
                if cancelled.withLock({ $0 }) {
                    Terminal.error(CLISupport.macImagePausedMessage())
                    throw ExitCode(130)
                }
                // Resumable only if a partial file is there, whatever the error was.
                if let lines = CLISupport.macImageFailureLines(
                    error: error, partial: downloader.partialBytes(for: destination))
                {
                    lines.forEach { Terminal.error($0) }
                    throw ExitCode.failure
                }
                throw error
            }
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
