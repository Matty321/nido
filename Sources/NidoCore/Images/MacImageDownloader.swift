// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation
import Synchronization

/// Downloads the macOS restore image Apple offers (`MacImageOffer`), only when the user asks
/// (`nido image macos --download`, the wizard's "Download from Apple").
///
/// - HTTPS from Apple's hosts only: the offer's URL, every redirect hop and the final URL must
///   pass `DownloadPolicy.validateAppleDownload` (`.hostNotAllowed` otherwise).
/// - The bytes go into `.<name>.part` next to the destination (0600), with a sidecar
///   `.<name>.part.json` (URL, expected size, `ETag`/`Last-Modified`) written before the first
///   byte. A later call resumes with `Range: bytes=<partial − 8 MiB>-` and `If-Range` (the tail
///   is fetched again, in case a power loss left it unwritten): a 206 appends, a 200 (a server
///   ignoring the range, or a file that changed) starts over from byte zero, a 416 means the
///   file was complete or changed size (start over).
/// - Free space: `expected − partial + 1 GiB` on the destination's volume, checked before the
///   request (with what the sidecar knows) and again once the server declares the size, before
///   anything is written (`.insufficientSpace`). Above 40 GiB the download is refused.
/// - Apple publishes no checksum: the complete file is checked under a hidden name
///   (`.<stem>.checking.<extension>`) and takes the destination's name only if
///   `MacRestoreImage.inspect` loads it and its build is the offer's. Otherwise it is deleted
///   (with the sidecar) and the error says why. A check file left by an interrupted run becomes
///   the partial file again on the next call.
/// - Cancelling, a network error or a failed write keep the `.part` and its sidecar for the next
///   call (an empty `.part` is removed). One download at a time per destination, across
///   processes (`flock` on the `.part`, then on the check file).
/// - The bytes are written from the URLSession delegate's queue, never through the actor.
public actor MacImageDownloader {
    /// Largest image accepted (Apple's IPSWs are around 18 GiB).
    public static let maxBytes: UInt64 = 40 << 30
    /// Free space left on the volume once the download is complete.
    public static let spaceMargin: UInt64 = 1 << 30
    /// Bytes at the end of a partial file fetched again on resume: a power loss can leave the
    /// last writes unwritten while the size says otherwise.
    public static let resumeBackoff: UInt64 = 8 << 20
    /// Largest sidecar read.
    static let maxRecordBytes = 64 << 10

    private let session: URLSession
    private let macosDirectory: URL
    private let loader: any MacRestoreImageLoading
    private let availableSpace: @Sendable (URL) -> Int64?
    private let hostVersion: OperatingSystemVersion
    private let writeChunk: @Sendable (Int32, Data, UInt64) -> Int32?
    private let resumeBackoff: UInt64

    /// `availableSpace` answers the free bytes of the volume holding a directory (nil: unknown,
    /// not checked).
    public init(
        session: URLSession = ImageStore.makeDownloadSession(),
        cacheRoot: URL = ImageStore.defaultCacheRoot(),
        loader: any MacRestoreImageLoading = LiveRestoreImageLoader(),
        availableSpace: @escaping @Sendable (URL) -> Int64? = MacImageDownloader.volumeAvailableSpace
    ) {
        self.init(
            session: session, cacheRoot: cacheRoot, loader: loader, availableSpace: availableSpace,
            hostVersion: ProcessInfo.processInfo.operatingSystemVersion, writeChunk: Self.writeAll,
            resumeBackoff: Self.resumeBackoff)
    }

    /// Test seam: `hostVersion` for `MacRestoreImage.inspect`; `writeChunk` writes a chunk at an
    /// offset and returns `errno` on failure (a full disk); `resumeBackoff` bytes are fetched again
    /// at the end of a partial file.
    init(
        session: URLSession, cacheRoot: URL, loader: any MacRestoreImageLoading,
        availableSpace: @escaping @Sendable (URL) -> Int64?, hostVersion: OperatingSystemVersion,
        writeChunk: @escaping @Sendable (Int32, Data, UInt64) -> Int32?, resumeBackoff: UInt64
    ) {
        self.session = session
        self.macosDirectory = cacheRoot.appendingPathComponent("macos", isDirectory: true)
        self.loader = loader
        self.availableSpace = availableSpace
        self.hostVersion = hostVersion
        self.writeChunk = writeChunk
        self.resumeBackoff = resumeBackoff
    }

    /// `SnapshotStore.volumeAvailableCapacity`, nil when the system does not say.
    public static func volumeAvailableSpace(_ url: URL) -> Int64? {
        guard let bytes = try? SnapshotStore.volumeAvailableCapacity(url) else { return nil }
        return Int64(clamping: bytes)
    }

    // MARK: - Paths

    /// Where `offer` goes: `<cache>/macos/<offer.fileName>` (whatever is there; `download`
    /// checks it), or `output`, which must be a new path in an existing folder: an existing
    /// item there is refused (`.downloadFailed`), a symbolic link too (`.unsafePath`), a missing
    /// folder is `.notFound`.
    public nonisolated func destination(for offer: MacImageOffer, output: URL?) throws(NidoError) -> URL {
        guard let output else {
            let name = offer.fileName
            guard Self.isSafeFileName(name), !name.hasPrefix(".") else { throw .unsafePath(name) }
            return macosDirectory.appendingPathComponent(name, isDirectory: false)
        }
        return try outputDestination(output)
    }

    /// `--output`: a new path in an existing folder (see `destination(for:output:)`). It needs no
    /// offer, so it can be checked before anything goes online.
    public nonisolated func outputDestination(_ output: URL) throws(NidoError) -> URL {
        guard output.isFileURL else { throw .unsafePath(output.absoluteString) }
        let url = output.standardizedFileURL
        guard Self.isSafeFileName(url.lastPathComponent) else { throw .unsafePath(url.path) }
        var info = stat()
        if lstat(url.path, &info) == 0 {
            if (info.st_mode & S_IFMT) == S_IFLNK { throw .unsafePath(url.path) }
            throw .downloadFailed(Self.alreadyExists(url))
        }
        let parent = url.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDirectory), isDirectory.boolValue
        else { throw .notFound(parent.path) }
        return url
    }

    /// Bytes already in the partial file of `destination` (0 without one).
    public nonisolated func partialBytes(for destination: URL) -> Int64 {
        var info = stat()
        guard lstat(Self.partURL(destination).path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return 0 }
        return Int64(info.st_size)
    }

    /// What Nido knows before the confirmation, so nothing is downloaded and then deleted:
    /// - `.restoreImageUnsupported(version:requiredHostMajor:)` when the offer's major version is
    ///   newer than the host's (the rule of `MacRestoreImage.inspect`);
    /// - `.downloadFailed` when `size`, if known, is over `maxBytes`.
    public static func checkOffer(
        _ offer: MacImageOffer, size: UInt64?,
        hostVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
    ) throws(NidoError) {
        if let major = offer.majorVersion, major > hostVersion.majorVersion {
            throw .restoreImageUnsupported(version: offer.version, requiredHostMajor: major)
        }
        if let size, size > maxBytes {
            throw .downloadFailed(L10n.string("image over the \(ByteSize.format(maxBytes)) limit"))
        }
    }

    /// A file in the macOS cache folder that is not part of the download of `destination`.
    public struct CachedFile: Equatable, Sendable {
        public let name: String
        public let path: String
        public let bytes: UInt64
    }

    /// The regular files in the macOS cache folder besides `destination`, its partial file, its
    /// sidecar and its check file (old builds, partial files of other downloads), by name. Nothing
    /// is deleted. Sidecars (`.part.json`) are left out: they are not what takes the space.
    public nonisolated func otherCachedFiles(besides destination: URL) -> [CachedFile] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: macosDirectory.path)) ?? []
        let own: Set<String> = [
            destination.lastPathComponent, Self.partURL(destination).lastPathComponent,
            Self.recordURL(destination).lastPathComponent, Self.checkURL(destination).lastPathComponent,
        ]
        var files: [CachedFile] = []
        for name in names.sorted() where !own.contains(name) && !name.hasSuffix(".part.json") {
            var info = stat()
            let path = macosDirectory.appendingPathComponent(name).path
            guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { continue }
            files.append(CachedFile(name: name, path: path, bytes: UInt64(max(0, info.st_size))))
        }
        return files
    }

    static func partURL(_ destination: URL) -> URL {
        destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).part", isDirectory: false)
    }

    static func recordURL(_ destination: URL) -> URL {
        destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).part.json", isDirectory: false)
    }

    /// `.<stem>.checking.<extension>`: where the complete file is checked before it takes its name.
    static func checkURL(_ destination: URL) -> URL {
        let ext = destination.pathExtension
        let stem = destination.deletingPathExtension().lastPathComponent
        let name = ext.isEmpty ? ".\(stem).checking" : ".\(stem).checking.\(ext)"
        return destination.deletingLastPathComponent().appendingPathComponent(name, isDirectory: false)
    }

    private static func isSafeFileName(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("/") && !name.contains("\0") && name != "." && name != ".."
    }

    private static func alreadyExists(_ url: URL) -> String {
        L10n.string("\(url.path) already exists: remove it or choose another path")
    }

    private static func busy(_ url: URL) -> String {
        L10n.string("another download is already writing \(url.path)")
    }

    // MARK: - Size

    /// The size of the image Apple serves for `offer`, from a HEAD request (nil when the server
    /// does not say or the request fails). Part of the same explicit ask as the offer; the same
    /// session, and Apple's policy on the URL and on every redirect hop: a hop elsewhere throws
    /// `.hostNotAllowed`.
    public func remoteSize(of offer: MacImageOffer) async throws -> UInt64? {
        try DownloadPolicy.validateAppleDownload(offer.url)
        var request = URLRequest(url: offer.url)
        request.httpMethod = "HEAD"
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let guardRedirects = HeadRedirectGuard()
        let response: URLResponse
        do {
            (_, response) = try await session.data(for: request, delegate: guardRedirects)
        } catch {
            if let refused = guardRedirects.refusal { throw refused }
            if error is CancellationError { throw error }
            return nil
        }
        if let refused = guardRedirects.refusal { throw refused }
        if let finalURL = response.url { try DownloadPolicy.validateAppleDownload(finalURL) }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
            let length = http.value(forHTTPHeaderField: "Content-Length").flatMap({ UInt64($0) }), length > 0
        else { return nil }
        return length
    }

    // MARK: - Download

    /// Downloads `offer` to `destination` (from `destination(for:output:)`), resuming a partial
    /// file left by an earlier call, and returns `destination` once checked. A file already at
    /// `destination` that is the offer's build is returned without any request.
    ///
    /// `progress` gets the bytes on disk (a resumed download starts from the partial size) and
    /// the full size when known: once when the server answers, then at most every 256 KiB and at
    /// the end, from a background thread. Cancelling the task throws `CancellationError` and
    /// keeps the partial file.
    public func download(
        _ offer: MacImageOffer, to destination: URL,
        progress: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> URL {
        try Task.checkCancellation()
        try DownloadPolicy.validateAppleDownload(offer.url)
        guard Self.isSafeFileName(destination.lastPathComponent) else { throw NidoError.unsafePath(destination.path) }
        let directory = destination.deletingLastPathComponent()
        if directory.standardizedFileURL.path == macosDirectory.standardizedFileURL.path {
            try PrivateDirectory.ensure(directory)
        } else {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue
            else { throw NidoError.notFound(directory.path) }
        }

        var info = stat()
        if lstat(destination.path, &info) == 0 {
            if (info.st_mode & S_IFMT) == S_IFLNK { throw NidoError.unsafePath(destination.path) }
            // Already downloaded and checked (or someone else's file): never replaced nor deleted.
            if (info.st_mode & S_IFMT) == S_IFREG, (try? await inspectedBuild(destination)) == offer.build {
                return destination
            }
            throw NidoError.downloadFailed(Self.alreadyExists(destination))
        }

        let partURL = Self.partURL(destination)
        let recordURL = Self.recordURL(destination)
        let checkURL = Self.checkURL(destination)
        try Self.recoverCheckFile(checkURL, part: partURL)
        var fd = try Self.openLocked(partURL, create: false)
        var keepOpen = false
        defer { if !keepOpen, fd >= 0 { _ = Darwin.close(fd) } }

        // What is already on disk, and whether it can be resumed.
        var resume = try Self.resumePoint(fd: fd, record: recordURL, url: offer.url, backoff: resumeBackoff)
        if resume == nil { _ = Darwin.unlink(recordURL.path) }

        // Every byte already there (the last run ended before the check): check it, no request.
        if let resume, let expected = resume.expected, expected == resume.offset {
            keepOpen = true
            return try await finish(
                fd: fd, part: partURL, record: recordURL, check: checkURL, destination: destination, offer: offer)
        }

        let needed = (resume.flatMap { r in r.expected.map { $0 - r.offset } } ?? 0) + Self.spaceMargin
        if let free = availableSpace(directory) {
            let available = UInt64(max(0, free))
            guard available >= needed else {
                if fd >= 0, resume == nil { Self.discard(part: partURL, record: recordURL) }
                throw NidoError.insufficientSpace(needed: needed, available: available)
            }
        }
        try Task.checkCancellation()

        if fd < 0 { fd = try Self.openLocked(partURL, create: true) }
        while true {
            let transfer = MacImageTransfer(
                url: offer.url, resume: resume, fd: fd, limit: Self.maxBytes,
                overLimit: .downloadFailed(L10n.string("image over the \(ByteSize.format(Self.maxBytes)) limit")),
                write: writeChunk,
                onResponse: Self.prepare(fd: fd, directory: directory, record: recordURL, url: offer.url,
                                         availableSpace: availableSpace),
                progress: progress)
            do {
                let outcome = try await transfer.run(session: session)
                if let expected = outcome.expected, outcome.total != expected {
                    throw NidoError.downloadFailed(L10n.string(
                        "the download stopped early (\(ByteSize.format(outcome.total)) of \(ByteSize.format(expected))): try again to resume it"))
                }
                break
            } catch let unsatisfiable as MacImageTransfer.RangeNotSatisfiable {
                // 416 to a resumed request: every byte was already there, or the file changed size.
                if let total = unsatisfiable.total, total == resume?.offset, (try? Self.fileSize(fd)) == total {
                    break
                }
                guard ftruncate(fd, 0) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                _ = Darwin.unlink(recordURL.path)
                resume = nil
            } catch let failure as MacImageTransfer.DiscardPartial {
                Self.discard(part: partURL, record: recordURL)
                throw failure.error
            } catch {
                if (try? Self.fileSize(fd)) == 0 { Self.discard(part: partURL, record: recordURL) }
                throw error
            }
        }
        keepOpen = true
        return try await finish(
            fd: fd, part: partURL, record: recordURL, check: checkURL, destination: destination, offer: offer)
    }

    /// The complete file never sits unchecked under its final name: it is synced, renamed to its
    /// hidden check name (same extension, for Virtualization), checked there, and renamed to
    /// `destination` only if it is a restore image of `offer.build` (never over an existing item).
    /// A file that fails is deleted with the sidecar. `fd` (and its lock) is held until the end,
    /// so no other download touches the check file meanwhile; it is closed on return.
    private func finish(
        fd: Int32, part: URL, record: URL, check: URL, destination: URL, offer: MacImageOffer
    ) async throws -> URL {
        defer { _ = Darwin.close(fd) }
        guard fsync(fd) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard renamex_np(part.path, check.path, UInt32(RENAME_EXCL)) == 0 else {
            if errno == EEXIST { throw NidoError.downloadFailed(Self.busy(check)) }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let build: String
        do {
            build = try await inspectedBuild(check)
        } catch {
            Self.discard(part: check, record: record)
            switch error {
            case .notARestoreImage:
                throw NidoError.downloadFailed(L10n.string(
                    "the downloaded file isn’t a macOS restore image Virtualization can load: it was deleted"))
            case .restoreImageUnsupported(let version, _):
                throw NidoError.downloadFailed(L10n.string(
                    "the downloaded macOS \(version) can’t be installed on this Mac: it was deleted"))
            default:
                throw NidoError.downloadFailed(L10n.string(
                    "the downloaded file can’t be checked (\(error.localizedDescription)): it was deleted"))
            }
        }
        guard build == offer.build else {
            Self.discard(part: check, record: record)
            throw NidoError.downloadFailed(L10n.string(
                "the downloaded file is build \(build), not build \(offer.build) as Apple’s catalog said: it was deleted"))
        }
        guard renamex_np(check.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
            let err = errno
            if err == EEXIST {
                // Something took the name meanwhile: it is left alone, and this copy goes.
                Self.discard(part: check, record: record)
                throw NidoError.downloadFailed(Self.alreadyExists(destination))
            }
            // Kept: the next call checks it again (`recoverCheckFile`).
            throw POSIXError(POSIXErrorCode(rawValue: err) ?? .EIO)
        }
        _ = Darwin.unlink(record.path)
        return destination
    }

    /// Where a partial file resumes: `backoff` bytes before its end (bytes a power loss may have
    /// left unwritten are fetched again; the tail is cut when the server answers). Nil, and the
    /// file emptied, when it cannot be resumed: no sidecar or another URL, no validator, a size
    /// over `maxBytes` or over the announced one, or nothing left once `backoff` is taken off.
    private static func resumePoint(
        fd: Int32, record: URL, url: URL, backoff: UInt64
    ) throws -> MacImageTransfer.Resume? {
        guard fd >= 0 else { return nil }
        let partial = try fileSize(fd)
        var resume: MacImageTransfer.Resume?
        if partial > 0, partial <= maxBytes, let saved = readRecord(record), saved.url == url.absoluteString,
            let validator = saved.validator,
            saved.expectedBytes.map({ $0 <= maxBytes && partial <= $0 }) ?? true
        {
            let complete = saved.expectedBytes == partial && backoff == 0
            let offset = complete ? partial : (partial > backoff ? partial - backoff : 0)
            if offset > 0 {
                resume = MacImageTransfer.Resume(
                    offset: offset, validator: validator, etag: saved.etag, lastModified: saved.lastModified,
                    expected: saved.expectedBytes)
            }
        }
        // A resumed file is cut to `offset` only once the server answers (`prepare`): a failed
        // request does not eat into it again and again.
        if resume == nil, partial > 0 {
            guard ftruncate(fd, 0) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
        return resume
    }

    /// A check file left by a run that stopped while checking (a crash, Ctrl-C): it becomes the
    /// partial file again (checked, resumed or restarted like one), or goes when a partial file
    /// already exists. One that another download is checking right now is refused (busy).
    private static func recoverCheckFile(_ check: URL, part: URL) throws {
        let fd = try openLocked(check, create: false)
        guard fd >= 0 else { return }
        defer { _ = Darwin.close(fd) }
        if renamex_np(check.path, part.path, UInt32(RENAME_EXCL)) != 0 {
            // Only a partial file already there makes the check file useless; any other failure
            // leaves it where it is for the next call.
            let err = errno
            guard err == EEXIST else { throw POSIXError(POSIXErrorCode(rawValue: err) ?? .EIO) }
            _ = Darwin.unlink(check.path)
        }
    }

    private func inspectedBuild(_ url: URL) async throws(NidoError) -> String {
        try await MacRestoreImage.inspect(url, loader: loader, hostVersion: hostVersion).buildVersion
    }

    /// Runs on the delegate's queue once the server answered, before any byte is written: the
    /// partial file cut to where the body starts (0 for a 200: what was there is of no use), free
    /// space for what is left, and the sidecar for a later resume.
    private static func prepare(
        fd: Int32, directory: URL, record: URL, url: URL, availableSpace: @escaping @Sendable (URL) -> Int64?
    ) -> @Sendable (MacImageTransfer.Response) throws -> Void {
        { response in
            guard ftruncate(fd, off_t(response.start)) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            if let total = response.total, let free = availableSpace(directory) {
                let needed = total - response.start + spaceMargin
                let available = UInt64(max(0, free))
                guard available >= needed else { throw NidoError.insufficientSpace(needed: needed, available: available) }
            }
            let partial = PartialRecord(
                url: url.absoluteString, expectedBytes: response.total, etag: response.etag,
                lastModified: response.lastModified)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try PrivateFile.writeAtomically(try encoder.encode(partial), to: record)
        }
    }

    // MARK: - Files

    /// What the sidecar of a partial file says.
    struct PartialRecord: Codable, Equatable, Sendable {
        var url: String
        var expectedBytes: UInt64?
        var etag: String?
        var lastModified: String?

        /// The `If-Range` value: a strong `ETag`, else `Last-Modified` (a weak `ETag` is not
        /// allowed there).
        var validator: String? {
            if let etag, !etag.hasPrefix("W/") { return etag }
            return lastModified
        }
    }

    /// The sidecar at `url`, nil when missing, unsafe, too large or unreadable.
    private static func readRecord(_ url: URL) -> PartialRecord? {
        guard let fd = try? PrivateFile.open(url, flags: O_RDONLY, label: url.path) else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        guard let data = try? handle.read(upToCount: maxRecordBytes + 1), data.count <= maxRecordBytes else { return nil }
        return try? JSONDecoder().decode(PartialRecord.self, from: data)
    }

    /// Opens `url` read-write (0600, never through a symbolic link or a hard link) and locks it
    /// for this download; checks after locking that the name still leads to the locked file (a
    /// download that finished meanwhile renamed it). -1 when it does not exist and `create` is
    /// false; busy when another download holds it.
    private static func openLocked(_ url: URL, create: Bool) throws -> Int32 {
        for _ in 0..<3 {
            let fd: Int32
            do {
                fd = try PrivateFile.open(url, flags: O_RDWR | (create ? O_CREAT | O_EXCL : 0), label: url.path)
            } catch let error as POSIXError where error.code == .ENOENT && !create {
                return -1
            } catch let error as POSIXError where error.code == .EEXIST {
                throw NidoError.downloadFailed(busy(url))
            }
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
                let err = errno
                _ = Darwin.close(fd)
                if err == EWOULDBLOCK { throw NidoError.downloadFailed(busy(url)) }
                throw POSIXError(POSIXErrorCode(rawValue: err) ?? .EIO)
            }
            var opened = stat(), named = stat()
            if fstat(fd, &opened) == 0, lstat(url.path, &named) == 0,
                opened.st_dev == named.st_dev, opened.st_ino == named.st_ino
            {
                return fd
            }
            _ = Darwin.close(fd)
        }
        throw NidoError.downloadFailed(busy(url))
    }

    private static func fileSize(_ fd: Int32) throws -> UInt64 {
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return UInt64(max(0, info.st_size))
    }

    private static func discard(part: URL, record: URL) {
        _ = Darwin.unlink(part.path)
        _ = Darwin.unlink(record.path)
    }

    /// Writes every byte of `data` to `fd` at `offset`, retrying on `EINTR`. Returns `errno` on
    /// failure.
    static func writeAll(_ fd: Int32, _ data: Data, at offset: UInt64) -> Int32? {
        var position = off_t(offset)
        for region in data.regions {
            let err: Int32? = region.withUnsafeBytes { buf in
                guard let base = buf.baseAddress else { return nil }
                var done = 0
                while done < buf.count {
                    let n = pwrite(fd, base + done, buf.count - done, position)
                    if n < 0 {
                        if errno == EINTR { continue }
                        return errno
                    }
                    done += n
                    position += off_t(n)
                }
                return nil
            }
            if let err { return err }
        }
        return nil
    }
}

/// One GET of the image, driven by a per-task `URLSessionDataDelegate` (the shape of
/// `StreamingTransfer`, with ranges): every redirect hop and the final URL must pass the Apple
/// policy; a resumed request carries `Range` and `If-Range` on every hop; the answer must be a
/// 200 or, for a resumed request, a 206 starting where the partial file ends. The body is written
/// at its offset in the file as it arrives, capped at `limit`. The first failure wins.
final class MacImageTransfer: NSObject, URLSessionDataDelegate, Sendable {
    /// A partial file to continue.
    struct Resume: Sendable {
        var offset: UInt64
        /// `If-Range` value.
        var validator: String
        var etag: String?
        var lastModified: String?
        /// The full size, when the earlier answer declared it.
        var expected: UInt64?
    }

    /// The server's answer, before the body.
    struct Response: Sendable {
        /// Offset in the file of the first byte of the body (0 for a 200).
        var start: UInt64
        /// The full size, when declared.
        var total: UInt64?
        var etag: String?
        var lastModified: String?
    }

    struct Outcome: Sendable {
        /// Bytes in the file at the end.
        var total: UInt64
        var expected: UInt64?
    }

    /// A failure after which the partial file cannot be resumed.
    struct DiscardPartial: Error {
        let error: NidoError
    }

    /// 416 to a resumed request; `total` from `Content-Range: bytes */<total>` when given.
    struct RangeNotSatisfiable: Error {
        let total: UInt64?
    }

    private struct State {
        var continuation: CheckedContinuation<Outcome, any Error>?
        var receivedResponse = false
        var failure: (any Error)?
        var start: UInt64 = 0
        var received: UInt64 = 0
        var expected: UInt64?
        var lastReported: UInt64?
    }

    private let url: URL
    private let resume: Resume?
    private let fd: Int32
    private let limit: UInt64
    private let overLimit: NidoError
    private let write: @Sendable (Int32, Data, UInt64) -> Int32?
    private let onResponse: @Sendable (Response) throws -> Void
    private let progress: @Sendable (DownloadProgress) -> Void
    private let state = Mutex(State())

    init(
        url: URL, resume: Resume?, fd: Int32, limit: UInt64, overLimit: NidoError,
        write: @escaping @Sendable (Int32, Data, UInt64) -> Int32?,
        onResponse: @escaping @Sendable (Response) throws -> Void,
        progress: @escaping @Sendable (DownloadProgress) -> Void
    ) {
        self.url = url
        self.resume = resume
        self.fd = fd
        self.limit = limit
        self.overLimit = overLimit
        self.write = write
        self.onResponse = onResponse
        self.progress = progress
    }

    func run(session: URLSession) async throws -> Outcome {
        let task = session.dataTask(with: withRange(URLRequest(url: url)))
        task.delegate = self
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                state.withLock { $0.continuation = continuation }
                task.resume()
            }
        } onCancel: {
            fail(CancellationError())
            task.cancel()
        }
    }

    /// The request for any hop: the bytes as stored (no content coding, so offsets and sizes are
    /// the file's) and, when resuming, the range.
    private func withRange(_ request: URLRequest) -> URLRequest {
        var request = request
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        guard let resume else { return request }
        request.setValue("bytes=\(resume.offset)-", forHTTPHeaderField: "Range")
        request.setValue(resume.validator, forHTTPHeaderField: "If-Range")
        return request
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
            try DownloadPolicy.validateAppleDownload(target)
            completionHandler(withRange(request))
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
            if let finalURL = response.url { try DownloadPolicy.validateAppleDownload(finalURL) }
            guard let http = response as? HTTPURLResponse else {
                throw NidoError.downloadFailed(L10n.string("non-HTTP response for \(url.absoluteString)"))
            }
            let etag = http.value(forHTTPHeaderField: "ETag")
            let lastModified = http.value(forHTTPHeaderField: "Last-Modified")
            let answer: Response
            switch http.statusCode {
            case 206 where resume != nil:
                let resume = resume!
                guard let range = http.value(forHTTPHeaderField: "Content-Range").flatMap(Self.parseContentRange),
                    range.first == resume.offset,
                    range.total == nil || resume.expected == nil || range.total == resume.expected,
                    etag == nil || resume.etag == nil || etag == resume.etag
                else {
                    throw DiscardPartial(error: .downloadFailed(L10n.string(
                        "the server resumed the download at the wrong point: the partial file was deleted, try again")))
                }
                answer = Response(
                    start: resume.offset, total: range.total, etag: etag ?? resume.etag,
                    lastModified: lastModified ?? resume.lastModified)
            case 416 where resume != nil:
                throw RangeNotSatisfiable(
                    total: http.value(forHTTPHeaderField: "Content-Range").flatMap(Self.parseUnsatisfiedRange))
            case 200:
                answer = Response(
                    start: 0, total: response.expectedContentLength > 0 ? UInt64(response.expectedContentLength) : nil,
                    etag: etag, lastModified: lastModified)
            default:
                throw NidoError.downloadFailed(L10n.string("HTTP \(String(http.statusCode)) for \(url.absoluteString)"))
            }
            if let total = answer.total, total > limit { throw overLimit }
            try onResponse(answer)
            state.withLock { s in
                s.receivedResponse = true
                s.start = answer.start
                s.expected = answer.total
                s.lastReported = answer.start
            }
            progress(DownloadProgress(receivedBytes: answer.start, expectedBytes: answer.total))
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
            let position = s.start + s.received
            let end = position + UInt64(data.count)
            guard end <= limit else {
                s.failure = overLimit
                return true
            }
            if let expected = s.expected, end > expected {
                s.failure = NidoError.downloadFailed(L10n.string(
                    "the server sent more than the \(ByteSize.format(expected)) it announced"))
                return true
            }
            if let err = write(fd, data, position) {
                s.failure = POSIXError(POSIXErrorCode(rawValue: err) ?? .EIO)
                return true
            }
            s.received += UInt64(data.count)
            if end - (s.lastReported ?? 0) >= StreamingTransfer.progressStep || end == s.expected {
                s.lastReported = end
                report = DownloadProgress(receivedBytes: end, expectedBytes: s.expected)
            }
            return false
        }
        if failed { dataTask.cancel() }
        if let report { progress(report) }
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
            let total = s.start + s.received
            if s.lastReported != total { final = DownloadProgress(receivedBytes: total, expectedBytes: s.expected) }
            return (continuation, .success(Outcome(total: total, expected: s.expected)))
        }
        if let final { progress(final) }
        continuation?.resume(with: result)
    }

    /// "bytes */200" (the answer of a 416) → 200.
    static func parseUnsatisfiedRange(_ value: String) -> UInt64? {
        let text = value.trimmingCharacters(in: .whitespaces)
        guard text.lowercased().hasPrefix("bytes */") else { return nil }
        return UInt64(text.dropFirst("bytes */".count))
    }

    /// "bytes 100-199/200" → (100, 199, 200); "bytes 100-199/*" → total nil.
    static func parseContentRange(_ value: String) -> (first: UInt64, last: UInt64, total: UInt64?)? {
        let text = value.trimmingCharacters(in: .whitespaces)
        guard text.lowercased().hasPrefix("bytes ") else { return nil }
        let spec = text.dropFirst("bytes ".count)
        let halves = spec.split(separator: "/", omittingEmptySubsequences: false)
        guard halves.count == 2 else { return nil }
        let bounds = halves[0].split(separator: "-", omittingEmptySubsequences: false)
        guard bounds.count == 2, let first = UInt64(bounds[0]), let last = UInt64(bounds[1]), first <= last else {
            return nil
        }
        if halves[1] == "*" { return (first, last, nil) }
        guard let total = UInt64(halves[1]), last < total else { return nil }
        return (first, last, total)
    }
}

/// Refuses a redirect of the size request to a host outside Apple's policy, and remembers why.
private final class HeadRedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    private let failure = Mutex<NidoError?>(nil)

    var refusal: NidoError? { failure.withLock { $0 } }

    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        do {
            guard let target = request.url else { throw NidoError.hostNotAllowed("") }
            try DownloadPolicy.validateAppleDownload(target)
            completionHandler(request)
        } catch {
            failure.withLock { $0 = (error as? NidoError) ?? .hostNotAllowed("") }
            task.cancel()
            completionHandler(nil)
        }
    }
}
