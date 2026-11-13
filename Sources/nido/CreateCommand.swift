// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import Dispatch
import Foundation
import NidoCLI
import NidoCore
import Synchronization

struct CreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: L10n.string("Create a Linux VM from a cloud image, or a macOS VM from a restore image (IPSW)."),
        discussion: L10n.string("macOS: nido create <name> --ipsw <file> --ssh-key <key.pub> --user <name>. Installation takes 4 to 20 minutes, depending on the Mac and the disk; Ctrl-C cancels it and leaves nothing behind. Nido only reads the IPSW: it never downloads, changes or moves it.")
    )

    @Argument(help: ArgumentHelp(L10n.string("VM name.")))
    var name: String

    @Option(help: ArgumentHelp(L10n.string("Catalog image to download and verify: debian-13, ubuntu-26.04 or ubuntu-24.04.")))
    var image: String?

    @Option(name: .customLong("image-file"), help: ArgumentHelp(L10n.string("Local disk image, raw or qcow2 (not verified).")))
    var imageFile: String?

    @Option(help: ArgumentHelp(L10n.string("A macOS restore image (.ipsw) you already downloaded: creates a macOS VM.")))
    var ipsw: String?

    @Option(help: ArgumentHelp(L10n.string("With --ipsw: the short name of the account you’ll create in macOS Setup Assistant (used by nido ssh).")))
    var user: String?

    @Option(name: .customLong("from-template"), help: ArgumentHelp(L10n.string("Create the VM from a template (nido template save): an instant copy with a new identity; CPU, memory and disk come from the template.")))
    var fromTemplate: String?

    @Option(name: .customLong("ssh-key"), help: ArgumentHelp(L10n.string("SSH public key (.pub) authorized in the guest. Optional with --from-template: the template’s key by default.")))
    var sshKey: String?

    @Option(help: ArgumentHelp(L10n.string("Number of virtual CPUs (default: 2 for Linux, 4 for macOS).")))
    var cpus: Int?

    @Option(help: ArgumentHelp(L10n.string("Memory (e.g. 4G, 512M). Default: 2G on Macs with 16 GB of RAM or less, 4G otherwise.")))
    var memory: String?

    @Option(help: ArgumentHelp(L10n.string("Disk size (e.g. 20G). Default: 20G for Linux, 64G for macOS.")))
    var disk: String?

    @Flag(name: .customLong("no-packages"), help: ArgumentHelp(L10n.string("Don’t install the essential packages at first boot.")))
    var noPackages = false

    @Flag(name: .customLong("no-guest-tools"), help: ArgumentHelp(L10n.string("Don’t install Nido’s Guest Tools at first boot.")))
    var noGuestTools = false

    @Flag(help: ArgumentHelp(L10n.string("Confirm the download without asking.")))
    var yes = false

    func run() async throws {
        if let ipsw {
            guard fromTemplate == nil else { throw CLIError.ipswConflict }
            try await createMac(ipsw: ipsw)
            return
        }
        if let fromTemplate {
            guard image == nil, imageFile == nil, cpus == nil, memory == nil, disk == nil,
                !noPackages, !noGuestTools, user == nil
            else { throw CLIError.fromTemplateConflict }
            print(try await CLISupport.createFromTemplate(
                template: fromTemplate, target: name, sshKey: sshKey, paths: try CLISupport.preparedPaths()))
            return
        }
        let options = try CLISupport.parseCreateOptions(
            name: name, image: image, imageFile: imageFile, sshKey: sshKey,
            cpus: cpus ?? 2, memory: memory, disk: disk ?? "20G",
            noPackages: noPackages, noGuestTools: noGuestTools, user: user)
        let publicKey = try VMControl.readPublicKey(at: options.sshKeyPath)
        try ResourceLimits.validate(cpuCount: options.cpuCount, memoryBytes: options.memoryBytes)
        let paths = try CLISupport.preparedPaths()
        // Fail before any download if the name is taken.
        if (try? VMBundle.open(options.name, paths: paths)) != nil {
            throw NidoError.alreadyExists(options.name.rawValue)
        }

        let baseImage: URL
        var distribution = LinuxDistribution.debian13
        switch options.image {
        case .catalog(let catalogImage):
            let assumeYes = yes
            let store = ImageStore(
                cacheRoot: ImageStore.defaultCacheRoot(), session: ImageStore.makeDownloadSession())
            distribution = catalogImage.distribution
            let line = ProgressLine()
            // Ended on success, error and cancel alike: "Error: …" never joins the progress.
            defer { line.finish() }
            baseImage = try await store.ensureImage(
                catalogImage,
                confirm: { image in assumeYes || Terminal.confirm(CLISupport.downloadQuestion(image)) },
                progress: { progress in line.show(progress) })
        case .file(let url):
            Terminal.error(L10n.string("Warning: local image not verified"))
            baseImage = url
        }

        let request = LinuxVMRequest(
            name: options.name, baseImage: baseImage, cpuCount: options.cpuCount,
            memoryBytes: options.memoryBytes, diskBytes: options.diskBytes, publicKey: publicKey,
            profile: options.profile, sshPublicKeyPath: options.sshKeyPath.path, distribution: distribution)
        _ = try VMFactory(paths: paths, runner: SystemProcessRunner()).createLinux(request)
        print(L10n.string("VM \(options.name.rawValue) created."))
    }

    /// `--ipsw`: installs macOS with a progress line. SIGINT, SIGTERM and SIGHUP cancel the
    /// installation; the installer removes everything it created before this returns.
    private func createMac(ipsw: String) async throws {
        let options = try CLISupport.parseMacCreateOptions(
            name: name, ipsw: ipsw, image: image, imageFile: imageFile, sshKey: sshKey, user: user,
            cpus: cpus, memory: memory, disk: disk, noPackages: noPackages, noGuestTools: noGuestTools)
        let paths = try CLISupport.preparedPaths()
        let installer = MacInstaller(paths: paths)
        // The signals are handled before the installation task exists: a Ctrl-C that comes while
        // it is being created is kept and cancels it as soon as it does (the default action would
        // kill the process before the installer cleans up).
        let cancellation = InstallCancellation()
        var sources: [any DispatchSourceSignal] = []
        for signalNumber in [SIGINT, SIGTERM, SIGHUP] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .global())
            source.setEventHandler {
                guard cancellation.request() else { return }
                Terminal.error("\n" + L10n.string("Canceling the installation…"))
            }
            source.resume()
            sources.append(source)
        }
        defer { sources.forEach { $0.cancel() } }
        let task = Task {
            try await CLISupport.createMac(options, paths: paths, installer: installer, line: ProgressLine())
        }
        cancellation.attach(task)
        print(try await task.value)
    }
}

/// A cancellation of `nido create --ipsw` asked by a signal, possibly before the installation task
/// exists: the task attached later is cancelled at once.
private final class InstallCancellation: Sendable {
    private let state = Mutex<(task: Task<String, any Error>?, requested: Bool)>((nil, false))

    /// Records the request and cancels the task if there is one; false when already requested.
    func request() -> Bool {
        let (first, task) = state.withLock { state in
            defer { state.requested = true }
            return (!state.requested, state.task)
        }
        if first { task?.cancel() }
        return first
    }

    func attach(_ task: Task<String, any Error>) {
        let requested = state.withLock { state in
            state.task = task
            return state.requested
        }
        if requested { task.cancel() }
    }
}
