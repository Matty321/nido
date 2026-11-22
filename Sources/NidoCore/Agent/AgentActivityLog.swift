// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation
import ImageIO
import NidoAgentKit
import os
import Synchronization

/// One action an agent asked of a VM's owner, as the activity log keeps it: what (`op` and its
/// parameters in `detail`), for whom (`session`, `client`), when (`time`, UTC, milliseconds), how
/// long (`ms`) and how it ended (`ok`, or `error` and `message`). Never the typed text (`type`
/// keeps only `chars`), never the clipboard (`setClipboard` is not recorded), never a tree's
/// contents (only its size and app), never a file's contents (only its guest path and size, or
/// how many entries a folder listed).
public struct AgentActivityEntry: Codable, Equatable, Sendable {
    /// The format's version, `version`.
    public var v: Int
    public var time: Date
    /// Groups the entries of one agent run (see `AgentGate`).
    public var session: String
    /// `AgentCommand.Client`: `mcp`, `act` or `nido`.
    public var client: String
    /// The protocol's op: `status`, `screenshot`, `zoom`, `uiTree`, `click`, `drag`, `scroll`,
    /// `type`, `key`, `checkpoint`, `rollback`, `checkpoints`, `putFile`, `getFile`, `listFiles`,
    /// and the owner's `rollbackEnd`.
    public var op: String
    /// The op's parameters as strings (`x`, `y`, `button`, `count`, `combo`, `chars`, `region`,
    /// `maxLongEdge`, `maxElements`, `path`, `bytes`, ...) and, for a tree, `elements` and `app`;
    /// for a folder listed, `entries`.
    public var detail: [String: String]
    public var ok: Bool
    /// `AgentErrorCode`'s raw value when `ok` is false.
    public var error: String?
    /// The failure's message, cleaned; nil for an ok answer and for every `type` and `key`.
    public var message: String?
    /// How long the owner took, in milliseconds.
    public var ms: Int
    /// The thumbnail of a screenshot or zoom (`AgentActivityLog.thumbnailURL`).
    public var thumb: String?

    public static let version = 1

    public init(v: Int, time: Date, session: String, client: String, op: String, detail: [String: String], ok: Bool,
                error: String?, message: String?, ms: Int, thumb: String?) {
        self.v = v
        self.time = time
        self.session = session
        self.client = client
        self.op = op
        self.detail = detail
        self.ok = ok
        self.error = error
        self.message = message
        self.ms = ms
        self.thumb = thumb
    }

    private enum CodingKeys: String, CodingKey {
        case v, time, session, client, op, detail, ok, error, message, ms, thumb
    }

    /// `time` is ISO 8601 in UTC with milliseconds (`2027-01-15T08:00:00.123Z`), whatever the
    /// encoder's date strategy.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        v = try c.decode(Int.self, forKey: .v)
        let text = try c.decode(String.self, forKey: .time)
        guard let date = (try? Self.timeStyle.parse(text)) ?? (try? Date.ISO8601FormatStyle().parse(text)) else {
            throw DecodingError.dataCorruptedError(forKey: .time, in: c, debugDescription: "not an ISO 8601 time")
        }
        time = date
        session = try c.decode(String.self, forKey: .session)
        client = try c.decode(String.self, forKey: .client)
        op = try c.decode(String.self, forKey: .op)
        detail = try c.decodeIfPresent([String: String].self, forKey: .detail) ?? [:]
        ok = try c.decode(Bool.self, forKey: .ok)
        error = try c.decodeIfPresent(String.self, forKey: .error)
        message = try c.decodeIfPresent(String.self, forKey: .message)
        ms = try c.decode(Int.self, forKey: .ms)
        thumb = try c.decodeIfPresent(String.self, forKey: .thumb)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(v, forKey: .v)
        try c.encode(time.formatted(Self.timeStyle), forKey: .time)
        try c.encode(session, forKey: .session)
        try c.encode(client, forKey: .client)
        try c.encode(op, forKey: .op)
        try c.encode(detail, forKey: .detail)
        try c.encode(ok, forKey: .ok)
        try c.encodeIfPresent(error, forKey: .error)
        try c.encodeIfPresent(message, forKey: .message)
        try c.encode(ms, forKey: .ms)
        try c.encodeIfPresent(thumb, forKey: .thumb)
    }

    private static let timeStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    // MARK: - From an action

    /// An action as the log names it.
    public struct Description: Equatable, Sendable {
        public var op: String
        public var detail: [String: String]

        public init(op: String, detail: [String: String]) {
            self.op = op
            self.detail = detail
        }
    }

    /// `action`'s op and parameters; nil for `setClipboard`, which is never recorded. `type` keeps
    /// only its length in characters; a key combo, a checkpoint's name and a file's guest path
    /// are cleaned like guest text (the client wrote them). A `putFile` keeps its size in bytes.
    public static func describe(_ action: AgentAction) -> Description? {
        switch action {
        case .status:
            return Description(op: "status", detail: [:])
        case .screenshot(let maxLongEdge):
            return Description(op: "screenshot", detail: ["maxLongEdge": String(maxLongEdge)])
        case .zoom(let x, let y, let width, let height, let maxLongEdge):
            return Description(op: "zoom", detail: [
                "region": [x, y, width, height].map(number).joined(separator: ","),
                "maxLongEdge": String(maxLongEdge),
            ])
        case .uiTree(let maxElements):
            return Description(op: "uiTree", detail: ["maxElements": String(maxElements)])
        case .click(let x, let y, let button, let count):
            return Description(op: "click", detail: [
                "x": number(x), "y": number(y), "button": button.rawValue, "count": String(count),
            ])
        case .drag(let fromX, let fromY, let toX, let toY):
            return Description(op: "drag", detail: [
                "fromX": number(fromX), "fromY": number(fromY), "toX": number(toX), "toY": number(toY),
            ])
        case .scroll(let dx, let dy, let x, let y):
            var detail = ["dx": number(dx), "dy": number(dy)]
            if let x { detail["x"] = number(x) }
            if let y { detail["y"] = number(y) }
            return Description(op: "scroll", detail: detail)
        case .type(let text):
            return Description(op: "type", detail: ["chars": String(text.count)])
        case .key(let combo):
            return Description(op: "key", detail: keyDetail(combo))
        case .setClipboard:
            return nil
        case .checkpoint(let name):
            return Description(op: "checkpoint", detail: nameDetail(name))
        case .rollback(let name):
            return Description(op: "rollback", detail: nameDetail(name))
        case .checkpoints:
            return Description(op: "checkpoints", detail: [:])
        case .putFile(let path, let size):
            return Description(op: "putFile", detail: ["path": pathDetail(path), "bytes": String(size)])
        case .getFile(let path, _):
            return Description(op: "getFile", detail: ["path": pathDetail(path)])
        case .listFiles(let path):
            return Description(op: "listFiles", detail: path.map { ["path": pathDetail($0)] } ?? [:])
        }
    }

    static let maxComboCharacters = 64

    /// The longest guest path a file op keeps, in characters (the log's limit for any detail).
    static let maxPathCharacters = 256

    /// A guest path as the client sent it, cleaned like guest text.
    private static func pathDetail(_ path: String) -> String {
        GuestSSH.sanitize(path, limit: maxPathCharacters)
    }

    /// A checkpoint's name as the client sent it, cleaned like guest text; none when not given.
    private static func nameDetail(_ name: String?) -> [String: String] {
        guard let name else { return [:] }
        return ["name": GuestSSH.sanitize(name, limit: VMName.maxLength)]
    }

    /// A `key` combo as the log keeps it. An agent can enter a password one key at a time, so a
    /// key that types a character (a single character or a key named after one, space included, alone or with
    /// shift) records only `chars: "1"`. A shortcut (cmd, ctrl, option or fn held), a named key
    /// that types no character (return, tab, escape, arrows, delete, F-keys...) or a bare
    /// modifier keeps its combo. A combo the key map cannot name keeps nothing.
    static func keyDetail(_ combo: String) -> [String: String] {
        let tokens = comboTokens(combo)
        guard let key = tokens.last, !key.isEmpty else { return [:] }
        let modifiers = tokens.dropLast().compactMap(KeyMap.modifier(named:))
        guard modifiers.count == tokens.count - 1 else { return [:] }
        let kept = ["combo": GuestSSH.sanitize(combo, limit: maxComboCharacters)]
        if tokens.count == 1, KeyMap.modifier(named: key) != nil { return kept }
        let typesCharacter: Bool
        if let named = KeyMap.named[key.lowercased()] {
            let scalars = named.chars.unicodeScalars
            typesCharacter = scalars.count == 1 && (0x20...0x7E).contains(scalars.first!.value)
        } else if key.count == 1 {
            typesCharacter = true
        } else {
            return [:]
        }
        let shortcut = modifiers.contains { $0 != .shift }
        return typesCharacter && !shortcut ? ["chars": "1"] : kept
    }

    /// `KeyMap`'s split of a combo at `+` (`cmd++` is cmd and `+`), without its modifiers' checks.
    private static func comboTokens(_ input: String) -> [String] {
        var text = input.trimmingCharacters(in: .whitespaces)
        var tokens: [String]
        if text.hasSuffix("++") {
            text.removeLast(2)
            tokens = text.isEmpty ? [] : text.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
            tokens.append("+")
        } else if text == "+" {
            tokens = ["+"]
        } else {
            tokens = text.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        }
        return tokens.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// The entry for `action` answered with `answer` (as the owner built it, before any
    /// cleaning): the guest's text cleaned, a tree reduced to its size and app, the message kept
    /// only for a failure and never for `type` (a helper could echo the text), `time` cut to
    /// milliseconds. Nil for `setClipboard`.
    static func make(action: AgentAction, answer: AgentAnswer, session: String, client: String, time: Date,
                     ms: Int) -> AgentActivityEntry? {
        guard let description = describe(action) else { return nil }
        let cleaned = answer.cleaned
        var detail = description.detail
        if case .uiTree = action, cleaned.ok, let tree = cleaned.tree {
            detail["elements"] = String(tree.elements.count)
            detail["app"] = tree.app
        }
        // The checkpoint saved (its default name included), or the one a rollback goes back to.
        // A file got: its size; a folder listed: how many entries came back. Never contents.
        switch action {
        case .checkpoint, .rollback:
            if cleaned.ok, let checkpoint = cleaned.checkpoint { detail["name"] = checkpoint.name }
        case .getFile:
            if cleaned.ok, let bytes = cleaned.bytes { detail["bytes"] = String(bytes) }
        case .listFiles:
            if cleaned.ok, let files = cleaned.files { detail["entries"] = String(files.count) }
        default:
            break
        }
        var message = cleaned.ok ? nil : cleaned.message
        // Only `type` and `key` carry the agent's text, and their failures can echo it (Nido
        // Agent's "unknown key 'hunter2'", "cannot type 'é'"); the other ops' messages name only
        // numbers, fields or the system's errors.
        switch action {
        case .type, .key: message = nil
        default: break
        }
        let milliseconds = (time.timeIntervalSince1970 * 1000).rounded(.down) / 1000
        return AgentActivityEntry(
            v: version, time: Date(timeIntervalSince1970: milliseconds), session: session, client: client,
            op: description.op, detail: detail, ok: answer.ok, error: answer.error?.rawValue, message: message,
            ms: max(0, ms), thumb: nil)
    }

    /// `100`, `20.5`, `200.25`: whole numbers without a fraction, others with at most two digits.
    static func number(_ value: Double) -> String {
        guard value.isFinite else { return String(value) }
        if value == value.rounded(), abs(value) < 1e15 { return String(Int(value)) }
        var text = String(format: "%.2f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    /// This entry made safe to print and bounded, whoever wrote the file: every string cleaned
    /// like guest text, a thumbnail name that is not one of ours dropped.
    var cleaned: AgentActivityEntry {
        var copy = self
        copy.session = GuestSSH.sanitize(session, limit: 64)
        copy.client = GuestSSH.sanitize(client, limit: 16)
        copy.op = GuestSSH.sanitize(op, limit: 32)
        var cleanDetail: [String: String] = [:]
        for (key, value) in detail.sorted(by: { $0.key < $1.key }).prefix(32) {
            let cleanKey = GuestSSH.sanitize(key, limit: 32)
            guard !cleanKey.isEmpty, cleanDetail[cleanKey] == nil else { continue }
            cleanDetail[cleanKey] = GuestSSH.sanitize(value, limit: 256)
        }
        copy.detail = cleanDetail
        copy.error = error.map { GuestSSH.sanitize($0, limit: 64) }
        copy.message = message.map { GuestSSH.sanitize($0, limit: AgentAnswer.maxMessageCharacters) }
        copy.ms = max(0, ms)
        copy.thumb = thumb.flatMap { AgentActivityLog.isThumbnailName($0) ? $0 : nil }
        return copy
    }
}

/// The one writer of a VM's activity log in its owner: entries are handed over in command order
/// (`AgentGate`, within each command's turn) and appended on a serial queue of their own, so no
/// answer waits for the disk (a thumbnail, an `fsync`, a rotation) and the order is kept. A
/// failure is reported to the system log once and never reaches the agent.
final class AgentActivityWriter: Sendable {
    typealias Append = @Sendable (AgentActivityEntry, Data?) throws -> Void

    private let queue = DispatchQueue(label: "io.gitlab.pichierri.Nido.agent-log", qos: .utility)
    private let append: Append
    private let vmName: String
    private let failureReported = Mutex(false)
    /// Entries queued and not yet written.
    private let pending = Mutex(0)

    /// Past this many entries waiting, a new one is queued without its PNG (no thumbnail): a
    /// writer stalled on the disk never holds more than this many screenshots in memory.
    static let maxPendingThumbnails = 50

    init(vmName: String, append: @escaping Append) {
        self.vmName = vmName
        self.append = append
    }

    /// The writer of `bundle`'s log (`AgentActivityLog.append`).
    convenience init(bundle: VMBundle, vmName: String) {
        self.init(vmName: vmName, append: { try AgentActivityLog.append($0, thumbnailPNG: $1, in: bundle) })
    }

    /// Queues `entry` and its screenshot's `png` (for the thumbnail) after the ones before it;
    /// the PNG is dropped when `maxPendingThumbnails` entries are already waiting.
    func enqueue(_ entry: AgentActivityEntry, png: Data?) {
        let waiting = pending.withLock { count -> Int in
            defer { count += 1 }
            return count
        }
        let png = waiting < Self.maxPendingThumbnails ? png : nil
        queue.async { [self] in
            defer { pending.withLock { $0 -= 1 } }
            do {
                try append(entry, png)
            } catch {
                let first = failureReported.withLock { reported -> Bool in
                    defer { reported = true }
                    return !reported
                }
                guard first else { return }
                Logger(subsystem: "io.gitlab.pichierri.Nido", category: "agent-log").error(
                    "could not write the agent activity log of \(self.vmName, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Returns once every entry queued before the call is written (or failed).
    func flush() {
        queue.sync {}
    }
}

/// The activity log of a VM: `<bundle>/agent-log/` (0700), one JSON line per entry in
/// `agent-log.jsonl`, rotated to `agent-log.1.jsonl` past `maxFileBytes` (two files at most), and
/// the JPEG thumbnails of screenshots and zooms in `thumbs/` (0700), deleted when no entry of the
/// two files names them any more, and never more than `maxThumbnails`. Every file is 0600 and
/// opened without following a symlink (`PrivateFile`); a symlink in place of a folder is refused.
///
/// One writer, the VM's owner (`AgentGate`), which appends one entry at a time; readers (`nido
/// agent log`, the app) skip any line they cannot decode, such as one cut by a crash.
public enum AgentActivityLog {
    /// The size past which `agent-log.jsonl` becomes `agent-log.1.jsonl`.
    public static let maxFileBytes = 2 << 20
    /// The most thumbnails kept: an agent that takes screenshots for hours keeps the newest.
    public static let maxThumbnails = 1000
    /// The thumbnails' long edge, in pixels, and their JPEG quality.
    static let thumbnailLongEdge = 320
    static let thumbnailQuality = 0.7
    /// The most a reader takes of one file: a file grown by hand is read from its end.
    static let maxReadBytes = 8 << 20

    static let currentName = "agent-log.jsonl"
    static let previousName = "agent-log.1.jsonl"
    static let thumbsName = "thumbs"

    /// Appends `entry` (and, from `thumbnailPNG`, its thumbnail) to `bundle`'s log, rotating it
    /// first when the line would take it past `maxFileBytes`. The line is written whole with one
    /// `write(2)`; after a line cut by a crash it starts on a line of its own. A PNG that cannot
    /// be read, or a thumbnail that cannot be saved, leaves the entry without one. Throws
    /// `.unsafePath` for a symlink or another file in place of the folder or the log.
    public static func append(_ entry: AgentActivityEntry, thumbnailPNG: Data?, in bundle: VMBundle) throws {
        try append(entry, thumbnailPNG: thumbnailPNG, in: bundle, maxThumbnails: maxThumbnails)
    }

    /// `append` with the thumbnail limit injectable (tests).
    static func append(_ entry: AgentActivityEntry, thumbnailPNG: Data?, in bundle: VMBundle,
                       maxThumbnails: Int) throws {
        let directory = bundle.agentLogURL
        try ensureDirectory(directory)
        var entry = entry
        if let thumbnailPNG {
            entry.thumb = try? writeThumbnail(thumbnailPNG, in: directory, keep: maxThumbnails)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var line = try encoder.encode(entry)
        line.append(0x0A)

        let current = directory.appendingPathComponent(currentName)
        var fd = try PrivateFile.open(current, flags: O_RDWR | O_CREAT | O_APPEND, label: currentName)
        defer { _ = Darwin.close(fd) }
        var size = try fileSize(fd)
        if size > 0, size + line.count > maxFileBytes {
            _ = Darwin.close(fd)
            fd = -1
            guard Darwin.rename(current.path, directory.appendingPathComponent(previousName).path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            pruneThumbnails(in: directory, keeping: entry.thumb)
            fd = try PrivateFile.open(current, flags: O_RDWR | O_CREAT | O_APPEND, label: currentName)
            size = try fileSize(fd)
        }
        if size > 0 {
            // A line cut by a crash: end it, so this one is read.
            var last: UInt8 = 0
            if pread(fd, &last, 1, off_t(size - 1)) == 1, last != 0x0A { line.insert(0x0A, at: 0) }
        }
        try line.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                offset += n
            }
        }
    }

    /// The entries of `bundle`'s log, oldest first, the last `limit` of them when given; lines that
    /// are not an entry are skipped, and what is returned is cleaned (`AgentActivityEntry.cleaned`).
    /// No log: empty. Throws `.unsafePath` for a symlink in place of the folder or a file.
    public static func read(in bundle: VMBundle, limit: Int?) throws -> [AgentActivityEntry] {
        let directory = bundle.agentLogURL
        guard try existingDirectory(directory) else { return [] }
        var entries = try readFile(directory.appendingPathComponent(previousName))
        entries += try readFile(directory.appendingPathComponent(currentName))
        if let limit { entries = Array(entries.suffix(max(0, limit))) }
        return entries
    }

    /// Deletes `bundle`'s log and thumbnails. A symlink in place of the folder is removed, never
    /// what it points to. Nothing there: nothing to do.
    public static func clear(in bundle: VMBundle) throws {
        try clear(in: bundle) { try FileManager.default.removeItem(at: $0) }
    }

    /// `clear` with the folder's removal injectable (tests). The owner may write a new file into
    /// the folder while it is being removed (ENOTEMPTY): the removal is tried once more.
    static func clear(in bundle: VMBundle, remove: (URL) throws -> Void) throws {
        let directory = bundle.agentLogURL
        var info = stat()
        guard lstat(directory.path, &info) == 0 else {
            guard errno == ENOENT else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            return
        }
        guard (info.st_mode & S_IFMT) == S_IFDIR else {
            guard Darwin.unlink(directory.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            return
        }
        // Removes links inside as links, never following them.
        do {
            try remove(directory)
        } catch where isNotEmpty(error) {
            try remove(directory)
        }
    }

    /// ENOTEMPTY, as `removeItem` reports it (a Cocoa error with the POSIX one underneath) or plain.
    private static func isNotEmpty(_ error: any Error) -> Bool {
        let error = error as NSError
        if error.domain == NSPOSIXErrorDomain { return error.code == Int(ENOTEMPTY) }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            return underlying.domain == NSPOSIXErrorDomain && underlying.code == Int(ENOTEMPTY)
        }
        return false
    }

    /// The file of the thumbnail `name`, as an entry `read` returned names it. Another name gives
    /// a path where no thumbnail is.
    public static func thumbnailURL(_ name: String, in bundle: VMBundle) -> URL {
        bundle.agentLogURL.appendingPathComponent(thumbsName, isDirectory: true)
            .appendingPathComponent(isThumbnailName(name) ? name : "invalid")
    }

    /// The most a thumbnail file may hold: ours are 10–25 KB.
    public static let maxThumbnailBytes = 1 << 20

    /// The bytes of the thumbnail `name`, read like the log itself: only a name this log gives, in a
    /// real `thumbs/` folder of a real `agent-log/` folder, a regular file of this user that is no
    /// symlink and opens without blocking (`PrivateFile`), at most `maxThumbnailBytes`. Anything
    /// else, or no file: nil.
    public static func thumbnailData(_ name: String, in bundle: VMBundle) -> Data? {
        guard isThumbnailName(name) else { return nil }
        let thumbs = bundle.agentLogURL.appendingPathComponent(thumbsName, isDirectory: true)
        guard (try? existingDirectory(bundle.agentLogURL)) == true, (try? existingDirectory(thumbs)) == true,
            let fd = try? PrivateFile.open(thumbs.appendingPathComponent(name), flags: O_RDONLY, label: name)
        else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        guard let size = try? fileSize(fd), size <= maxThumbnailBytes,
            let data = try? handle.read(upToCount: maxThumbnailBytes + 1), data.count <= maxThumbnailBytes
        else { return nil }
        return data
    }

    // MARK: - Thumbnails

    /// A JPEG of `png` at most `thumbnailLongEdge` pixels on its long edge; nil when `png` is no image.
    static func thumbnailJPEG(_ png: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailLongEdge,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(
            destination, image, [kCGImageDestinationLossyCompressionQuality: thumbnailQuality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// Saves the thumbnail of `png` in `<directory>/thumbs/` and deletes all but the newest
    /// `keep`; returns its name, or nil when `png` is no image. Names are the time in nanoseconds,
    /// zero-padded, bumped past the newest one there (as `AgentShots` does).
    private static func writeThumbnail(_ png: Data, in directory: URL, keep: Int) throws -> String? {
        guard let jpeg = thumbnailJPEG(png) else { return nil }
        let thumbs = directory.appendingPathComponent(thumbsName, isDirectory: true)
        try ensureDirectory(thumbs)
        var existing = try thumbnails(in: thumbs)
        var stamp = clock_gettime_nsec_np(CLOCK_REALTIME)
        if let newest = existing.last, stamp <= newest.stamp { stamp = newest.stamp + 1 }
        let name = thumbnailName(stamp)
        try PrivateFile.writeAtomically(jpeg, to: thumbs.appendingPathComponent(name))
        existing.append((stamp, name))
        for old in existing.dropLast(max(0, keep)) {
            _ = Darwin.unlink(thumbs.appendingPathComponent(old.name).path)
        }
        return name
    }

    /// After a rotation: deletes the thumbnails no entry of `agent-log.1.jsonl` names, but
    /// `keeping` (the entry being written). Nothing is deleted when that file cannot be read.
    private static func pruneThumbnails(in directory: URL, keeping: String?) {
        let thumbs = directory.appendingPathComponent(thumbsName, isDirectory: true)
        guard (try? existingDirectory(thumbs)) == true,
            let entries = try? readFile(directory.appendingPathComponent(previousName)),
            let names = try? thumbnails(in: thumbs)
        else { return }
        var referenced = Set(entries.compactMap(\.thumb))
        if let keeping { referenced.insert(keeping) }
        for thumb in names where !referenced.contains(thumb.name) {
            _ = Darwin.unlink(thumbs.appendingPathComponent(thumb.name).path)
        }
    }

    private static func thumbnailName(_ stamp: UInt64) -> String {
        let digits = String(stamp)
        return String(repeating: "0", count: max(0, 20 - digits.count)) + digits + ".jpg"
    }

    /// Twenty digits and `.jpg`: a name this log gave, never a path.
    static func isThumbnailName(_ name: String) -> Bool {
        guard name.utf8.count == 24, name.hasSuffix(".jpg"), let stamp = UInt64(name.prefix(20)) else { return false }
        return thumbnailName(stamp) == name
    }

    /// The thumbnails in `directory`, oldest first; anything else there is left alone.
    private static func thumbnails(in directory: URL) throws -> [(stamp: UInt64, name: String)] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .compactMap { name -> (stamp: UInt64, name: String)? in
                guard isThumbnailName(name), let stamp = UInt64(name.prefix(20)) else { return nil }
                return (stamp, name)
            }
            .sorted { $0.stamp < $1.stamp }
    }

    // MARK: - Files

    /// Creates `url` 0700 when missing; a symlink or a file in its place is refused before
    /// anything is changed through it.
    private static func ensureDirectory(_ url: URL) throws {
        _ = try existingDirectory(url)
        try PrivateDirectory.ensure(url)
        guard try existingDirectory(url) else { throw NidoError.unsafePath(url.path) }
    }

    /// True for a real directory at `url`, false for nothing there; `.unsafePath` for anything else.
    private static func existingDirectory(_ url: URL) throws -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            guard errno == ENOENT else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            return false
        }
        guard (info.st_mode & S_IFMT) == S_IFDIR else { throw NidoError.unsafePath(url.path) }
        return true
    }

    private static func fileSize(_ fd: Int32) throws -> Int {
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return Int(info.st_size)
    }

    /// The entries of one log file, oldest first (at most its last `maxReadBytes`); missing: none.
    private static func readFile(_ url: URL) throws -> [AgentActivityEntry] {
        let fd: Int32
        do {
            fd = try PrivateFile.open(url, flags: O_RDONLY, label: url.lastPathComponent)
        } catch let error as POSIXError where error.code == .ENOENT {
            return []
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        let size = try fileSize(fd)
        var skipFirstLine = false
        if size > maxReadBytes {
            try handle.seek(toOffset: UInt64(size - maxReadBytes))
            skipFirstLine = true
        }
        let data = try handle.readToEnd() ?? Data()
        try handle.close()
        let decoder = JSONDecoder()
        var lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        if skipFirstLine, !lines.isEmpty { lines.removeFirst() }
        return lines.compactMap { line in
            guard let entry = try? decoder.decode(AgentActivityEntry.self, from: Data(line)),
                entry.v >= AgentActivityEntry.version
            else { return nil }
            return entry.cleaned
        }
    }
}
