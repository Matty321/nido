// SPDX-License-Identifier: Apache-2.0
import CryptoKit
import Foundation
import Synchronization

/// Local cache of verified cloud images.
///
/// Downloads happen only after explicit confirmation and only from allowlisted HTTPS URLs.
/// Checksum-list redirects must stay on the allowlist; the image may be redirected to any
/// HTTPS mirror (`DownloadPolicy.validateMirrorRedirect`). The image is streamed into a private
/// `.part` file inside the cache, hashed while written and capped at `CloudImage.maxBytes`;
/// it becomes visible under its final name only after its digest matches the list
/// (`SHA512SUMS` for Debian, `SHA256SUMS` for Ubuntu: `CloudImage.checksum`).
public actor ImageStore {
    private let cacheRoot: URL
    private let session: URLSession
    private let hashFile: @Sendable (URL, ChecksumAlgorithm) throws -> String
    private let readDigest: @Sendable (URL) throws -> String
    private let fileType: @Sendable (URL) throws -> FileAttributeType?

    /// Downloads in progress, keyed by `CloudImage.id`: later callers join the running download.
    private var inFlight: [String: Flight] = [:]
    /// Downloads published so far, keyed by `CloudImage.id` (see `ensureImage`).
    private var publications: [String: Int] = [:]

    private struct Waiter {
        let continuation: CheckedContinuation<URL, any Error>
    }

    private struct Flight {
        let token: UUID
        let task: Task<URL, any Error>
        let broadcaster: ProgressBroadcaster
        var waiters: [UUID: Waiter] = [:]
    }

    public init(cacheRoot: URL, session: URLSession) {
        self.init(cacheRoot: cacheRoot, session: session, hash: Checksums.digest(of:algorithm:))
    }

    /// Test seam: `hashFile` hashes every image, whatever its `CloudImage.checksum`.
    init(
        cacheRoot: URL, session: URLSession,
        hashFile: @escaping @Sendable (URL) throws -> String,
        readDigest: @escaping @Sendable (URL) throws -> String = { try String(contentsOf: $0, encoding: .utf8) },
        fileType: @escaping @Sendable (URL) throws -> FileAttributeType? = {
            try FileManager.default.attributesOfItem(atPath: $0.path)[.type] as? FileAttributeType
        }
    ) {
        self.init(
            cacheRoot: cacheRoot, session: session, hash: { url, _ in try hashFile(url) },
            readDigest: readDigest, fileType: fileType)
    }

    /// The three closures are the cache-validity reads (digest of the image, sidecar contents,
    /// file type); injectable to simulate I/O errors.
    private init(
        cacheRoot: URL, session: URLSession,
        hash hashFile: @escaping @Sendable (URL, ChecksumAlgorithm) throws -> String,
        readDigest: @escaping @Sendable (URL) throws -> String = { try String(contentsOf: $0, encoding: .utf8) },
        fileType: @escaping @Sendable (URL) throws -> FileAttributeType? = {
            try FileManager.default.attributesOfItem(atPath: $0.path)[.type] as? FileAttributeType
        }
    ) {
        self.cacheRoot = cacheRoot
        self.session = session
        self.hashFile = hashFile
        self.readDigest = readDigest
        self.fileType = fileType
    }

    /// Largest accepted checksum list body.
    public static let maxChecksumsBytes: UInt64 = 1 << 20

    /// Ephemeral session for image downloads: no cookies, credentials or HTTP cache on disk,
    /// and the checksum list is always fetched fresh. A stalled transfer fails after 60 s without
    /// data; a whole download fails after 6 hours.
    public static func makeDownloadSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 6 * 60 * 60
        return URLSession(configuration: config)
    }

    /// `~/Library/Caches/Nido/images`.
    public static func defaultCacheRoot() -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Caches", isDirectory: true)
        return base.appendingPathComponent("Nido", isDirectory: true)
            .appendingPathComponent("images", isDirectory: true)
    }

    /// Returns the local URL of a verified copy of `image`, downloading it if needed.
    ///
    /// - A valid cached copy is returned without network access and without calling `confirm`.
    /// - Otherwise `confirm` is called before any request; `false` throws `.downloadDeclined`.
    /// - A call for an image whose download is already running joins it: no second request,
    ///   no second `confirm`; its `progress` receives the updates too.
    /// - `progress` is called at most every 256 KiB and once at the end of the transfer,
    ///   possibly from a background thread.
    /// - A shared download proceeds on the first caller's `confirm`: a caller that joins it is
    ///   not asked again (the app's wizard and the CLI both ask before calling).
    /// - Cancelling the calling task makes this call throw `CancellationError`; the download
    ///   itself is cancelled (and its `.part` file removed) only when no caller is left waiting.
    ///   The last caller returns after that cleanup.
    /// - `refresh` skips the cache: the image is downloaded again (after `confirm`), and the new
    ///   build replaces the cached one only once verified (`checkForUpdate` says when it is worth it).
    public func ensureImage(
        _ image: CloudImage,
        refresh: Bool = false,
        confirm: @escaping @Sendable (CloudImage) async -> Bool,
        progress: @escaping @Sendable (DownloadProgress) -> Void = { _ in }
    ) async throws -> URL {
        try Self.validateFileName(image.fileName)
        // Checked again when a download published this image while the hash ran: the hash may
        // have read the old file against the new sidecar (a second download would be wasted).
        var checks = 0
        while inFlight[image.id] == nil {
            // A caller that is already gone must not start (or confirm) a download.
            try Task.checkCancellation()
            let finalURL = cacheRoot.appendingPathComponent(image.fileName, isDirectory: false)
            let digestURL = cacheRoot.appendingPathComponent(image.sidecarName, isDirectory: false)
            let published = publications[image.id, default: 0]
            checks += 1
            // Hashing a multi-GiB image takes seconds: it runs off the actor, which keeps
            // answering other callers meanwhile.
            if !refresh, try await Self.isValidCacheEntry(
                file: finalURL, digest: digestURL, algorithm: image.checksum,
                reads: CacheReads(hashFile: hashFile, readDigest: readDigest,
                                                                     fileType: fileType))
            {
                return finalURL
            }
            if !refresh, inFlight[image.id] == nil, publications[image.id, default: 0] != published, checks < 3 {
                continue
            }
            // Back on the actor after a suspension: the state may have changed. Another caller may
            // have started the download meanwhile (join it: one download, one confirmation), and
            // this caller may have been cancelled (it must not start or confirm one).
            if inFlight[image.id] == nil {
                try Task.checkCancellation()
                // Validate everything before asking or touching the network.
                try DownloadPolicy.validate(image.url)
                try DownloadPolicy.validate(image.checksumsURL)
                if let signature = image.signature { try DownloadPolicy.validate(signature.url) }
                startDownload(image, confirm: confirm)
            }
        }
        return try await join(imageID: image.id, progress: progress)
    }

    private func startDownload(_ image: CloudImage, confirm: @escaping @Sendable (CloudImage) async -> Bool) {
        let token = UUID()
        let broadcaster = ProgressBroadcaster()
        let task = Task { [self] () throws -> URL in
            let result: Result<URL, any Error>
            do {
                result = .success(try await download(image, confirm: confirm, broadcaster: broadcaster))
            } catch {
                result = .failure(error)
            }
            finish(imageID: image.id, token: token, result: result)
            return try result.get()
        }
        inFlight[image.id] = Flight(token: token, task: task, broadcaster: broadcaster)
    }

    /// Number of downloads currently tracked (test seam).
    var inFlightCount: Int { inFlight.count }

    /// Number of callers currently waiting for the download of `imageID` (test seam).
    func waiterCount(imageID: String) -> Int {
        inFlight[imageID]?.waiters.count ?? 0
    }

    /// Waits for the running download of `imageID` as one more caller.
    private func join(imageID: String, progress: @escaping @Sendable (DownloadProgress) -> Void) async throws -> URL {
        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // Runs synchronously on the actor: cancellation cannot slip in between the
                // check and the registration (a later one finds the waiter registered).
                guard !Task.isCancelled, var flight = inFlight[imageID] else {
                    // Cancelled before registering: if nobody else waits, stop the orphan download.
                    if let orphan = inFlight[imageID], orphan.waiters.isEmpty {
                        inFlight[imageID] = nil
                        orphan.task.cancel()
                    }
                    continuation.resume(throwing: CancellationError())
                    return
                }
                flight.broadcaster.add(waiterID, progress)
                flight.waiters[waiterID] = Waiter(continuation: continuation)
                inFlight[imageID] = flight
            }
        } onCancel: {
            Task { await self.cancelWaiter(imageID: imageID, waiterID: waiterID) }
        }
    }

    private func cancelWaiter(imageID: String, waiterID: UUID) {
        guard var flight = inFlight[imageID], let waiter = flight.waiters.removeValue(forKey: waiterID) else {
            return  // already finished
        }
        flight.broadcaster.remove(waiterID)
        guard flight.waiters.isEmpty else {
            inFlight[imageID] = flight
            waiter.continuation.resume(throwing: CancellationError())
            return
        }
        // Last caller: stop the download, and answer once its `.part` file is gone.
        // A new call from now on starts a fresh download.
        inFlight[imageID] = nil
        flight.task.cancel()
        let task = flight.task
        Task {
            _ = await task.result
            waiter.continuation.resume(throwing: CancellationError())
        }
    }

    /// Delivers the outcome to every caller still waiting and forgets the download.
    private func finish(imageID: String, token: UUID, result: Result<URL, any Error>) {
        guard let flight = inFlight[imageID], flight.token == token else { return }
        inFlight[imageID] = nil
        if case .success = result { publications[imageID, default: 0] += 1 }
        for waiter in flight.waiters.values { waiter.continuation.resume(with: result) }
    }

    /// The download proper: confirmation, checksum list, streamed image, verification, publication.
    private func download(
        _ image: CloudImage, confirm: @Sendable (CloudImage) async -> Bool,
        broadcaster: ProgressBroadcaster
    ) async throws -> URL {
        let finalURL = cacheRoot.appendingPathComponent(image.fileName, isDirectory: false)
        let digestURL = cacheRoot.appendingPathComponent(image.sidecarName, isDirectory: false)

        guard await confirm(image) else { throw NidoError.downloadDeclined }
        try Task.checkCancellation()

        try PrivateDirectory.ensure(cacheRoot)
        let fm = FileManager.default

        let sums = try await fetchSums(image)
        guard let expected = sums[image.fileName] else {
            throw NidoError.downloadFailed(L10n.string("no checksum for \(image.fileName)"))
        }

        // Stream straight into a private file inside the cache (never via $TMPDIR),
        // hashing while writing.
        let partURL = cacheRoot.appendingPathComponent(
            ".\(image.fileName).\(UUID().uuidString).part", isDirectory: false)
        let fd = Darwin.open(partURL.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var fdOpen = true
        defer {
            if fdOpen { _ = Darwin.close(fd) }
            try? fm.removeItem(at: partURL)
        }
        guard fchmod(fd, 0o600) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

        // Mirror redirects allowed: the digest is verified below.
        let actual = try await fetchImage(image, into: fd, progress: broadcaster.send)
        guard fsync(fd) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        fdOpen = false  // close exactly once, whatever its result
        guard Darwin.close(fd) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

        guard actual == expected else {
            throw NidoError.checksumMismatch(expected: expected, actual: actual)
        }
        try Task.checkCancellation()

        // Publication, both by rename(2) within the cache directory (atomic, replacing what was
        // there): the sidecar first, then the image. So an image present always has a sidecar,
        // and a validator in another process never sees a fresh image without one. A sidecar
        // left without its image (a failed rename) is just a cache miss.
        let sidecarPart = cacheRoot.appendingPathComponent(
            ".\(image.sidecarName).\(UUID().uuidString).part", isDirectory: false)
        defer { try? fm.removeItem(at: sidecarPart) }
        let sidecarFD = Darwin.open(sidecarPart.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard sidecarFD >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let line = Array((actual + "\n").utf8)
        let written = line.withUnsafeBytes { Darwin.write(sidecarFD, $0.baseAddress, $0.count) }
        let sidecarOK = written == line.count && fchmod(sidecarFD, 0o600) == 0 && fsync(sidecarFD) == 0
        let sidecarErrno = errno
        guard Darwin.close(sidecarFD) == 0, sidecarOK else {
            throw POSIXError(POSIXErrorCode(rawValue: sidecarErrno) ?? .EIO)
        }
        guard Darwin.rename(sidecarPart.path, digestURL.path) == 0 else {
            throw NidoError.downloadFailed(L10n.string("can’t write \(digestURL.path)"))
        }
        guard Darwin.rename(partURL.path, finalURL.path) == 0 else {
            let renameErrno = errno
            // The new digest next to the old image would make `checkForUpdate` say "current":
            // without it the entry is a plain miss, and the next call downloads again.
            unlink(digestURL.path)
            throw POSIXError(POSIXErrorCode(rawValue: renameErrno) ?? .EIO)
        }
        return finalURL
    }

    // MARK: - Updates

    /// Whether the catalog publishes another build of `image` than the cached one. Only on the
    /// user's request (`nido image check`, the wizard's "Cerca una nuova build"): one request for
    /// the checksum list (same rules as a download), the image itself is never fetched nor hashed.
    /// Compares the published digest with the cache sidecar; a cached image that later turns out
    /// corrupted is still caught by `ensureImage`.
    public func checkForUpdate(_ image: CloudImage) async throws -> ImageUpdateStatus {
        try Self.validateFileName(image.fileName)
        guard let stored = cachedDigest(image) else { return .notCached }
        try DownloadPolicy.validate(image.checksumsURL)
        let sums = try await fetchSums(image)
        guard let published = sums[image.fileName] else {
            throw NidoError.downloadFailed(L10n.string("no checksum for \(image.fileName)"))
        }
        return published == stored ? .current : .updateAvailable
    }

    /// Whether `image` has a cached copy with its sidecar (no hashing, no network): for listings.
    public func isCached(_ image: CloudImage) -> Bool {
        (try? Self.validateFileName(image.fileName)) != nil && cachedDigest(image) != nil
    }

    /// The Debian build last accepted for `image` (`acceptBuild`), from the cache alone: the one
    /// the last check or download verified, which can be newer than the cached image (a check
    /// that found a new build accepts it before any download). Nil without a valid record.
    public func acceptedBuild(_ image: CloudImage) -> String? {
        guard (try? Self.validateFileName(image.fileName)) != nil,
            let text = try? String(contentsOf: buildRecordURL(image), encoding: .utf8)
        else { return nil }
        let fields = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard fields.count == 2, let version = DebianBuildManifest.Version(fields[0]) else { return nil }
        return version.description
    }

    /// `nido image reset`: forgets the build (`acceptBuild`) and the signature time
    /// (`acceptSignature`) accepted for `image`, so the next list is taken as a first time. For a
    /// refusal that does not go away (a mirror stuck on an older build); it lowers the replay
    /// protection until the next accepted list. The cached image stays. Returns the records removed.
    @discardableResult
    public func forgetAccepted(_ image: CloudImage) throws -> [URL] {
        try Self.validateFileName(image.fileName)
        var removed: [URL] = []
        for record in [buildRecordURL(image), signatureRecordURL(image)] {
            do {
                try FileManager.default.removeItem(at: record)
                removed.append(record)
            } catch let error as CocoaError where error.code == .fileNoSuchFile {
                continue
            }
        }
        return removed
    }

    private func buildRecordURL(_ image: CloudImage) -> URL {
        cacheRoot.appendingPathComponent(image.fileName + ".build", isDirectory: false)
    }

    private func signatureRecordURL(_ image: CloudImage) -> URL {
        cacheRoot.appendingPathComponent(image.fileName + ".signed", isDirectory: false)
    }

    /// The digest recorded when the cached copy was verified; nil without a regular image file
    /// or with a malformed sidecar.
    private func cachedDigest(_ image: CloudImage) -> String? {
        let file = cacheRoot.appendingPathComponent(image.fileName, isDirectory: false)
        let digest = cacheRoot.appendingPathComponent(image.sidecarName, isDirectory: false)
        guard (try? fileType(file)) == .some(.typeRegular),
            let stored = try? readDigest(digest).trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            stored.count == image.checksum.hexLength, stored.allSatisfy(\.isHexDigit)
        else { return nil }
        return stored
    }

    // MARK: - Cache

    private static func validateFileName(_ name: String) throws {
        guard !name.isEmpty, !name.contains("/"), name != ".", name != "..", !name.hasPrefix(".") else {
            throw NidoError.unsafePath(name)
        }
    }

    /// The cache-validity reads, injectable for the tests.
    private struct CacheReads: Sendable {
        let hashFile: @Sendable (URL, ChecksumAlgorithm) throws -> String
        let readDigest: @Sendable (URL) throws -> String
        let fileType: @Sendable (URL) throws -> FileAttributeType?
    }

    /// A cache entry is valid when the image is a regular file whose digest (`algorithm`) equals the one
    /// stored at download time. An invalid or incomplete entry is a miss but is never deleted:
    /// another process (CLI or app) may be publishing it right now; the download that follows
    /// replaces both files atomically. A transient I/O error while reading (`EINTR`, `EAGAIN`)
    /// is rethrown: it says nothing about the entry. `@concurrent`: runs on the global executor,
    /// never on the actor (the hash reads the whole image).
    @concurrent
    private static func isValidCacheEntry(
        file: URL, digest: URL, algorithm: ChecksumAlgorithm, reads: CacheReads
    ) async throws -> Bool {
        let hashFile = reads.hashFile, readDigest = reads.readDigest, fileType = reads.fileType
        // A missing or unreadable-for-good entry is a cache miss; a transient error is not.
        func attempt<T>(_ body: () throws -> T) throws -> T? {
            do { return try body() } catch {
                if Self.isTransientIO(error) { throw error }
                return nil
            }
        }
        if try attempt({ try fileType(file) }) == .some(.typeRegular),
           let stored = try attempt({
               try readDigest(digest).trimmingCharacters(in: .whitespacesAndNewlines)
           }),
           stored.count == algorithm.hexLength,
           let actual = try attempt({ try hashFile(file, algorithm) }),
           actual == stored.lowercased()
        {
            return true
        }
        return false
    }

    static func isTransientIO(_ error: any Error) -> Bool {
        let transient: Set<Int32> = [EINTR, EAGAIN]
        if let posix = error as? POSIXError { return transient.contains(posix.code.rawValue) }
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain { return transient.contains(Int32(truncatingIfNeeded: ns.code)) }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            return isTransientIO(underlying)
        }
        return false
    }

    // MARK: - Network

    /// The checksum list of `image`, parsed; when the image has a `signature`, only after it
    /// verified with the built-in key (before anything in the list is read).
    private func fetchSums(_ image: CloudImage) async throws -> [String: String] {
        let data = try await fetchChecksums(image.checksumsURL)
        if let signature = image.signature {
            try DownloadPolicy.validate(signature.url)
            let transfer = StreamingTransfer(
                url: signature.url, policy: DownloadPolicy.validate, sink: .memory,
                limit: OpenPGPSignature.maxBytes,
                overLimit: .downloadFailed(L10n.string("checksum list signature over the \(ByteSize.format(OpenPGPSignature.maxBytes)) limit")))
            let signed: Data
            do {
                signed = try await transfer.run(session: session).data
            } catch NidoError.downloadFailed(let reason) {
                throw NidoError.downloadFailed(L10n.string("checksum list signature not downloaded (\(reason))"))
            }
            let created = try OpenPGPSignature.verify(signed, of: data, keys: signature.keys)
            try acceptSignature(created, of: image)
        }
        let sums = Checksums.parseSums(String(decoding: data, as: UTF8.self), algorithm: image.checksum)
        if let manifest = image.manifest { try await checkManifest(manifest, sums: sums, of: image) }
        return sums
    }

    /// Debian (no signature): the build manifest must be the one the list names, give the image
    /// the list's digest, and not be an older build than the last one accepted (`acceptBuild`).
    /// None of this makes an unsigned list trustworthy: it only refuses an inconsistent or older
    /// set of files (docs/SECURITY.md).
    private func checkManifest(_ manifest: CloudImage.Manifest, sums: [String: String], of image: CloudImage) async throws {
        try DownloadPolicy.validate(manifest.url)
        guard let listed = sums[manifest.fileName] else {
            throw NidoError.downloadFailed(L10n.string("build manifest missing from the checksum list"))
        }
        let transfer = StreamingTransfer(
            url: manifest.url, policy: DownloadPolicy.validate, sink: .memory, limit: DebianBuildManifest.maxBytes,
            overLimit: .downloadFailed(L10n.string("build manifest over the \(ByteSize.format(DebianBuildManifest.maxBytes)) limit")))
        let data: Data
        do {
            data = try await transfer.run(session: session).data
        } catch NidoError.downloadFailed(let reason) {
            throw NidoError.downloadFailed(L10n.string("build manifest not downloaded (\(reason))"))
        }
        guard SHA512.hash(data: data).map({ String(format: "%02x", $0) }).joined() == listed else {
            throw NidoError.downloadFailed(L10n.string("build manifest differs from the one in the checksum list"))
        }
        let build = try DebianBuildManifest.parse(data, imageFormat: manifest.imageFormat)
        guard build.sha512 == sums[image.fileName] else {
            throw NidoError.downloadFailed(L10n.string(
                "the manifest of build \(build.version.description) lists a different checksum for \(image.fileName) than the checksum list does"))
        }
        try acceptBuild(build.version, sha512: build.sha512, of: image)
    }

    /// Against an older build served again (Debian, `checkManifest`): the last build accepted for
    /// `image` is kept in `<fileName>.build` ("<version> <sha512>"). An older version is refused,
    /// and so is the same version with another digest (a build is never rebuilt under its name).
    /// Same rules as `acceptSignature`: a missing or unreadable record is a first time, the
    /// record is 0600 and a failed write does not refuse the list.
    private func acceptBuild(_ version: DebianBuildManifest.Version, sha512: String, of image: CloudImage) throws {
        let record = buildRecordURL(image)
        let reset = "nido image reset \(image.id)"
        if let text = try? String(contentsOf: record, encoding: .utf8) {
            let fields = text.split(whereSeparator: \.isWhitespace).map(String.init)
            if fields.count == 2, let last = DebianBuildManifest.Version(fields[0]) {
                guard version >= last else {
                    throw NidoError.downloadFailed(L10n.string(
                        "build \(version.description) is older than the one already accepted (\(last.description)): it may be an old copy served again; try again later (if it keeps happening: \(reset))"))
                }
                if version == last {
                    guard sha512 == fields[1] else {
                        throw NidoError.downloadFailed(L10n.string(
                            "build \(version.description) was already accepted with another checksum: the files changed without a new build; try again later (if it keeps happening: \(reset))"))
                    }
                    return
                }
            }
        }
        try? PrivateDirectory.ensure(cacheRoot)
        try? PrivateFile.writeAtomically(Data("\(version) \(sha512)\n".utf8), to: record)
    }

    /// Against a replayed list: a valid signature older than the last one accepted for `image`
    /// (an old list served again by a compromised mirror or TLS, to keep the cache on an older
    /// build) is refused. The creation time of the last accepted one is kept in
    /// `<fileName>.signed` (Unix seconds); only signature times are compared, never the Mac's
    /// clock. A missing or unreadable record is a first time: it is written again (whoever can
    /// write the cache can remove the protection: tampering from the Mac is out of scope). The
    /// record is written 0600 and atomically (`PrivateFile`); a failed write does not refuse a
    /// valid list, the protection just does not move forward.
    private func acceptSignature(_ created: Date, of image: CloudImage) throws {
        let record = signatureRecordURL(image)
        let seconds = Int64(created.timeIntervalSince1970)
        if let text = try? String(contentsOf: record, encoding: .utf8),
            let last = Int64(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            guard seconds >= last else {
                let (signed, accepted, reset) = (Self.utcDate(seconds), Self.utcDate(last), "nido image reset \(image.id)")
                throw NidoError.downloadFailed(L10n.string(
                    "checksum list signed on \(signed), before the one already accepted (\(accepted)): it may be an old copy served again; try again later (if it keeps happening: \(reset))"))
            }
            if seconds == last { return }
        }
        try? PrivateDirectory.ensure(cacheRoot)
        try? PrivateFile.writeAtomically(Data("\(seconds)\n".utf8), to: record)
    }

    private static func utcDate(_ seconds: Int64) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm 'UTC'"
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(seconds)))
    }

    /// Strict: the request and every redirect must pass `DownloadPolicy.validate`;
    /// the body is capped at `maxChecksumsBytes`.
    private func fetchChecksums(_ url: URL) async throws -> Data {
        let transfer = StreamingTransfer(
            url: url, policy: DownloadPolicy.validate, sink: .memory,
            limit: Self.maxChecksumsBytes,
            overLimit: .downloadFailed(L10n.string("checksum list over the \(ByteSize.format(Self.maxChecksumsBytes)) limit")))
        return try await transfer.run(session: session).data
    }

    /// Image download: redirects may go to any HTTPS mirror (checked on every hop and on the
    /// final URL); the body is written to `fd`, capped at `image.maxBytes`.
    /// Returns the digest (`image.checksum`, lowercase hex) of the written bytes.
    private func fetchImage(
        _ image: CloudImage, into fd: Int32, progress: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> String {
        let transfer = StreamingTransfer(
            url: image.url, policy: DownloadPolicy.validateMirrorRedirect, sink: .file(fd),
            digest: image.checksum == .sha512 ? .sha512 : .sha256, limit: image.maxBytes,
            overLimit: .downloadFailed(L10n.string("image over the \(ByteSize.format(image.maxBytes)) limit")),
            progress: progress)
        return try await transfer.run(session: session).digest
    }
}

/// The cached copy of a catalog image against the build the catalog publishes now.
public enum ImageUpdateStatus: Sendable, Equatable {
    /// No cached copy: the next VM downloads the current build anyway.
    case notCached
    /// The cached copy is the published build.
    case current
    /// The catalog publishes another build (security fixes): `ensureImage(refresh: true)`.
    case updateAvailable
}

/// Bytes received so far by a running image download.
public struct DownloadProgress: Sendable, Equatable {
    public var receivedBytes: UInt64
    /// Declared `Content-Length`, when the server sent one.
    public var expectedBytes: UInt64?

    public init(receivedBytes: UInt64, expectedBytes: UInt64?) {
        self.receivedBytes = receivedBytes
        self.expectedBytes = expectedBytes
    }
}

/// Fans one download's progress out to every caller waiting for it (also `OllamaArchiveStore`).
final class ProgressBroadcaster: Sendable {
    private let handlers = Mutex<[UUID: @Sendable (DownloadProgress) -> Void]>([:])

    func add(_ id: UUID, _ handler: @escaping @Sendable (DownloadProgress) -> Void) {
        handlers.withLock { $0[id] = handler }
    }

    func remove(_ id: UUID) {
        handlers.withLock { _ = $0.removeValue(forKey: id) }
    }

    @Sendable func send(_ progress: DownloadProgress) {
        let current = handlers.withLock { Array($0.values) }
        for handler in current { handler(progress) }
    }
}

/// One GET driven by a per-task `URLSessionDataDelegate`: every redirect and the final URL
/// must pass `policy`; the status must be 2xx; the body is delivered chunk by chunk to the
/// sink (memory or an open file descriptor) and, for a file, hashed on the way (SHA-512 or
/// SHA-256), and the transfer is cancelled as soon as more than `limit` bytes are declared or
/// received. The first failure wins and is the error thrown by `run`. Also used by
/// `OllamaArchiveStore`.
final class StreamingTransfer: NSObject, URLSessionDataDelegate, Sendable {
    typealias Policy = @Sendable (URL) throws(NidoError) -> Void

    /// The hash computed over a file sink.
    enum Digest: Sendable {
        case sha512, sha256
    }

    enum Sink: Sendable {
        case memory
        case file(Int32)
    }

    struct Outcome: Sendable {
        let data: Data
        /// Lowercase hex of `digest` over the bytes written to the file sink.
        let digest: String
        let received: UInt64
    }

    private struct State {
        var continuation: CheckedContinuation<Outcome, any Error>?
        var receivedResponse = false
        var failure: (any Error)?
        var sha512 = SHA512()
        var sha256 = SHA256()
        var data = Data()
        var received: UInt64 = 0
        var expected: UInt64?
        var lastReported: UInt64 = 0
    }

    /// Minimum number of new bytes between two progress reports.
    static let progressStep: UInt64 = 256 << 10

    private let url: URL
    private let policy: Policy
    private let sink: Sink
    private let digest: Digest
    private let limit: UInt64
    private let overLimit: NidoError
    private let progress: (@Sendable (DownloadProgress) -> Void)?
    private let state = Mutex(State())

    init(url: URL, policy: @escaping Policy, sink: Sink, digest: Digest = .sha512, limit: UInt64,
         overLimit: NidoError, progress: (@Sendable (DownloadProgress) -> Void)? = nil) {
        self.progress = progress
        self.url = url
        self.policy = policy
        self.sink = sink
        self.digest = digest
        self.limit = limit
        self.overLimit = overLimit
    }

    func run(session: URLSession) async throws -> Outcome {
        let task = session.dataTask(with: URLRequest(url: url))
        task.delegate = self
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                state.withLock { $0.continuation = continuation }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    /// Records `error` unless an earlier failure is already recorded.
    private func fail(_ error: any Error) {
        state.withLock { s in
            if s.failure == nil { s.failure = error }
        }
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        do {
            guard let target = request.url else { throw NidoError.hostNotAllowed("") }
            try policy(target)
            completionHandler(request)
        } catch {
            fail(error)
            task.cancel()
            completionHandler(nil)
        }
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        do {
            if let finalURL = response.url { try policy(finalURL) }
            guard let http = response as? HTTPURLResponse else {
                throw NidoError.downloadFailed(L10n.string("non-HTTP response for \(url.absoluteString)"))
            }
            guard (200...299).contains(http.statusCode) else {
                throw NidoError.downloadFailed(L10n.string("HTTP \(String(http.statusCode)) for \(url.absoluteString)"))
            }
            if response.expectedContentLength > 0, UInt64(response.expectedContentLength) > limit {
                throw overLimit
            }
            state.withLock { s in
                s.receivedResponse = true
                if response.expectedContentLength > 0 { s.expected = UInt64(response.expectedContentLength) }
            }
            completionHandler(.allow)
        } catch {
            fail(error)
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        var report: DownloadProgress?
        let failed = state.withLock { s -> Bool in
            guard s.failure == nil else { return true }
            let total = s.received + UInt64(data.count)
            guard total <= limit else {
                s.failure = overLimit
                return true
            }
            switch sink {
            case .memory:
                s.data.append(data)
            case .file(let fd):
                if let err = Self.writeAll(fd, data) {
                    s.failure = POSIXError(POSIXErrorCode(rawValue: err) ?? .EIO)
                    return true
                }
                switch digest {
                case .sha512: s.sha512.update(data: data)
                case .sha256: s.sha256.update(data: data)
                }
            }
            s.received = total
            if total - s.lastReported >= Self.progressStep {
                s.lastReported = total
                report = DownloadProgress(receivedBytes: total, expectedBytes: s.expected)
            }
            return false
        }
        if failed { dataTask.cancel() }
        if let report { progress?(report) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        var final: DownloadProgress?
        let (continuation, result) = state.withLock { s -> (CheckedContinuation<Outcome, any Error>?, Result<Outcome, any Error>) in
            let continuation = s.continuation
            s.continuation = nil
            if let failure = s.failure { return (continuation, .failure(failure)) }
            if let error { return (continuation, .failure(error)) }
            guard s.receivedResponse else {
                return (continuation, .failure(NidoError.downloadFailed(L10n.string("no response for \(url.absoluteString)"))))
            }
            if s.lastReported != s.received || s.received == 0 {
                final = DownloadProgress(receivedBytes: s.received, expectedBytes: s.expected)
            }
            let hex: String = switch digest {
            case .sha512: s.sha512.finalize().map { String(format: "%02x", $0) }.joined()
            case .sha256: s.sha256.finalize().map { String(format: "%02x", $0) }.joined()
            }
            return (continuation, .success(Outcome(data: s.data, digest: hex, received: s.received)))
        }
        if let final, case .file = sink { progress?(final) }
        continuation?.resume(with: result)
    }

    /// Writes every byte of `data` to `fd`, retrying on `EINTR`. Returns `errno` on failure.
    private static func writeAll(_ fd: Int32, _ data: Data) -> Int32? {
        for region in data.regions {
            let err: Int32? = region.withUnsafeBytes { buf in
                guard let base = buf.baseAddress else { return nil }
                var offset = 0
                while offset < buf.count {
                    let n = Darwin.write(fd, base + offset, buf.count - offset)
                    if n < 0 {
                        if errno == EINTR { continue }
                        return errno
                    }
                    offset += n
                }
                return nil
            }
            if let err { return err }
        }
        return nil
    }
}
