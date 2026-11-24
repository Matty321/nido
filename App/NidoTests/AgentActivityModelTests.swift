// SPDX-License-Identifier: Apache-2.0
import CoreGraphics
import Foundation
import ImageIO
import NidoCore
import Testing

@testable import Nido

/// The Agent Activity panel's model: sessions newest first, one line per action in the app's
/// language (the tests run in Italian), the live refresh and "Clear" after its confirmation.
@MainActor
struct AgentActivityModelTests {
    /// 15 Jan 2027, 08:00:00 UTC.
    nonisolated static let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    nonisolated static let utc = TimeZone(identifier: "UTC")!

    private struct Fixture {
        let bundle: VMBundle
        let root: URL

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("nido-activity-\(UUID().uuidString)", isDirectory: true)
            let config = VMConfig(
                id: UUID(), name: try VMName("macos-agenti"), guest: .macos, cpuCount: 4,
                memoryBytes: UInt64(8) << 30, diskBytes: UInt64(64) << 30, macAddress: "52:54:00:12:34:57",
                sshUser: "agente", osVersion: "26.6")
            bundle = try VMBundle.create(config: config, paths: NidoPaths(root: root))
        }

        func append(_ entry: AgentActivityEntry, png: Data? = nil) throws {
            try AgentActivityLog.append(entry, thumbnailPNG: png, in: bundle)
        }

        @MainActor func model(limit: Int = AgentActivityModel.maxEntries) -> AgentActivityModel {
            AgentActivityModel(bundle: bundle, name: "macos-agenti", limit: limit, timeZone: AgentActivityModelTests.utc)
        }

        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }

    private func entry(
        _ op: String, _ detail: [String: String] = [:], session: String = "aaaaaaaa-1111", client: String = "mcp",
        at seconds: Double = 0, ok: Bool = true, error: String? = nil, message: String? = nil, ms: Int = 120,
        thumb: String? = nil
    ) -> AgentActivityEntry {
        AgentActivityEntry(
            v: AgentActivityEntry.version, time: Self.t0.addingTimeInterval(seconds), session: session, client: client,
            op: op, detail: detail, ok: ok, error: error, message: message, ms: ms, thumb: thumb)
    }

    // MARK: - Sessions

    @Test func groupsSessionsNewestFirst() async throws {
        let fx = try Fixture(); defer { fx.cleanup() }
        try fx.append(entry("screenshot", ["maxLongEdge": "1280"], session: "aaaaaaaa-1111", at: 0))
        try fx.append(entry("click", ["x": "1", "y": "2", "button": "left", "count": "1"], session: "aaaaaaaa-1111", at: 1))
        try fx.append(entry("status", session: "bbbbbbbb-2222", client: "act", at: 2))
        try fx.append(entry("type", ["chars": "3"], session: "bbbbbbbb-2222", client: "act", at: 3))
        let model = fx.model()
        await model.refresh()

        // The session with the newest action first; in each, the newest action first.
        #expect(model.sessions.map(\.id) == ["bbbbbbbb-2222", "aaaaaaaa-1111"])
        #expect(model.sessions[0].rows.map(\.text) == ["3 caratteri digitati", "Controllo dello stato"])
        #expect(model.sessions[1].rows.map(\.text) == ["Clic su 1, 2", "Screenshot"])
        #expect(model.sessions[0].client == "nido act")
        #expect(model.sessions[1].client == "Agente via MCP")
        #expect(model.sessions[0].shortID == "bbbbbbbb")
        #expect(model.sessions[0].countText == "2 azioni")
        #expect(model.sessions[1].rows.first?.time == "08:00:01")

        // An older session that acts again comes back to the top.
        try fx.append(entry("key", ["combo": "cmd+a"], session: "aaaaaaaa-1111", at: 4))
        await model.refresh()
        #expect(model.sessions.map(\.id) == ["aaaaaaaa-1111", "bbbbbbbb-2222"])
        #expect(model.sessions[0].rows.map(\.text) == ["Tasto cmd+a", "Clic su 1, 2", "Screenshot"])
        #expect(model.sessions[0].countText == "3 azioni")
        #expect(!model.isEmpty)
    }

    @Test func noLogIsEmpty() async throws {
        let fx = try Fixture(); defer { fx.cleanup() }
        let model = fx.model()
        await model.refresh()
        #expect(model.sessions.isEmpty)
        #expect(model.isEmpty)
        #expect(model.errorMessage == nil)
    }

    // MARK: - One line per action

    @Test func describesEachAction() {
        let cases: [(AgentActivityEntry, String)] = [
            (entry("status"), "Controllo dello stato"),
            (entry("screenshot", ["maxLongEdge": "1280"]), "Screenshot"),
            (entry("zoom", ["region": "10,20,300,200", "maxLongEdge": "1280"]), "Zoom su 10, 20 (300 × 200)"),
            (entry("zoom", ["region": "garbage"]), "Zoom"),
            (entry("uiTree", ["maxElements": "200", "elements": "42", "app": "Safari"]),
             "Albero dell’interfaccia di Safari: 42 elementi"),
            (entry("uiTree", ["maxElements": "200", "elements": "1"]), "Albero dell’interfaccia: 1 elemento"),
            (entry("uiTree", ["maxElements": "200"], ok: false, error: "permissionMissing"), "Albero dell’interfaccia"),
            (entry("readText", ["region": "0,0,100,50", "lines": "12"]), "Lettura del testo: 12 righe"),
            (entry("readText", ["lines": "1"]), "Lettura del testo: 1 riga"),
            (entry("readText", [:], ok: false, error: "noScreenshot"), "Lettura del testo"),
            (entry("readClipboard", ["chars": "12"]), "Appunti letti: 12 caratteri"),
            (entry("readClipboard", ["chars": "1"]), "Appunti letti: 1 carattere"),
            (entry("readClipboard", [:], ok: false, error: "badRequest"), "Appunti letti"),
            (entry("writeClipboard", ["chars": "340"]), "Appunti impostati: 340 caratteri"),
            (entry("writeClipboard", ["chars": "1"]), "Appunti impostati: 1 carattere"),
            (entry("writeClipboard", [:], ok: false, error: "notReady"), "Appunti impostati"),
            (entry("click", ["x": "120", "y": "340", "button": "left", "count": "1"]), "Clic su 120, 340"),
            (entry("click", ["x": "120", "y": "340", "button": "left", "count": "2"]), "Doppio clic su 120, 340"),
            (entry("click", ["x": "1", "y": "2", "button": "left", "count": "3"]), "Clic ×3 su 1, 2"),
            (entry("click", ["x": "5", "y": "6.5", "button": "right", "count": "1"]), "Clic destro su 5, 6.5"),
            (entry("click", ["x": "5", "y": "6", "button": "right", "count": "2"]), "Clic destro ×2 su 5, 6"),
            (entry("drag", ["fromX": "1", "fromY": "2", "toX": "30", "toY": "40"]), "Trascinamento da 1, 2 a 30, 40"),
            (entry("scroll", ["dx": "0", "dy": "-5", "x": "100", "y": "200"]), "Scorrimento di 0, -5 su 100, 200"),
            (entry("scroll", ["dx": "0", "dy": "-5"]), "Scorrimento di 0, -5"),
            (entry("type", ["chars": "12"]), "12 caratteri digitati"),
            (entry("type", ["chars": "1"]), "1 carattere digitato"),
            (entry("key", ["combo": "cmd+a"]), "Tasto cmd+a"),
            (entry("key", ["chars": "1"]), "1 carattere digitato"),
            (entry("key", [:]), "Pressione di un tasto"),
            (entry("checkpoint", ["name": "before-brew"]), "Checkpoint before-brew"),
            (entry("checkpoint", [:], ok: false, error: "notRunning"), "Checkpoint"),
            (entry("rollback", ["name": "before-brew"]), "Ritorno al checkpoint before-brew"),
            (entry("rollback", [:], ok: false, error: "badRequest"), "Ritorno al checkpoint più recente"),
            (entry("checkpoints"), "Elenco dei checkpoint"),
            (entry("rollbackEnd", ["name": "before-brew"], client: "nido"), "Fine del ritorno a before-brew"),
            (entry("putFile", ["path": "in/data.csv", "bytes": "2048"]), "File nella VM: in/data.csv (2 KiB)"),
            (entry("putFile", ["path": "a.txt", "bytes": "300"], ok: false, error: "badRequest"), "File nella VM: a.txt (300 B)"),
            (entry("putFile", ["path": "a.txt"]), "File nella VM: a.txt"),
            (entry("putFile"), "File nella VM"),
            (entry("getFile", ["path": "out/log.txt", "bytes": "1048576"]), "File dalla VM: out/log.txt (1 MiB)"),
            (entry("getFile", ["path": "out/log.txt"], ok: false, error: "badRequest"), "File dalla VM: out/log.txt"),
            (entry("getFile"), "File dalla VM"),
            (entry("listFiles", ["path": "out", "entries": "3"]), "File in out: 3 elementi"),
            (entry("listFiles", ["entries": "1"]), "File in NidoTransfer: 1 elemento"),
            (entry("listFiles", ["path": "nope"], ok: false, error: "badRequest"), "Elenco dei file di nope"),
            (entry("listFiles", [:], ok: false, error: "notRunning"), "Elenco dei file di NidoTransfer"),
            (entry("teleport", ["x": "1"]), "teleport"),
        ]
        for (entry, expected) in cases {
            #expect(AgentActivityModel.text(for: entry) == expected, "\(entry.op) \(entry.detail)")
        }
        #expect(AgentActivityModel.symbol(for: "click") == "cursorarrow.click")
        #expect(AgentActivityModel.symbol(for: "teleport") == "questionmark.circle")
        #expect(AgentActivityModel.symbol(for: "readClipboard") == "doc.on.clipboard")
        #expect(AgentActivityModel.symbol(for: "writeClipboard") == "doc.on.clipboard")
        #expect(AgentActivityModel.symbol(for: "key", detail: ["combo": "cmd+a"]) == "command")
        #expect(AgentActivityModel.symbol(for: "key", detail: ["chars": "1"]) == "keyboard")
        #expect(AgentActivityModel.symbol(for: "key") == "command")
        #expect(AgentActivityModel.symbol(for: "checkpoint") == "bookmark")
        #expect(AgentActivityModel.symbol(for: "rollback") == "arrow.uturn.backward")
        #expect(AgentActivityModel.symbol(for: "checkpoints") == "list.bullet")
        #expect(AgentActivityModel.symbol(for: "rollbackEnd") == "arrow.uturn.backward.circle")
        #expect(AgentActivityModel.symbol(for: "putFile") == "square.and.arrow.down")
        #expect(AgentActivityModel.symbol(for: "getFile") == "square.and.arrow.up")
        #expect(AgentActivityModel.symbol(for: "listFiles") == "folder")
    }

    /// `type` is only a count: a field the log never writes (a foreign or forged line) is not
    /// shown either, and a failed `type` shows only its code.
    @Test func typeShowsOnlyACount() async throws {
        let fx = try Fixture(); defer { fx.cleanup() }
        try fx.append(entry("type", ["chars": "12", "text": "hunter2"], at: 0))
        try fx.append(entry("type", ["chars": "7", "text": "hunter2"], at: 1, ok: false, error: "badRequest",
                            message: "cannot type 'hunter2'"))
        let model = fx.model()
        await model.refresh()
        let rows = model.sessions.flatMap(\.rows)
        #expect(rows.map(\.text) == ["7 caratteri digitati", "12 caratteri digitati"])
        #expect(rows[0].failure == "badRequest")
        #expect(rows[1].failure == nil)
        for row in rows {
            #expect(!"\(row)".contains("hunter2"))
        }
    }

    @Test func failureShowsCodeAndMessage() async throws {
        let fx = try Fixture(); defer { fx.cleanup() }
        try fx.append(entry("click", ["x": "1", "y": "2", "button": "left", "count": "1"], ok: false,
                            error: "permissionMissing", message: "Accessibility is not allowed", ms: 4))
        try fx.append(entry("status", at: 1, ms: 9))
        let model = fx.model()
        await model.refresh()
        let rows = model.sessions.flatMap(\.rows)
        #expect(rows.map(\.ok) == [true, false])
        #expect(rows[0].outcome == "OK")
        #expect(rows[1].outcome == "Non riuscito")
        #expect(rows[1].failure == "permissionMissing: Accessibility is not allowed")
        #expect(rows.map(\.duration) == ["9 ms", "4 ms"])
    }

    // MARK: - Thumbnails

    @Test func thumbnailsAndMissingOnes() async throws {
        let fx = try Fixture(); defer { fx.cleanup() }
        try fx.append(entry("screenshot", ["maxLongEdge": "1280"], at: 0), png: Self.png)
        // An entry whose thumbnail was pruned (cap) or never made.
        try fx.append(entry("zoom", ["region": "0,0,10,10"], at: 1, thumb: "00000000000000000001.jpg"))
        try fx.append(entry("click", ["x": "1", "y": "2", "button": "left", "count": "1"], at: 2))
        let model = fx.model()
        await model.refresh()
        let rows = model.sessions.flatMap(\.rows)
        #expect(rows.map(\.showsThumbnail) == [false, true, true])
        #expect(rows[0].thumbnail == nil)
        // Rows name their thumbnail; the view reads it when the row is shown (`thumbnailData`,
        // through `AgentActivityLog.thumbnailData`). Gone: nil, the view draws the placeholder.
        #expect(rows[1].thumbnail == "00000000000000000001.jpg")
        #expect(await model.thumbnailData("00000000000000000001.jpg") == nil)
        let kept = try #require(rows[2].thumbnail)
        let data = try #require(await model.thumbnailData(kept))
        #expect(data.prefix(2) == Data([0xFF, 0xD8]))
        // A symlink in place of the file is not followed.
        let file = fx.bundle.agentLogURL.appendingPathComponent("thumbs").appendingPathComponent(kept)
        let outside = fx.root.appendingPathComponent("outside.jpg")
        try FileManager.default.moveItem(at: file, to: outside)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: outside)
        #expect(await model.thumbnailData(kept) == nil)
    }

    // MARK: - Live

    @Test func refreshPicksUpAppendedEntries() async throws {
        let fx = try Fixture(); defer { fx.cleanup() }
        let model = fx.model()
        await model.refresh()
        #expect(model.sessions.isEmpty)
        try fx.append(entry("status", at: 0))
        await model.refresh()
        #expect(model.sessions.flatMap(\.rows).count == 1)
        try fx.append(entry("screenshot", ["maxLongEdge": "1280"], at: 1))
        await model.refresh()
        #expect(model.sessions.flatMap(\.rows).map(\.text) == ["Screenshot", "Controllo dello stato"])
    }

    @Test func watchPicksUpAppendedEntries() async throws {
        let fx = try Fixture(); defer { fx.cleanup() }
        let model = fx.model()
        let watcher = Task { await model.watch(interval: .milliseconds(20)) }
        defer { watcher.cancel() }
        try fx.append(entry("status", at: 0))
        #expect(await waitUntil { model.sessions.flatMap(\.rows).count == 1 })
        try fx.append(entry("type", ["chars": "4"], at: 1))
        #expect(await waitUntil { model.sessions.flatMap(\.rows).count == 2 })
        // A clear from elsewhere (`nido agent log --clear`) empties the panel too.
        try AgentActivityLog.clear(in: fx.bundle)
        #expect(await waitUntil { model.sessions.isEmpty })
    }

    @Test func showsOnlyTheNewest() async throws {
        let fx = try Fixture(); defer { fx.cleanup() }
        for i in 0..<5 { try fx.append(entry("type", ["chars": "\(i + 1)"], at: Double(i))) }
        let model = fx.model(limit: 3)
        await model.refresh()
        #expect(model.sessions.flatMap(\.rows).map(\.text) ==
                ["5 caratteri digitati", "4 caratteri digitati", "3 caratteri digitati"])
        #expect(model.limitText == "Sono mostrate solo le ultime 3 azioni.")
        let all = fx.model(limit: 5)
        await all.refresh()
        #expect(all.limitText == nil)
    }

    // MARK: - Clear

    @Test func clearEmptiesOnlyAfterConfirmation() async throws {
        let fx = try Fixture(); defer { fx.cleanup() }
        try fx.append(entry("screenshot", ["maxLongEdge": "1280"], at: 0), png: Self.png)
        let model = fx.model()
        await model.refresh()
        #expect(model.sessions.count == 1)

        // Not asked: nothing happens.
        await model.clear()
        #expect(model.sessions.count == 1)
        #expect(FileManager.default.fileExists(atPath: fx.bundle.agentLogURL.path))

        // Asked, then cancelled.
        model.requestClear()
        #expect(model.isConfirmingClear)
        #expect(model.clearQuestion == "Cancellare l’attività dell’agente di macos-agenti?")
        model.cancelClear()
        #expect(!model.isConfirmingClear)
        await model.clear()
        #expect(model.sessions.count == 1)

        // Confirmed: the log and its thumbnails are gone.
        model.requestClear()
        await model.clear()
        #expect(!model.isConfirmingClear)
        #expect(model.sessions.isEmpty)
        #expect(model.errorMessage == nil)
        #expect(!FileManager.default.fileExists(atPath: fx.bundle.agentLogURL.path))
    }

    @Test func clearFailureIsSaid() async throws {
        let fx = try Fixture(); defer { fx.cleanup() }
        try fx.append(entry("status", at: 0))
        let model = AgentActivityModel(
            bundle: fx.bundle, name: "macos-agenti", timeZone: Self.utc,
            clearLog: { _ in throw POSIXError(.EACCES) })
        await model.refresh()
        model.requestClear()
        await model.clear()
        #expect(model.sessions.count == 1)
        #expect(model.errorMessage?.hasPrefix("Impossibile cancellare il registro attività dell’agente: ") == true)
    }

    // MARK: - Helpers

    /// A 4×2 PNG (thumbnails are made from it).
    static let png: Data = {
        let width = 4, height = 2
        var pixels = [UInt8](repeating: 0x80, count: width * height * 4)
        let context = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let image = context.makeImage()!
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }()

    private func waitUntil(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<250 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }
}
