// SPDX-License-Identifier: Apache-2.0
import Foundation

/// An Ollama model in the guest.
public struct OllamaModel: Equatable, Hashable, Sendable {
    public let name: String
    public let sizeBytes: Int64

    public init(name: String, sizeBytes: Int64) {
        self.name = name
        self.sizeBytes = sizeBytes
    }
}

/// One step of `/var/lib/nido-provision/state.json`, read leniently.
public struct ProvisionStep: Equatable, Sendable {
    public enum State: String, Sendable { case pending, running, done, failed, unknown }

    public let name: String
    public let state: State
    public let message: String
    public let updated: String?
    public let model: String?
    public let completedBytes: Int64?
    public let totalBytes: Int64?
    public let warning: String?

    public init(
        name: String, state: State, message: String, updated: String? = nil, model: String? = nil,
        completedBytes: Int64? = nil, totalBytes: Int64? = nil, warning: String? = nil
    ) {
        self.name = name
        self.state = state
        self.message = message
        self.updated = updated
        self.model = model
        self.completedBytes = completedBytes
        self.totalBytes = totalBytes
        self.warning = warning
    }

    /// The `steps` object of `state.json` (also embedded by the Guest Tools in the monitor's
    /// `provisioning` field), leniently: entries that are not objects are skipped, an unknown
    /// state is `.unknown`, numbers may be numeric strings.
    static func parseSteps(_ value: Any?) -> [String: ProvisionStep] {
        var steps: [String: ProvisionStep] = [:]
        for (name, value) in value as? [String: Any] ?? [:] {
            guard let entry = value as? [String: Any] else { continue }
            let progress = entry["progress"] as? [String: Any]
            steps[name] = ProvisionStep(
                name: name,
                state: (entry["state"] as? String).flatMap(State.init(rawValue:)) ?? .unknown,
                message: entry["message"] as? String ?? "",
                updated: entry["updated"] as? String,
                model: entry["model"] as? String,
                completedBytes: int64(progress?["completed"]),
                totalBytes: int64(progress?["total"]),
                warning: entry["warning"] as? String)
        }
        return steps
    }

    /// A JSON number or a numeric string (a future or sloppy guest).
    static func int64(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber, !(value is Bool) { return number.int64Value }
        if let text = value as? String { return Int64(text) }
        return nil
    }
}

public struct AIRuntimeStatus: Equatable, Sendable {
    public let installed: Bool
    public let version: String?
    public let running: Bool
    public let models: [OllamaModel]
    /// The Ollama version this Guest Tools release installs (`ollama/release.json`).
    public let pinnedVersion: String?
    /// The provisioning steps by name (`ollama-install`, `model-pull`, …): a `failed` one is
    /// what "Riprova" runs again.
    public let steps: [String: ProvisionStep]

    public init(
        installed: Bool, version: String?, running: Bool, models: [OllamaModel], pinnedVersion: String?,
        steps: [String: ProvisionStep]
    ) {
        self.installed = installed
        self.version = version
        self.running = running
        self.models = models
        self.pinnedVersion = pinnedVersion
        self.steps = steps
    }
}

public struct PullProgress: Equatable, Sendable {
    public let completedBytes: Int64
    public let totalBytes: Int64
    public let message: String
    public let warning: String?

    public init(completedBytes: Int64, totalBytes: Int64, message: String, warning: String?) {
        self.completedBytes = completedBytes
        self.totalBytes = totalBytes
        self.message = message
        self.warning = warning
    }
}

/// The metrics Ollama reports on the last line of a chat answer (`total_duration`, `eval_count`,
/// `eval_duration`, durations in nanoseconds). Each is nil when missing or not a sensible number.
public struct ChatStats: Equatable, Sendable {
    /// From the request to the end of the answer, model loading included.
    public let totalDuration: Duration?
    /// Tokens generated, and the time spent generating them.
    public let evalCount: Int?
    public let evalDuration: Duration?

    public init(totalDuration: Duration?, evalCount: Int?, evalDuration: Duration?) {
        self.totalDuration = totalDuration
        self.evalCount = evalCount
        self.evalDuration = evalDuration
    }

    /// Generation speed, when both the token count and a positive duration are known.
    public var tokensPerSecond: Double? {
        guard let evalCount, let evalDuration, evalDuration > .zero else { return nil }
        return Double(evalCount) / (Double(evalDuration.components.seconds)
            + Double(evalDuration.components.attoseconds) / 1e18)
    }

    static func parse(_ object: [String: Any]) -> ChatStats {
        ChatStats(
            totalDuration: nanoseconds(object["total_duration"]),
            evalCount: count(object["eval_count"]),
            evalDuration: nanoseconds(object["eval_duration"]))
    }

    private static func count(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double >= 0, double <= Double(Int32.max) else { return nil }
        return Int(double)
    }

    private static func nanoseconds(_ value: Any?) -> Duration? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        // Positive and under a day: anything else is not a duration of one answer.
        guard double.isFinite, double > 0, double < 86_400e9 else { return nil }
        return .nanoseconds(Int64(double))
    }
}

/// What a chat stream yields: the answer's pieces as they arrive, then, once, Ollama's metrics.
public enum ChatEvent: Equatable, Sendable {
    case piece(String)
    case finished(ChatStats)
}

public struct ChatMessage: Codable, Equatable, Sendable {
    public enum Role: String, Codable, Sendable { case system, user, assistant }
    public let role: Role
    public let content: String

    public init(role: Role, content: String) {
        self.role = role
        self.content = content
    }
}

public enum AIRuntimeError: Error, Equatable, Sendable {
    /// `nido-provision <step>` failed; the message is the guest's explanation as it arrived
    /// (`<code>: <English message>`, or older Guest Tools' Italian), shown through `GuestMessage`.
    case stepFailed(step: String, message: String)
    /// Another provisioning step is running in the guest.
    case busy
    /// The guest's Guest Tools predate `nido-provision`: update them first.
    case guestToolsOutdated
    /// Ollama does not answer on the guest's loopback.
    case notRunning
    /// Ollama answered with an error.
    case ollama(String)
    case invalidResponse
}

extension AIRuntimeError: LocalizedError {
    public var errorDescription: String? {
        localizedDescription(language: L10n.language)
    }

    /// The description in `language` (tests check languages other than the pinned one with it).
    func localizedDescription(language: String) -> String {
        switch self {
        case .stepFailed(let step, let message):
            Self.stepFailure(step, message: GuestMessage.text(message, language: language), language: language)
        case .busy:
            L10n.string("another Ollama operation is already running in the VM: try again in a moment", language: language)
        case .guestToolsOutdated:
            L10n.string("the VM’s Guest Tools are out of date: update them to use Ollama", language: language)
        case .notRunning:
            L10n.string("Ollama isn’t running in the VM: start it with Start in the Local panel.", language: language)
        case .ollama(let message):
            L10n.string("Ollama returned an error: \(GuestSSH.sanitize(message, limit: 200))", language: language)
        case .invalidResponse:
            L10n.string("the VM sent an invalid response", language: language)
        }
    }

    /// "Couldn’t install Ollama: <message>", one whole sentence per step; `message` is the guest's,
    /// already in `language` (`GuestMessage.text`).
    static func stepFailure(_ step: String, message: String, language: String) -> String {
        switch step {
        case "ollama-install": L10n.string("couldn’t install Ollama: \(message)", language: language)
        case "ollama-verify": L10n.string("couldn’t verify Ollama: \(message)", language: language)
        case "ollama-start": L10n.string("couldn’t start Ollama: \(message)", language: language)
        case "ollama-stop": L10n.string("couldn’t stop Ollama: \(message)", language: language)
        case "ollama-restart": L10n.string("couldn’t restart Ollama: \(message)", language: language)
        case "ollama-update": L10n.string("couldn’t update Ollama: \(message)", language: language)
        case "ollama-uninstall": L10n.string("couldn’t uninstall Ollama: \(message)", language: language)
        case "model-pull": L10n.string("couldn’t download the model: \(message)", language: language)
        case "model-remove": L10n.string("couldn’t remove the model: \(message)", language: language)
        default: L10n.string("the operation failed: \(message)", language: language)
        }
    }
}

/// Ollama in a running Debian guest, driven over the background SSH with fixed commands only:
/// `sudo -n /opt/nido-guest-tools/bin/nido-provision <step>` for every change (phase 2 of the
/// provisioning) and a fixed `curl` to the guest's own `127.0.0.1:11434` for the chat. "Riprova"
/// is the same call again: every step resumes where it was interrupted.
///
/// Cancelling the calling task stops only the host side (the ssh process): the step keeps
/// running in the guest (`nido-provision` ignores the closed session) until it ends. The UI
/// follows it with `status()` (or the monitor's `provisioning` field) instead of assuming it
/// stopped.
public struct AIRuntime: Sendable {
    /// Light models for small VMs, as suggestions, not guarantees. Names and sizes verified on
    /// registry.ollama.ai on 2026-10-24.
    public static let suggestedModels: [OllamaModel] = [
        OllamaModel(name: "qwen3:0.6b", sizeBytes: 522_653_277),
        OllamaModel(name: "gemma3:1b", sizeBytes: 806_067_267),
        OllamaModel(name: "llama3.2:1b", sizeBytes: 1_321_097_844),
    ]

    /// Where the Ollama archive comes from: a verified file on the Mac for `release`, its
    /// download (when one is needed) reported to the second argument.
    public typealias ArchiveProvider =
        @Sendable (OllamaRelease, @escaping @Sendable (DownloadProgress) -> Void) async throws -> URL

    private let ssh: GuestSSH
    private let release: OllamaRelease
    private let archive: ArchiveProvider
    private let quickTimeout: Duration
    private let installTimeout: Duration
    private let pullTimeout: Duration
    private let chatTimeout: Duration
    private let pollInterval: Duration

    public init(
        ssh: GuestSSH, quickTimeout: Duration = .seconds(90), installTimeout: Duration = .seconds(2 * 3600),
        pullTimeout: Duration = .seconds(6 * 3600), chatTimeout: Duration = .seconds(15 * 60),
        pollInterval: Duration = .seconds(2), release: OllamaRelease = .pinned,
        archive: @escaping ArchiveProvider = { try await OllamaArchiveStore.shared.ensureArchive($0, progress: $1) }
    ) {
        self.ssh = ssh
        self.release = release
        self.archive = archive
        self.quickTimeout = quickTimeout
        self.installTimeout = installTimeout
        self.pullTimeout = pullTimeout
        self.chatTimeout = chatTimeout
        self.pollInterval = pollInterval
    }

    /// For the VM `bundle` (its config gives the SSH key).
    public init(bundle: VMBundle, runner: ProcessRunner = SystemProcessRunner()) throws {
        self.init(ssh: GuestSSH(bundle: bundle, config: try bundle.readConfig(), runner: runner))
    }

    // MARK: - Status

    public func status() async throws -> AIRuntimeStatus {
        let output = try await ssh.run(.provisionStatus, timeout: quickTimeout)
        guard let status = Self.parseStatus(Data(output.stdout.utf8)) else { throw AIRuntimeError.invalidResponse }
        return status
    }

    /// The tail of the guest's provisioning log.
    public func log() async throws -> String {
        try await ssh.run(.readProvisionLog, timeout: quickTimeout).stdout
    }

    static func parseStatus(_ data: Data) -> AIRuntimeStatus? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let ollama = root["ollama"] as? [String: Any] ?? [:]
        let models = (root["models"] as? [Any] ?? []).compactMap { item -> OllamaModel? in
            guard let entry = item as? [String: Any], let name = entry["name"] as? String else { return nil }
            return OllamaModel(name: name, sizeBytes: int64(entry["size"]) ?? 0)
        }
        return AIRuntimeStatus(
            installed: ollama["installed"] as? Bool ?? false,
            version: ollama["version"] as? String,
            running: ollama["running"] as? Bool ?? false,
            models: models,
            pinnedVersion: ollama["pinned"] as? String,
            steps: ProvisionStep.parseSteps(root["steps"]))
    }

    private static func int64(_ value: Any?) -> Int64? { ProvisionStep.int64(value) }

    // MARK: - Ollama

    /// Installs the pinned Ollama (archive, checksum, service). The guest never downloads it:
    /// when the guest needs it, Nido downloads and verifies it on the Mac (`archive`, cached,
    /// reported to `progress`) and sends it over SSH; the guest checks it again. Long: cancelling
    /// stops waiting (and the Mac's download, see `OllamaArchiveStore`), not a guest step already
    /// running (see the type's notes); poll `status()`.
    public func install(progress: @escaping @Sendable (DownloadProgress) -> Void) async throws {
        try await installOrUpdate(update: false, progress: progress)
    }
    public func install() async throws { try await install(progress: { _ in }) }
    public func verify() async throws { try await perform(.verify, timeout: quickTimeout) }
    public func start() async throws { try await perform(.start, timeout: quickTimeout) }
    public func stop() async throws { try await perform(.stop, timeout: quickTimeout) }
    public func restart() async throws { try await perform(.restart, timeout: quickTimeout) }
    /// Brings Ollama to the pinned release, the archive coming from the Mac as for `install()`.
    public func update(progress: @escaping @Sendable (DownloadProgress) -> Void) async throws {
        try await installOrUpdate(update: true, progress: progress)
    }
    public func update() async throws { try await update(progress: { _ in }) }

    /// Asks the guest first: its Guest Tools must pin this build's release (else
    /// `.guestToolsOutdated`, nothing downloaded). Ollama already at that version needs no
    /// archive (the step only checks the service). Otherwise the guest's Guest Tools must take the
    /// archive on stdin (`archiveOnStdinSince` or later), checked before any download; then the
    /// archive is copied to the step's stdin from the file, chunk by chunk (about 1.5 GB: never in
    /// memory, never mapped). A usage error from older Guest
    /// Tools is also `.guestToolsOutdated`.
    private func installOrUpdate(
        update: Bool, progress: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws {
        let step = update ? "ollama-update" : "ollama-install"
        let current: AIRuntimeStatus
        do {
            current = try await status()
        } catch let error as GuestSSHError {
            throw Self.translate(error, step: step)
        }
        guard current.pinnedVersion == release.version else { throw AIRuntimeError.guestToolsOutdated }
        if current.installed, current.version == release.version {
            try await perform(update ? .update : .install, timeout: installTimeout)
            return
        }
        guard let tools = try await guestToolsVersion(step: step), Self.takesArchiveOnStdin(tools) else {
            throw AIRuntimeError.guestToolsOutdated
        }
        let file = try await archive(release, progress)
        let handle = try Self.openArchive(file, size: release.size)
        defer { try? handle.close() }
        let action: GuestCommand.OllamaAction = update ? .updateFromStdin : .installFromStdin
        do {
            _ = try await ssh.run(.ollama(action), stdinFile: handle, timeout: installTimeout)
        } catch {
            throw Self.translate(error, step: action.stepName)
        }
    }

    /// The first Guest Tools release whose `nido-provision` takes the Ollama archive on stdin
    /// (`--archive-stdin`). Later ones do too (1.5.0 only changed the messages): a VM with 1.4.0
    /// installs Ollama without reinstalling its Guest Tools.
    static let archiveOnStdinSince = "1.4.0"

    /// True for a Guest Tools release (`1.4.0`, `1.10.2`) at `archiveOnStdinSince` or later.
    static func takesArchiveOnStdin(_ version: String) -> Bool {
        func numbers(_ text: String) -> [Int]? {
            let parts = text.split(separator: ".", omittingEmptySubsequences: false).compactMap { Int($0) }
            return parts.count == 3 && parts.allSatisfy { $0 >= 0 } ? parts : nil
        }
        guard let version = numbers(version), let since = numbers(archiveOnStdinSince) else { return false }
        return !version.lexicographicallyPrecedes(since)
    }

    /// The Guest Tools release in the guest; nil when it has none (no `VERSION` file).
    private func guestToolsVersion(step: String) async throws -> String? {
        do {
            let output = try await ssh.run(.readGuestToolsVersion, timeout: quickTimeout)
            return output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch .commandFailed(_, let tail) where tail.contains("No such file") {
            return nil
        } catch {
            throw Self.translate(error, step: step)
        }
    }

    /// `file` opened for reading without following a link: a regular file of exactly `size`
    /// bytes, else `.downloadFailed` (nothing is sent).
    static func openArchive(_ file: URL, size: UInt64) throws -> FileHandle {
        let fd = Darwin.open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw NidoError.downloadFailed(L10n.string("unreadable Ollama archive: \(file.path)")) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, UInt64(info.st_size) == size else {
            throw NidoError.downloadFailed(L10n.string("incomplete Ollama archive: \(file.path)"))
        }
        return handle
    }

    /// Models stay unless `removeModels` (the app asks for confirmation first).
    public func uninstall(removeModels: Bool) async throws {
        try await perform(.uninstall(removeModels: removeModels), timeout: quickTimeout)
    }

    // MARK: - Models

    /// Downloads `model` (an official identifier). An existing model is not pulled again unless
    /// `force` (the app asks first). `progress` gets the guest's `state.json` progress while the
    /// pull runs. Cancelling stops waiting and polling only: the download continues in the guest
    /// and `status()` shows how it ends.
    public func pull(
        model: String, force: Bool = false, progress: @escaping @Sendable (PullProgress) -> Void
    ) async throws {
        let model = try GuestCommand.validateModelName(model)
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await perform(.pull(model: model, force: force), timeout: pullTimeout)
            }
            group.addTask {
                while true {
                    try await Task.sleep(for: pollInterval)
                    guard let status = try? await status(), let step = status.steps["model-pull"],
                        step.model == model, step.state == .running,
                        let total = step.totalBytes, total > 0
                    else { continue }
                    progress(PullProgress(
                        completedBytes: step.completedBytes ?? 0, totalBytes: total,
                        message: step.message, warning: step.warning))
                }
            }
            // The pull ends first (the poller only ends when cancelled).
            try await group.next()
            group.cancelAll()
        }
    }

    public func remove(model: String) async throws {
        let model = try GuestCommand.validateModelName(model)
        try await perform(.remove(model: model), timeout: quickTimeout)
    }

    private func perform(_ action: GuestCommand.OllamaAction, timeout: Duration) async throws {
        do {
            _ = try await ssh.run(.ollama(action), timeout: timeout)
        } catch {
            throw Self.translate(error, step: action.stepName)
        }
    }

    static func translate(_ error: GuestSSHError, step: String) -> Error {
        guard case .commandFailed(let code, let tail) = error else { return error }
        if tail.contains("nido-provision: command not found") || tail.contains("nido-provision: No such file") {
            return AIRuntimeError.guestToolsOutdated
        }
        if code == 3, tail.contains("nido-provision:") { return AIRuntimeError.busy }
        // A usage error: Guest Tools that predate this step's arguments (`--archive-stdin`). The
        // usage line is Italian before Guest Tools 1.5.0, English since.
        if code == 2, tail.contains("uso: nido-provision") || tail.contains("usage: nido-provision") {
            return AIRuntimeError.guestToolsOutdated
        }
        if let marker = tail.range(of: "nido-provision: ", options: .backwards) {
            let message = tail[marker.upperBound...].trimmingCharacters(in: .whitespaces)
            if !message.isEmpty { return AIRuntimeError.stepFailed(step: step, message: message) }
        }
        return error
    }

    // MARK: - Chat

    private struct ChatRequest: Encodable {
        let model: String
        let messages: [ChatMessage]
        let stream: Bool
    }

    /// One chat turn with `model` in the guest: yields the answer's pieces as Ollama streams
    /// them, then its metrics when the answer is complete. Ending the iteration or cancelling the
    /// task stops the request.
    public func chat(model: String, messages: [ChatMessage]) -> AsyncThrowingStream<ChatEvent, Error> {
        let ssh = ssh
        let timeout = chatTimeout
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let model = try GuestCommand.validateModelName(model)
                    let body = try JSONEncoder().encode(ChatRequest(model: model, messages: messages, stream: true))
                    var buffer = Data()
                    var finished = false
                    for try await chunk in ssh.stream(.chat, stdin: body, timeout: timeout) {
                        buffer.append(chunk)
                        while !finished, let newline = buffer.firstIndex(of: 0x0A) {
                            let line = buffer[buffer.startIndex..<newline]
                            buffer = Data(buffer[buffer.index(after: newline)...])
                            finished = try Self.handleChatLine(line, continuation: continuation)
                        }
                        if finished { break }
                    }
                    if !finished, !buffer.isEmpty {
                        _ = try Self.handleChatLine(buffer, continuation: continuation)
                    }
                    continuation.finish()
                } catch let error as GuestSSHError {
                    if case .commandFailed(7, _) = error {
                        continuation.finish(throwing: AIRuntimeError.notRunning)
                    } else {
                        continuation.finish(throwing: error)
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Yields the content of one NDJSON line, and the metrics on the last; true when the answer
    /// is complete.
    private static func handleChatLine(
        _ line: Data, continuation: AsyncThrowingStream<ChatEvent, Error>.Continuation
    ) throws -> Bool {
        guard line.contains(where: { $0 != 0x20 && $0 != 0x0D && $0 != 0x09 }) else { return false }
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
            throw AIRuntimeError.invalidResponse
        }
        if let error = object["error"] as? String { throw AIRuntimeError.ollama(error) }
        if let message = object["message"] as? [String: Any], let content = message["content"] as? String,
            !content.isEmpty
        {
            continuation.yield(.piece(content))
        }
        guard object["done"] as? Bool == true else { return false }
        continuation.yield(.finished(ChatStats.parse(object)))
        return true
    }
}
