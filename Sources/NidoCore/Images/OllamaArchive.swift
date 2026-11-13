// SPDX-License-Identifier: Apache-2.0
import CryptoKit
import Darwin
import Foundation

/// The Ollama release the Guest Tools pin (`guest/linux/ollama/release.json`, shipped in
/// `GuestToolsPayload`). Nido downloads it on the Mac and sends it to the guest over SSH, so a
/// guest never needs GitHub in its egress allowlist.
public struct OllamaRelease: Sendable, Equatable {
    public let version: String
    /// The archive's file name (no `/`, no leading `.`).
    public let file: String
    /// Always `https://github.com/ollama/ollama/releases/download/…`.
    public let url: URL
    public let size: UInt64
    /// Lowercase hex SHA-256 of the archive.
    public let sha256: String

    /// Largest accepted archive.
    public static let maxSize: UInt64 = 16 << 30
    static let urlPrefix = "https://github.com/ollama/ollama/releases/download/"
    static let payloadPath = "/opt/nido-guest-tools/ollama/release.json"

    /// The release of this build's Guest Tools. Their `release.json` is a constant checked by
    /// the tests, so a failure here is a build error.
    public static let pinned: OllamaRelease = {
        guard let entry = GuestToolsPayload.files.first(where: { $0.path == payloadPath }),
            let data = Data(base64Encoded: entry.base64)
        else { preconditionFailure("GuestToolsPayload has no \(payloadPath)") }
        do {
            return try parse(data)
        } catch {
            preconditionFailure("GuestToolsPayload: invalid \(payloadPath): \(error)")
        }
    }()

    /// Reads a `release.json`. Refuses (`.downloadFailed`) anything but an HTTPS URL under the
    /// official GitHub releases of ollama/ollama (no credentials, default port), a plain file and
    /// version name, a size of 1 byte to `maxSize` and a 64-character lowercase hex SHA-256.
    public static func parse(_ data: Data) throws(NidoError) -> OllamaRelease {
        let refusal = NidoError.downloadFailed(L10n.string("invalid Ollama release.json"))
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let version = object["version"] as? String, let file = object["file"] as? String,
            let urlText = object["url"] as? String, let size = object["size"] as? NSNumber,
            CFGetTypeID(size) != CFBooleanGetTypeID(), let sha256 = object["sha256"] as? String
        else { throw refusal }
        guard isPlainName(version), isPlainName(file),
            size.int64Value > 0, UInt64(size.int64Value) <= maxSize, size.doubleValue == Double(size.int64Value),
            sha256.utf8.count == 64,
            sha256.utf8.allSatisfy({ (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }),
            urlText.hasPrefix(urlPrefix), let url = URL(string: urlText),
            url.scheme == "https", url.host == "github.com", url.user == nil, url.password == nil,
            url.port == nil
        else { throw refusal }
        return OllamaRelease(version: version, file: file, url: url, size: UInt64(size.int64Value), sha256: sha256)
    }

    /// Letters, digits, `.`, `_`, `-`; not empty, no leading `.`, at most 128 bytes.
    private static func isPlainName(_ name: String) -> Bool {
        guard !name.isEmpty, name.utf8.count <= 128, name.first != "." else { return false }
        return name.utf8.allSatisfy {
            (0x30...0x39).contains($0) || (0x41...0x5A).contains($0) || (0x61...0x7A).contains($0)
                || $0 == UInt8(ascii: ".") || $0 == UInt8(ascii: "_") || $0 == UInt8(ascii: "-")
        }
    }
}

/// Cache of verified Ollama archives on the Mac (`~/Library/Caches/Nido/ollama`), following the
/// image cache's conventions (`ImageStore`): the download streams into a private `.part` file
/// inside the cache (0700 directory, 0600 file, `O_EXCL | O_NOFOLLOW`), hashed while written and
/// capped at the pinned size, and is published under its final name by `rename(2)` only after
/// its size and SHA-256 match the release.
///
/// - Hosts: the first URL is the pinned GitHub one; its redirects may only go to HTTPS
///   `github.com` or `*.githubusercontent.com` (`validateRedirect`). The pinned SHA-256 stays the
///   integrity anchor.
/// - Joining: a call for an archive whose download is already running joins it (one request);
///   its `progress` gets the updates too. Cancelling one caller throws `CancellationError` for it;
///   the download stops (and its part is removed) only when no caller is left.
/// - Leftovers: every call first removes the `.part` files an interrupted run left behind
///   (`sweepStaleParts`).
///
/// No confirmation is asked: it is the download the user already chose with "Installa Ollama".
public actor OllamaArchiveStore {
    private let cacheRoot: URL
    private let session: URLSession

    /// A part not written for this long belongs to no running download (the session gives up
    /// after 60 s without data): `sweepStaleParts` removes it.
    public static let stalePartAge: TimeInterval = 60 * 60

    /// Downloads in progress, keyed by the archive's final path.
    private var inFlight: [String: Flight] = [:]
    /// Parts this store is writing now: never swept.
    private var activeParts: Set<String> = []

    private struct Flight {
        let token: UUID
        let task: Task<URL, any Error>
        let broadcaster: ProgressBroadcaster
        var waiters: [UUID: CheckedContinuation<URL, any Error>] = [:]
    }

    public init(cacheRoot: URL = OllamaArchiveStore.defaultCacheRoot(), session: URLSession = ImageStore.makeDownloadSession()) {
        self.cacheRoot = cacheRoot
        self.session = session
    }

    /// `~/Library/Caches/Nido/ollama`.
    public static func defaultCacheRoot() -> URL {
        ImageStore.defaultCacheRoot().deletingLastPathComponent()
            .appendingPathComponent("ollama", isDirectory: true)
    }

    /// The archive provider `AIRuntime` uses by default.
    public static let shared = OllamaArchiveStore()

    /// A redirect target of the archive's download: HTTPS on `github.com` or a host under
    /// `githubusercontent.com` (GitHub's release assets), no credentials, default port. Anything
    /// else is `.hostNotAllowed`.
    public static func validateRedirect(_ url: URL) throws(NidoError) {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased(), url.user == nil,
            url.password == nil, url.port == nil || url.port == 443,
            host == "github.com" || (host.hasSuffix(".githubusercontent.com") && !host.hasPrefix("."))
        else { throw .hostNotAllowed(url.absoluteString) }
    }

    /// A verified copy of `release`'s archive: the cached one when it is a regular file of the
    /// right size and SHA-256 (hashed again on every call), otherwise downloaded now (or the
    /// download already running joined). `progress` is called at most every 256 KiB, possibly
    /// from a background thread. Cancelling the calling task throws `CancellationError`; the
    /// download is cancelled, and its `.part` file removed, when no other caller waits for it.
    public func ensureArchive(
        _ release: OllamaRelease, progress: @escaping @Sendable (DownloadProgress) -> Void = { _ in }
    ) async throws -> URL {
        sweepStaleParts()
        let finalURL = finalURL(release)
        let key = finalURL.path
        if inFlight[key] == nil {
            try Task.checkCancellation()
            if try await Self.isValid(finalURL, release: release) { return finalURL }
            // Back on the actor after the hash: another caller may have started the download.
            if inFlight[key] == nil {
                try Task.checkCancellation()
                try Self.validateRedirect(release.url)
                start(release, finalURL: finalURL, key: key)
            }
        }
        return try await join(key: key, progress: progress)
    }

    /// Number of callers waiting for the download of `release` (test seam).
    func waiterCount(_ release: OllamaRelease) -> Int {
        inFlight[finalURL(release).path]?.waiters.count ?? 0
    }

    private func finalURL(_ release: OllamaRelease) -> URL {
        cacheRoot.appendingPathComponent("\(release.version)-\(release.file)", isDirectory: false)
    }

    // MARK: - Shared download

    private func start(_ release: OllamaRelease, finalURL: URL, key: String) {
        let token = UUID()
        let broadcaster = ProgressBroadcaster()
        let task = Task { [self] () throws -> URL in
            let result: Result<URL, any Error>
            do {
                result = .success(try await download(release, finalURL: finalURL, progress: broadcaster.send))
            } catch {
                result = .failure(error)
            }
            finish(key: key, token: token, result: result)
            return try result.get()
        }
        inFlight[key] = Flight(token: token, task: task, broadcaster: broadcaster)
    }

    private func join(key: String, progress: @escaping @Sendable (DownloadProgress) -> Void) async throws -> URL {
        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // Runs synchronously on the actor: a cancellation after this finds the waiter.
                guard !Task.isCancelled, var flight = inFlight[key] else {
                    if let orphan = inFlight[key], orphan.waiters.isEmpty {
                        inFlight[key] = nil
                        orphan.task.cancel()
                    }
                    continuation.resume(throwing: CancellationError())
                    return
                }
                flight.broadcaster.add(waiterID, progress)
                flight.waiters[waiterID] = continuation
                inFlight[key] = flight
            }
        } onCancel: {
            Task { await self.cancelWaiter(key: key, waiterID: waiterID) }
        }
    }

    private func cancelWaiter(key: String, waiterID: UUID) {
        guard var flight = inFlight[key], let waiter = flight.waiters.removeValue(forKey: waiterID) else { return }
        flight.broadcaster.remove(waiterID)
        guard flight.waiters.isEmpty else {
            inFlight[key] = flight
            waiter.resume(throwing: CancellationError())
            return
        }
        // Last caller: stop the download and answer once its part is gone.
        inFlight[key] = nil
        flight.task.cancel()
        let task = flight.task
        Task {
            _ = await task.result
            waiter.resume(throwing: CancellationError())
        }
    }

    private func finish(key: String, token: UUID, result: Result<URL, any Error>) {
        guard let flight = inFlight[key], flight.token == token else { return }
        inFlight[key] = nil
        for waiter in flight.waiters.values { waiter.resume(with: result) }
    }

    /// The download proper: a private part, streamed and hashed, checked, then published.
    private func download(
        _ release: OllamaRelease, finalURL: URL, progress: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> URL {
        try PrivateDirectory.ensure(cacheRoot)
        let partName = ".\(release.version)-\(release.file).\(UUID().uuidString).part"
        let partURL = cacheRoot.appendingPathComponent(partName, isDirectory: false)
        activeParts.insert(partName)
        defer { activeParts.remove(partName) }
        let fd = Darwin.open(partURL.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var fdOpen = true
        defer {
            if fdOpen { _ = Darwin.close(fd) }
            try? FileManager.default.removeItem(at: partURL)
        }
        guard fchmod(fd, 0o600) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

        let transfer = StreamingTransfer(
            url: release.url, policy: Self.validateRedirect, sink: .file(fd), digest: .sha256,
            limit: release.size,
            overLimit: .downloadFailed(L10n.string("Ollama archive larger than \(ByteSize.format(release.size))")),
            progress: progress)
        let outcome = try await transfer.run(session: session)
        guard fsync(fd) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        fdOpen = false  // close exactly once, whatever its result
        guard Darwin.close(fd) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard outcome.received == release.size else {
            let (received, size) = (String(outcome.received), String(release.size))
            throw NidoError.downloadFailed(L10n.string("incomplete Ollama archive (\(received) of \(size) bytes)"))
        }
        guard outcome.digest == release.sha256 else {
            throw NidoError.checksumMismatch(expected: release.sha256, actual: outcome.digest)
        }
        try Task.checkCancellation()
        guard Darwin.rename(partURL.path, finalURL.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return finalURL
    }

    // MARK: - Cache

    /// Removes the parts an interrupted download left in the cache: entries named like this
    /// store's parts (`.<version>-<file>.<UUID>.part`) that `lstat` shows as regular files (never
    /// a link, which is left alone) not modified for `stalePartAge`, and not written by this
    /// store now. A part of another process still downloading is younger, so it stays. Best
    /// effort: a cache that cannot be listed is left as it is.
    private func sweepStaleParts() {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: cacheRoot.path) else { return }
        let now = Date()
        for name in names where Self.isPartName(name) && !activeParts.contains(name) {
            let path = cacheRoot.appendingPathComponent(name, isDirectory: false).path
            var info = stat()
            guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { continue }
            let modified = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
            guard now.timeIntervalSince(modified) >= Self.stalePartAge else { continue }
            _ = Darwin.unlink(path)
        }
    }

    /// `.<anything>.<UUID>.part`, the name `download` gives its parts.
    static func isPartName(_ name: String) -> Bool {
        guard name.hasPrefix("."), name.hasSuffix(".part") else { return false }
        let stem = name.dropLast(5)
        guard let dot = stem.lastIndex(of: "."), stem.index(after: dot) < stem.endIndex else { return false }
        return UUID(uuidString: String(stem[stem.index(after: dot)...])) != nil && dot > stem.startIndex
    }

    /// A regular file (not a link) of `release.size` bytes whose SHA-256 is the pinned one.
    /// Runs off the actor: hashing reads the whole archive.
    @concurrent
    private static func isValid(_ url: URL, release: OllamaRelease) async throws -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
            UInt64(info.st_size) == release.size,
            let handle = try? FileHandle(forReadingFrom: url)
        else { return false }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined() == release.sha256
    }
}
