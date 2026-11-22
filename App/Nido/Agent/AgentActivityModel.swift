// SPDX-License-Identifier: Apache-2.0
import Foundation
import NidoCore
import Observation

/// The Agent Activity panel of a VM: what agents did in it (`AgentActivityLog`), grouped by
/// session, the session with the newest action first and, in each, the newest action first. The
/// log is read off the main actor; while the panel is shown, `watch` looks at the size of the log's
/// files every second and reads it again when they changed. Typed text is never in the log (only
/// its length), and nothing here shows a field the log does not define.
@MainActor
@Observable
final class AgentActivityModel {
    struct Row: Identifiable, Equatable {
        /// From the entry's content (session, time, op, duration, and which of identical entries
        /// it is), never its position: a row keeps its identity when new entries arrive.
        let id: String
        /// SF Symbol of the action.
        let symbol: String
        let time: String
        /// One line, in the app's language: "Click at 120, 340", "12 characters typed".
        let text: String
        let ok: Bool
        /// "OK" or "Failed".
        let outcome: String
        /// A failure's code and, when the log has one, its message (`permissionMissing: …`).
        let failure: String?
        let duration: String
        /// A screenshot or a zoom: the row has a thumbnail, or its placeholder.
        let showsThumbnail: Bool
        /// The thumbnail's name in the log; the view reads it (`thumbnailData`) only while the row
        /// is on screen. nil, or a file no longer kept, draws the placeholder.
        let thumbnail: String?
    }

    struct Session: Identifiable, Equatable {
        /// The session's id as the log writes it.
        let id: String
        /// Who acted: "Agent via MCP", "nido act".
        let client: String
        /// The id's first 8 characters, as `nido agent log` prints them.
        let shortID: String
        /// When its first action shown here ran (day, month and time).
        let started: String
        /// "3 actions".
        let countText: String
        /// Newest first.
        let rows: [Row]
    }

    /// The most entries read and shown: the newest ones.
    nonisolated static let maxEntries = 1000

    let name: String
    private(set) var sessions: [Session] = []
    /// The log could not be read or cleared.
    var errorMessage: String? { clearError ?? readError }
    /// "Clear…" was pressed: the confirmation is shown.
    private(set) var isConfirmingClear = false
    private(set) var isClearing = false
    /// The log holds more entries than are shown.
    private(set) var isLimited = false

    private var readError: String?
    private var clearError: String?

    @ObservationIgnored private let bundle: VMBundle
    @ObservationIgnored private let limit: Int
    @ObservationIgnored private let timeZone: TimeZone
    /// Built once per model (the time zone never changes): a `DateFormatter` is costly to make.
    @ObservationIgnored private let rowTime: DateFormatter
    @ObservationIgnored private let dayTime: DateFormatter
    @ObservationIgnored private let clearLog: @Sendable (VMBundle) throws -> Void
    @ObservationIgnored private var entries: [AgentActivityEntry] = []
    /// The log's files as last read (`signature`): `watch` reads again only when it changes.
    @ObservationIgnored private var lastSignature: Signature?
    /// Counts the reads started: a read that ends after a newer one started is dropped.
    @ObservationIgnored private var generation = 0

    init(
        bundle: VMBundle, name: String, limit: Int = AgentActivityModel.maxEntries, timeZone: TimeZone = .current,
        clearLog: @escaping @Sendable (VMBundle) throws -> Void = { try AgentActivityLog.clear(in: $0) }
    ) {
        self.bundle = bundle
        self.name = name
        self.limit = max(1, limit)
        self.timeZone = timeZone
        self.rowTime = Self.formatter(template: "jjmmss", timeZone: timeZone)
        self.dayTime = Self.formatter(template: "ddMMjjmmss", timeZone: timeZone)
        self.clearLog = clearLog
    }

    var isEmpty: Bool { sessions.isEmpty }

    /// Under the list when only the newest entries are shown.
    var limitText: String? {
        guard isLimited else { return nil }
        return String(localized: "Only the latest \(limit) actions are shown.")
    }

    var clearQuestion: String {
        String(localized: "Clear the agent activity of \(name)?", comment: "%@ is the VM’s name.")
    }

    // MARK: - Reading

    /// Reads the log again.
    func refresh() async {
        generation += 1
        let current = generation
        let (bundle, limit) = (bundle, limit)
        let read = await Task.detached { () -> Read in
            let signature = Self.signature(of: bundle)
            do {
                let entries = try AgentActivityLog.read(in: bundle, limit: limit + 1)
                return Read(signature: signature, result: .success(entries))
            } catch {
                return Read(signature: signature, result: .failure(error))
            }
        }.value
        guard current == generation else { return }
        lastSignature = read.signature
        switch read.result {
        case .success(let all):
            let limited = all.count > limit
            let shown = Array(all.suffix(limit))
            if readError != nil { readError = nil }
            if limited != isLimited { isLimited = limited }
            if shown != entries {
                entries = shown
                rebuild()
            }
        case .failure(let error):
            readError = String(localized: "Can’t read the agent activity log: \(error.localizedDescription)")
        }
    }

    /// The bytes of a row's thumbnail, read off the main actor the way the log is read (no
    /// symlink, no FIFO, at most `AgentActivityLog.maxThumbnailBytes`); nil when it is not kept.
    func thumbnailData(_ name: String) async -> Data? {
        let bundle = bundle
        return await Task.detached { AgentActivityLog.thumbnailData(name, in: bundle) }.value
    }

    /// Looks at the log's files every `interval` and reads the log when they changed, until the
    /// task is cancelled (the panel goes away).
    func watch(interval: Duration = .seconds(1)) async {
        while !Task.isCancelled {
            let bundle = bundle
            let signature = await Task.detached { Self.signature(of: bundle) }.value
            if lastSignature == nil || signature != lastSignature { await refresh() }
            try? await Task.sleep(for: interval)
        }
    }

    private struct Read: Sendable {
        let signature: Signature
        let result: Result<[AgentActivityEntry], any Error>
    }

    /// The size and modification time of the log's two files (nil when missing): an append, a
    /// rotation or a clear changes it.
    struct Signature: Equatable, Sendable {
        var current: [Int64]?
        var previous: [Int64]?
    }

    nonisolated static func signature(of bundle: VMBundle) -> Signature {
        func stamp(_ name: String) -> [Int64]? {
            var info = stat()
            let path = bundle.agentLogURL.appendingPathComponent(name).path
            guard lstat(path, &info) == 0 else { return nil }
            return [Int64(info.st_size), Int64(info.st_mtimespec.tv_sec), Int64(info.st_mtimespec.tv_nsec),
                    Int64(info.st_ino)]
        }
        return Signature(current: stamp("agent-log.jsonl"), previous: stamp("agent-log.1.jsonl"))
    }

    private func rebuild() {
        // Per session: its entries (oldest first) and the index of its newest one.
        var order: [String] = []
        var grouped: [String: (rows: [Row], last: Int, first: AgentActivityEntry)] = [:]
        var seen: [String: Int] = [:]
        for (index, entry) in entries.enumerated() {
            let key = "\(entry.session)|\(entry.time.timeIntervalSince1970)|\(entry.op)|\(entry.ms)"
            let occurrence = seen[key, default: 0]
            seen[key] = occurrence + 1
            let row = row(entry, id: "\(key)#\(occurrence)", time: rowTime.string(from: entry.time))
            if var group = grouped[entry.session] {
                group.rows.append(row)
                group.last = index
                grouped[entry.session] = group
            } else {
                order.append(entry.session)
                grouped[entry.session] = ([row], index, entry)
            }
        }
        sessions = order.compactMap { id -> (Session, Int)? in
            guard let group = grouped[id] else { return nil }
            let session = Session(
                id: id, client: Self.clientText(group.first.client), shortID: String(id.prefix(8)),
                started: dayTime.string(from: group.first.time),
                countText: String(localized: "\(group.rows.count) actions"), rows: group.rows.reversed())
            return (session, group.last)
        }
        .sorted { $0.1 > $1.1 }
        .map(\.0)
    }

    private func row(_ entry: AgentActivityEntry, id: String, time: String) -> Row {
        let hasThumbnail = entry.op == "screenshot" || entry.op == "zoom"
        let thumbnail = hasThumbnail ? entry.thumb : nil
        var failure: String?
        if !entry.ok {
            let code = entry.error ?? "error"
            // The log keeps no message for `type` and `key` (it could echo the text); one in a
            // line written by hand is not shown either.
            let message = entry.op == "type" || entry.op == "key" ? nil : entry.message
            failure = message.map { "\(code): \($0)" } ?? code
        }
        return Row(
            id: id, symbol: Self.symbol(for: entry.op, detail: entry.detail),time: time, text: Self.text(for: entry), ok: entry.ok,
            outcome: entry.ok ? String(localized: "OK") : String(localized: "Failed"), failure: failure,
            duration: "\(entry.ms) ms", showsThumbnail: hasThumbnail, thumbnail: thumbnail)
    }

    static func formatter(template: String, timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter
    }

    // MARK: - Texts

    /// Who acted, as the session's heading says it.
    static func clientText(_ client: String) -> String {
        switch client {
        case "mcp": String(localized: "Agent via MCP")
        case "act": "nido act"
        case "nido": "Nido"
        default: client
        }
    }

    /// The action in one line. Only the fields the log defines for each op are used: `type`
    /// (and a `key` that types a character) is a count, never text.
    static func text(for entry: AgentActivityEntry) -> String {
        let detail = entry.detail
        switch entry.op {
        case "status":
            return String(localized: "Status check")
        case "screenshot":
            return String(localized: "Screenshot")
        case "zoom":
            let parts = (detail["region"] ?? "").split(separator: ",").map(String.init)
            guard parts.count == 4 else { return String(localized: "Zoom") }
            return String(localized: "Zoom on \(parts[0]), \(parts[1]) (\(parts[2]) × \(parts[3]))",
                          comment: "The zoomed region: its top-left corner (x, y), then its width and height.")
        case "uiTree":
            guard let count = detail["elements"].flatMap(Int.init) else { return String(localized: "UI tree") }
            if let app = detail["app"], !app.isEmpty {
                return String(localized: "UI tree of \(app): \(count) elements", comment: "%@ is an app’s name.")
            }
            return String(localized: "UI tree: \(count) elements")
        case "click":
            let (x, y) = (detail["x"] ?? "?", detail["y"] ?? "?")
            let count = detail["count"] ?? "1"
            if detail["button"] == "right" {
                return count == "1"
                    ? String(localized: "Right-click at \(x), \(y)")
                    : String(localized: "Right-click ×\(count) at \(x), \(y)", comment: "How many clicks, then x and y.")
            }
            switch count {
            case "1": return String(localized: "Click at \(x), \(y)")
            case "2": return String(localized: "Double-click at \(x), \(y)")
            default: return String(localized: "Click ×\(count) at \(x), \(y)", comment: "How many clicks, then x and y.")
            }
        case "drag":
            return String(localized: "Drag from \(detail["fromX"] ?? "?"), \(detail["fromY"] ?? "?") to \(detail["toX"] ?? "?"), \(detail["toY"] ?? "?")")
        case "scroll":
            let (dx, dy) = (detail["dx"] ?? "0", detail["dy"] ?? "0")
            if let x = detail["x"], let y = detail["y"] {
                return String(localized: "Scroll by \(dx), \(dy) at \(x), \(y)", comment: "The scroll amounts, then x and y.")
            }
            return String(localized: "Scroll by \(dx), \(dy)")
        case "type":
            return typed(detail["chars"])
        case "key":
            if let combo = detail["combo"], !combo.isEmpty {
                return String(localized: "Key \(combo)", comment: "A key or a shortcut pressed: cmd+a, return.")
            }
            if detail["chars"] != nil { return typed(detail["chars"]) }
            return String(localized: "Key press")
        case "checkpoint":
            guard let name = detail["name"], !name.isEmpty else { return String(localized: "Checkpoint") }
            return String(localized: "Checkpoint \(name)", comment: "An agent saved the VM as a checkpoint: its name.")
        case "rollback":
            guard let name = detail["name"], !name.isEmpty else {
                return String(localized: "Back to the newest checkpoint", comment: "An agent rolled the VM back.")
            }
            return String(localized: "Back to checkpoint \(name)", comment: "An agent rolled the VM back: the checkpoint’s name.")
        case "checkpoints":
            return String(localized: "Checkpoint list", comment: "An agent listed its checkpoints.")
        case "rollbackEnd":
            return String(localized: "End of the rollback to \(detail["name"] ?? "?")",
                          comment: "Nido restarted the VM from an agent’s checkpoint (or failed to): the checkpoint’s name.")
        case "putFile":
            guard let path = detail["path"], !path.isEmpty else {
                return String(localized: "File to the VM", comment: "An agent copied a file into the VM’s NidoTransfer folder.")
            }
            guard let size = size(detail["bytes"]) else {
                return String(localized: "File to the VM: \(path)", comment: "An agent copied a file into the VM: its path in NidoTransfer.")
            }
            return String(localized: "File to the VM: \(path) (\(size))",
                          comment: "An agent copied a file into the VM: its path in NidoTransfer, then its size.")
        case "getFile":
            guard let path = detail["path"], !path.isEmpty else {
                return String(localized: "File from the VM", comment: "An agent copied a file out of the VM’s NidoTransfer folder.")
            }
            guard let size = size(detail["bytes"]) else {
                return String(localized: "File from the VM: \(path)", comment: "An agent copied a file out of the VM: its path in NidoTransfer.")
            }
            return String(localized: "File from the VM: \(path) (\(size))",
                          comment: "An agent copied a file out of the VM: its path in NidoTransfer, then its size.")
        case "listFiles":
            // Without a path the agent listed the folder itself.
            let folder = detail["path"].flatMap { $0.isEmpty ? nil : $0 } ?? "NidoTransfer"
            guard let count = detail["entries"].flatMap(Int.init) else {
                return String(localized: "File list of \(folder)", comment: "An agent listed a folder of NidoTransfer in the VM: its path.")
            }
            return String(localized: "Files in \(folder): \(count) entries",
                          comment: "An agent listed a folder of NidoTransfer in the VM: its path, then how many entries.")
        default:
            return entry.op
        }
    }

    /// A file's size as the log records it (`bytes`), as the app shows sizes; nil when missing.
    private static func size(_ bytes: String?) -> String? {
        bytes.flatMap(UInt64.init).map { ByteSize.text($0) }
    }

    private static func typed(_ chars: String?) -> String {
        let count = chars.flatMap(Int.init) ?? 0
        return String(localized: "\(count) characters typed")
    }

    /// A key that types a character (logged as `chars`, no `combo`) reads as typing, so it gets the
    /// keyboard, not the command key.
    static func symbol(for op: String, detail: [String: String] = [:]) -> String {
        if op == "key", detail["combo"] == nil, detail["chars"] != nil { return "keyboard" }
        return switch op {
        case "status": "info.circle"
        case "screenshot": "camera.viewfinder"
        case "zoom": "plus.magnifyingglass"
        case "uiTree": "list.bullet.indent"
        case "click": "cursorarrow.click"
        case "drag": "hand.draw"
        case "scroll": "arrow.up.and.down"
        case "type": "keyboard"
        case "key": "command"
        case "checkpoint": "bookmark"
        case "rollback": "arrow.uturn.backward"
        case "checkpoints": "list.bullet"
        case "rollbackEnd": "arrow.uturn.backward.circle"
        case "putFile": "square.and.arrow.down"
        case "getFile": "square.and.arrow.up"
        case "listFiles": "folder"
        default: "questionmark.circle"
        }
    }

    // MARK: - Clear

    /// "Clear…": asks first.
    func requestClear() { isConfirmingClear = true }

    func cancelClear() { isConfirmingClear = false }

    /// Deletes the log and its thumbnails, only after `requestClear`.
    func clear() async {
        guard isConfirmingClear, !isClearing else { return }
        isConfirmingClear = false
        clearError = nil
        isClearing = true
        defer { isClearing = false }
        let (bundle, clearLog) = (bundle, clearLog)
        let result = await Task.detached { Result { try clearLog(bundle) } }.value
        if case .failure(let error) = result {
            clearError = String(localized: "Can’t clear the agent activity log: \(error.localizedDescription)")
            return
        }
        await refresh()
    }

    func dismissError() {
        clearError = nil
        readError = nil
    }
}
