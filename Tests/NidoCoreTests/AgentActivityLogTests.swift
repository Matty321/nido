// SPDX-License-Identifier: Apache-2.0
import CoreGraphics
import Darwin
import Foundation
import ImageIO
import NidoAgentKit
import Synchronization
import Testing
@testable import NidoCore

/// A real PNG of `width`×`height` pixels, one color: what a screenshot looks like to ImageIO.
func testPNG(width: Int, height: Int) -> Data {
    let space = CGColorSpaceCreateDeviceRGB()
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = context.makeImage()!
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
    return data as Data
}

@Suite struct AgentActivityLogTests {
    private func makeBundle() throws -> (tmp: URL, bundle: VMBundle) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("nido-alog-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let config = VMConfig(
            id: UUID(), name: try VMName("mac"), guest: .macos, cpuCount: 4,
            memoryBytes: 8 * 1024 * 1024 * 1024, diskBytes: 64 * 1024 * 1024 * 1024,
            macAddress: "02:00:00:00:00:01")
        return (tmp, try VMBundle.create(config: config, paths: NidoPaths(root: tmp.appendingPathComponent("VMs"))))
    }

    private func entry(_ op: String = "click", detail: [String: String] = ["x": "1", "y": "2"], second: Int = 0,
                       ok: Bool = true) -> AgentActivityEntry {
        AgentActivityEntry(
            v: 1, time: Date(timeIntervalSince1970: 1_800_000_000 + Double(second)), session: "s1", client: "mcp",
            op: op, detail: detail, ok: ok, error: ok ? nil : "notReady", message: ok ? nil : "not ready", ms: 12,
            thumb: nil)
    }

    private func files(_ bundle: VMBundle) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: bundle.agentLogURL.path).sorted()
    }

    private func thumbs(_ bundle: VMBundle) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(
            atPath: bundle.agentLogURL.appendingPathComponent("thumbs").path)) ?? []).sorted()
    }

    private func allBytes(_ bundle: VMBundle) throws -> Data {
        var data = Data()
        for name in ["agent-log.jsonl", "agent-log.1.jsonl"] {
            let url = bundle.agentLogURL.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) { data.append(try Data(contentsOf: url)) }
        }
        return data
    }

    // MARK: - What an action becomes

    @Test func typeRecordsLengthOnly() throws {
        let (tmp, bundle) = try makeBundle()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let described = try #require(AgentActivityEntry.describe(.type(text: "hunter2!")))
        #expect(described.op == "type")
        #expect(described.detail == ["chars": "8"])

        // Even when the helper echoes the text back, in an answer or an error.
        for answer in [AgentAnswer(ok: true, message: "typed hunter2!"),
                       AgentAnswer.failure(.notReady, "could not type hunter2!")] {
            let made = try #require(AgentActivityEntry.make(
                action: .type(text: "hunter2!"), answer: answer, session: "s", client: "act",
                time: Date(timeIntervalSince1970: 1_800_000_000), ms: 3))
            #expect(made.detail == ["chars": "8"])
            try AgentActivityLog.append(made, thumbnailPNG: nil, in: bundle)
        }
        let text = String(decoding: try allBytes(bundle), as: UTF8.self)
        #expect(!text.contains("hunter2"))
        #expect(text.contains(#""chars":"8""#))
        let read = try AgentActivityLog.read(in: bundle, limit: nil)
        #expect(read.count == 2)
        #expect(read[1].error == "notReady")
    }

    @Test func clipboardNeverRecorded() {
        #expect(AgentActivityEntry.describe(.setClipboard(text: "secret", clearAfter: 60)) == nil)
        #expect(AgentActivityEntry.make(
            action: .setClipboard(text: "secret", clearAfter: 60), answer: AgentAnswer(ok: true), session: "s",
            client: "act", time: Date(), ms: 1) == nil)
    }

    @Test func everyActionIsDescribed() throws {
        func d(_ action: AgentAction) throws -> AgentActivityEntry.Description {
            try #require(AgentActivityEntry.describe(action))
        }
        #expect(try d(.status).op == "status")
        #expect(try d(.status).detail == [:])
        #expect(try d(.screenshot(maxLongEdge: 1280)).detail == ["maxLongEdge": "1280"])
        #expect(try d(.zoom(x: 10, y: 20.5, width: 300, height: 200, maxLongEdge: 800)).detail
            == ["region": "10,20.5,300,200", "maxLongEdge": "800"])
        #expect(try d(.zoom(x: 1, y: 2, width: 3, height: 4, maxLongEdge: 800)).op == "zoom")
        #expect(try d(.uiTree(maxElements: 300)) == .init(op: "uiTree", detail: ["maxElements": "300"]))
        #expect(try d(.click(x: 100, y: 200.25, button: .right, count: 2))
            == .init(op: "click", detail: ["x": "100", "y": "200.25", "button": "right", "count": "2"]))
        #expect(try d(.drag(fromX: 1, fromY: 2, toX: 3, toY: 4))
            == .init(op: "drag", detail: ["fromX": "1", "fromY": "2", "toX": "3", "toY": "4"]))
        #expect(try d(.scroll(dx: 0, dy: -3, x: nil, y: nil)) == .init(op: "scroll", detail: ["dx": "0", "dy": "-3"]))
        #expect(try d(.scroll(dx: 1, dy: 2, x: 5, y: 6)).detail == ["dx": "1", "dy": "2", "x": "5", "y": "6"])
        #expect(try d(.key(combo: "cmd+a")) == .init(op: "key", detail: ["combo": "cmd+a"]))
        // A combo the key map cannot name is the client's text: not kept.
        #expect(try d(.key(combo: "cmd+\u{1B}[2J\n")).detail == [:])
        #expect(try d(.checkpoint(name: nil)) == .init(op: "checkpoint", detail: [:]))
        #expect(try d(.checkpoint(name: "before-brew")) == .init(op: "checkpoint", detail: ["name": "before-brew"]))
        #expect(try d(.rollback(name: nil)) == .init(op: "rollback", detail: [:]))
        #expect(try d(.rollback(name: "a1")) == .init(op: "rollback", detail: ["name": "a1"]))
        #expect(try d(.checkpoints) == .init(op: "checkpoints", detail: [:]))
        // A name is the client's text: cleaned and bounded.
        #expect(try d(.checkpoint(name: "a\u{1B}[2J\nb")).detail == ["name": "a [2J b"])
    }

    /// A checkpoint records the name it was saved as, a rollback the checkpoint it goes back to
    /// (the owner's answer names them); a failure keeps the name asked.
    @Test func checkpointEntriesNameTheirCheckpoint() throws {
        let info = AgentCheckpointInfo(name: "agent-20261117-101500", createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        func make(_ action: AgentAction, _ answer: AgentAnswer) throws -> AgentActivityEntry {
            try #require(AgentActivityEntry.make(action: action, answer: answer, session: "s", client: "mcp",
                                                 time: Date(), ms: 3))
        }
        #expect(try make(.checkpoint(name: nil), AgentAnswer(ok: true, message: "saved", checkpoint: info)).detail
            == ["name": "agent-20261117-101500"])
        #expect(try make(.rollback(name: nil), AgentAnswer(ok: true, message: "going back", checkpoint: info)).detail
            == ["name": "agent-20261117-101500"])
        let failed = try make(.rollback(name: "nope"), .failure(.badRequest, "no agent checkpoint named nope"))
        #expect(failed.detail == ["name": "nope"])
        #expect(failed.message == "no agent checkpoint named nope")
        let listed = try make(.checkpoints, AgentAnswer(ok: true, checkpoints: [info]))
        #expect(listed.op == "checkpoints" && listed.detail == [:])
    }

    /// A password entered one `key` press at a time must not land in the log: a key that types a
    /// character records one character, never which; shortcuts and named keys keep their combo.
    @Test func keysThatTypeACharacterKeepNoText() throws {
        let (tmp, bundle) = try makeBundle()
        defer { try? FileManager.default.removeItem(at: tmp) }

        for combo in ["a", "Q", "7", "shift+a", "Shift+1", "?", "period", "comma", "shift+slash", "é", "space", "shift+space", "Space"] {
            #expect(AgentActivityEntry.describe(.key(combo: combo))?.detail == ["chars": "1"], "\(combo)")
        }
        for combo in ["cmd+a", "ctrl+c", "option+e", "fn+f", "cmd+shift+4", "cmd++", "return", "tab", "escape",
                      "delete", "left", "f5", "shift+tab", "shift", "cmd"] {
            #expect(AgentActivityEntry.describe(.key(combo: combo))?.detail == ["combo": combo], "\(combo)")
        }
        // Not a key at all: nothing of it is kept.
        for combo in ["hunter2", "cmd+hunter2", "secret+a", "", "+x+"] {
            #expect(AgentActivityEntry.describe(.key(combo: combo))?.detail == [:], "\(combo)")
        }

        for combo in ["p", "w", "shift+d", "cmd+a", "return"] {
            let entry = try #require(AgentActivityEntry.make(
                action: .key(combo: combo), answer: AgentAnswer(ok: true), session: "s", client: "mcp",
                time: Date(timeIntervalSince1970: 1_800_000_000), ms: 1))
            try AgentActivityLog.append(entry, thumbnailPNG: nil, in: bundle)
        }
        // Nido Agent's own refusals of a key name it: the message goes, the error code stays.
        for (combo, message) in [("hunter2", "unknown key 'hunter2'. Use a single character or a name like return"),
                                 ("é", "cannot type 'é' (U+E9): only characters on a US keyboard layout can be typed")] {
            let failed = try #require(AgentActivityEntry.make(
                action: .key(combo: combo), answer: .failure(.badRequest, message), session: "s", client: "mcp",
                time: Date(timeIntervalSince1970: 1_800_000_000), ms: 1))
            #expect(failed.message == nil)
            #expect(failed.error == "badRequest")
            try AgentActivityLog.append(failed, thumbnailPNG: nil, in: bundle)
        }
        let text = String(decoding: try allBytes(bundle), as: UTF8.self)
        for typed in [#""combo":"p""#, #""combo":"w""#, "shift+d", "hunter2", "é", "\\u00e9"] {
            #expect(!text.contains(typed), "\(typed)")
        }
        #expect(try AgentActivityLog.read(in: bundle, limit: nil).map(\.detail)
            == [["chars": "1"], ["chars": "1"], ["chars": "1"], ["combo": "cmd+a"], ["combo": "return"], [:], ["chars": "1"]])
    }

    /// A writer that falls behind (a disk that stalls while an agent takes screenshots) holds at
    /// most `maxPendingThumbnails` PNGs: later entries are still written, without a thumbnail.
    @Test func backloggedWriterDropsThumbnails() {
        let release = DispatchSemaphore(value: 0)
        let written = Mutex<[Bool]>([])
        let writer = AgentActivityWriter(vmName: "mac", append: { _, png in
            release.wait()
            release.signal()
            written.withLock { $0.append(png != nil) }
        })
        let cap = AgentActivityWriter.maxPendingThumbnails
        #expect(cap == 50)
        for i in 0..<(cap + 10) { writer.enqueue(entry(second: i), png: Data([1])) }
        release.signal()
        writer.flush()
        let pngs = written.withLock { $0 }
        #expect(pngs.count == cap + 10)
        #expect(pngs.prefix(cap).allSatisfy { $0 })
        #expect(pngs.dropFirst(cap).allSatisfy { !$0 })

        // Caught up: thumbnails again.
        writer.enqueue(entry(second: 99), png: Data([1]))
        writer.flush()
        #expect(written.withLock { $0.last } == true)
    }

    /// The answer's guest text is cleaned; a tree adds its size and app, never its contents.
    @Test func answerIsCleanedAndTreeSummarized() throws {
        let failed = try #require(AgentActivityEntry.make(
            action: .click(x: 1, y: 2, button: .left, count: 1), answer: .failure(.notReady, "bad\u{1B}[31m\nthing\u{9B}"), session: "s",
            client: "mcp", time: Date(timeIntervalSince1970: 1_800_000_000.1234), ms: 7))
        #expect(failed.message == "bad [31m thing")
        #expect(failed.error == "notReady")
        #expect(!failed.ok)
        // Milliseconds, no finer.
        #expect(failed.time.timeIntervalSince1970 == 1_800_000_000.123)

        let tree = UITree(app: "No\ntes", elements: [
            UIElement(id: 0, role: "secureTextField", name: "Password", value: "hunter2", enabled: true,
                      focused: true, frame: PixelRect(x: 1, y: 2, w: 3, h: 4)),
        ], truncated: false)
        let walked = try #require(AgentActivityEntry.make(
            action: .uiTree(maxElements: 300), answer: AgentAnswer(ok: true, message: "fine", tree: tree),
            session: "s", client: "mcp", time: Date(), ms: 9))
        #expect(walked.detail == ["maxElements": "300", "elements": "1", "app": "No tes"])
        // An ok answer keeps no message.
        #expect(walked.message == nil)
        #expect(!String(decoding: try JSONEncoder().encode(walked), as: UTF8.self).contains("hunter2"))
    }

    // MARK: - The files

    @Test func appendAndReadNewestLast() throws {
        let (tmp, bundle) = try makeBundle()
        defer { try? FileManager.default.removeItem(at: tmp) }

        #expect(try AgentActivityLog.read(in: bundle, limit: nil).isEmpty)
        let entries = (0..<5).map { entry(second: $0) }
        for e in entries { try AgentActivityLog.append(e, thumbnailPNG: nil, in: bundle) }
        #expect(try AgentActivityLog.read(in: bundle, limit: nil) == entries)
        #expect(try AgentActivityLog.read(in: bundle, limit: 2) == Array(entries.suffix(2)))
        #expect(try AgentActivityLog.read(in: bundle, limit: 0) == [])

        var info = stat()
        #expect(lstat(bundle.agentLogURL.path, &info) == 0)
        #expect(info.st_mode & S_IFMT == S_IFDIR)
        #expect(info.st_mode & 0o777 == 0o700)
        let file = bundle.agentLogURL.appendingPathComponent("agent-log.jsonl")
        #expect(lstat(file.path, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o600)
        // One JSON object per line, with its version.
        let lines = String(decoding: try Data(contentsOf: file), as: UTF8.self).split(separator: "\n")
        #expect(lines.count == 5)
        #expect(lines.allSatisfy { $0.contains(#""v":1"#) })
        // UTC with milliseconds.
        #expect(lines[0].contains(#""time":"2027-01-15T08:00:00.000Z""#))
    }

    @Test func readSkipsBadLines() throws {
        let (tmp, bundle) = try makeBundle()
        defer { try? FileManager.default.removeItem(at: tmp) }

        try AgentActivityLog.append(entry(second: 0), thumbnailPNG: nil, in: bundle)
        let file = bundle.agentLogURL.appendingPathComponent("agent-log.jsonl")
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"hello":"world"}"#.utf8 + [0x0A]))
        try handle.write(contentsOf: Data("not json at all\n".utf8))
        // A crash in the middle of a line: no newline at the end.
        try handle.write(contentsOf: Data(#"{"v":1,"time":"2027-01-15T08:00:01.000Z","sess"#.utf8))
        try handle.close()

        #expect(try AgentActivityLog.read(in: bundle, limit: nil) == [entry(second: 0)])

        // The next line starts on a line of its own.
        try AgentActivityLog.append(entry(second: 2), thumbnailPNG: nil, in: bundle)
        try AgentActivityLog.append(entry(second: 3), thumbnailPNG: nil, in: bundle)
        #expect(try AgentActivityLog.read(in: bundle, limit: nil) == [entry(second: 0), entry(second: 2), entry(second: 3)])
    }

    /// What a reader returns is safe to print, whoever wrote the file.
    @Test func readCleansWhatItReturns() throws {
        let (tmp, bundle) = try makeBundle()
        defer { try? FileManager.default.removeItem(at: tmp) }

        var dirty = entry(ok: false)
        dirty.message = "evil\u{1B}]0;title\u{07}"
        dirty.op = "cl\nick"
        dirty.detail = ["x\u{1B}": "1\u{9B}"]
        dirty.thumb = "../../config.json"
        try AgentActivityLog.append(dirty, thumbnailPNG: nil, in: bundle)
        let read = try #require(try AgentActivityLog.read(in: bundle, limit: nil).first)
        #expect(read.message == "evil ]0;title")
        #expect(read.op == "cl ick")
        #expect(read.detail == ["x": "1"])
        #expect(read.thumb == nil)
    }

    @Test func rotatesPast2MiB() throws {
        let (tmp, bundle) = try makeBundle()
        defer { try? FileManager.default.removeItem(at: tmp) }

        #expect(AgentActivityLog.maxFileBytes == 2 * 1024 * 1024)
        let big = String(repeating: "a", count: 100 * 1024)
        // About 21 lines fit a file.
        for i in 0..<25 { try AgentActivityLog.append(entry(detail: ["pad": big], second: i), thumbnailPNG: nil, in: bundle) }
        #expect(try files(bundle) == ["agent-log.1.jsonl", "agent-log.jsonl"])
        #expect(try AgentActivityLog.read(in: bundle, limit: nil).map(\.time) == (0..<25).map { entry(second: $0).time })

        for i in 25..<70 { try AgentActivityLog.append(entry(detail: ["pad": big], second: i), thumbnailPNG: nil, in: bundle) }
        #expect(try files(bundle) == ["agent-log.1.jsonl", "agent-log.jsonl"])
        for name in try files(bundle) {
            let size = try FileManager.default.attributesOfItem(
                atPath: bundle.agentLogURL.appendingPathComponent(name).path)[.size] as! NSNumber
            #expect(size.intValue <= AgentActivityLog.maxFileBytes)
        }
        let read = try AgentActivityLog.read(in: bundle, limit: nil)
        // The oldest are gone, the newest kept, in order.
        #expect(read.count < 70 && read.count > 21)
        #expect(read.last?.time == entry(second: 69).time)
        #expect(read.map(\.time) == read.map(\.time).sorted())
        #expect(read.first?.time != entry(second: 0).time)
    }

    @Test func screenshotThumbnailIsASmallJPEG() throws {
        let (tmp, bundle) = try makeBundle()
        defer { try? FileManager.default.removeItem(at: tmp) }

        try AgentActivityLog.append(entry("screenshot", detail: [:]), thumbnailPNG: testPNG(width: 1280, height: 800),
                                    in: bundle)
        let read = try #require(try AgentActivityLog.read(in: bundle, limit: nil).first)
        let name = try #require(read.thumb)
        #expect(name.hasSuffix(".jpg"))
        let url = AgentActivityLog.thumbnailURL(name, in: bundle)
        #expect(url.deletingLastPathComponent().standardizedFileURL
            == bundle.agentLogURL.appendingPathComponent("thumbs", isDirectory: true).standardizedFileURL)
        var info = stat()
        #expect(lstat(url.path, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o600)
        #expect(lstat(url.deletingLastPathComponent().path, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o700)
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        #expect(CGImageSourceGetType(source) as String? == "public.jpeg")
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == 320)
        #expect(properties[kCGImagePropertyPixelHeight] as? Int == 200)

        // Bytes that are no image: the entry without a thumbnail, never no entry.
        try AgentActivityLog.append(entry("screenshot", detail: [:], second: 1), thumbnailPNG: Data([1, 2, 3]), in: bundle)
        let second = try AgentActivityLog.read(in: bundle, limit: nil)
        #expect(second.count == 2)
        #expect(second[1].thumb == nil)
    }

    @Test func thumbnailsPrunedWithTheirEntries() throws {
        let (tmp, bundle) = try makeBundle()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let png = testPNG(width: 64, height: 40)
        let big = String(repeating: "b", count: 100 * 1024)
        for i in 0..<70 {
            try AgentActivityLog.append(entry("screenshot", detail: ["pad": big], second: i), thumbnailPNG: png, in: bundle)
        }
        let live = Set(try AgentActivityLog.read(in: bundle, limit: nil).compactMap(\.thumb))
        #expect(live.count > 21 && live.count < 70)
        // Every thumbnail left is named by a live entry, and every live entry's is there.
        #expect(Set(thumbs(bundle)) == live)
    }

    /// However long an agent loops, at most `maxThumbnails` stay: the oldest go first.
    @Test func thumbnailsAreCapped() throws {
        let (tmp, bundle) = try makeBundle()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let png = testPNG(width: 64, height: 40)
        for i in 0..<8 {
            try AgentActivityLog.append(entry("screenshot", detail: [:], second: i), thumbnailPNG: png, in: bundle,
                                        maxThumbnails: 5)
        }
        let read = try AgentActivityLog.read(in: bundle, limit: nil)
        #expect(read.count == 8)
        let kept = Array(read.compactMap(\.thumb).suffix(5))
        #expect(thumbs(bundle) == kept.sorted())
        #expect(AgentActivityLog.maxThumbnails == 1000)
    }

    @Test func clearRemovesEverything() throws {
        let (tmp, bundle) = try makeBundle()
        defer { try? FileManager.default.removeItem(at: tmp) }

        try AgentActivityLog.clear(in: bundle)  // nothing there: fine
        let big = String(repeating: "c", count: 100 * 1024)
        for i in 0..<25 {
            try AgentActivityLog.append(entry("screenshot", detail: ["pad": big], second: i),
                                        thumbnailPNG: testPNG(width: 32, height: 32), in: bundle)
        }
        #expect(try files(bundle).count == 3)
        try AgentActivityLog.clear(in: bundle)
        #expect(try AgentActivityLog.read(in: bundle, limit: nil).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: bundle.agentLogURL.path))
        // And it starts again.
        try AgentActivityLog.append(entry(), thumbnailPNG: nil, in: bundle)
        #expect(try AgentActivityLog.read(in: bundle, limit: nil) == [entry()])
    }

    @Test func symlinkedLogDirectoryRefused() throws {
        let (tmp, bundle) = try makeBundle()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let elsewhere = tmp.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: bundle.agentLogURL, withDestinationURL: elsewhere)
        #expect(throws: NidoError.self) { try AgentActivityLog.append(entry(), thumbnailPNG: nil, in: bundle) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path).isEmpty)
        #expect(throws: NidoError.self) { try AgentActivityLog.read(in: bundle, limit: nil) }
        // Clearing removes the link, never what it points to.
        try Data("keep".utf8).write(to: elsewhere.appendingPathComponent("mine"))
        try AgentActivityLog.clear(in: bundle)
        #expect(FileManager.default.fileExists(atPath: elsewhere.appendingPathComponent("mine").path))

        // A symlinked log file is refused too.
        try PrivateDirectory.ensure(bundle.agentLogURL)
        try FileManager.default.createSymbolicLink(
            at: bundle.agentLogURL.appendingPathComponent("agent-log.jsonl"),
            withDestinationURL: elsewhere.appendingPathComponent("mine"))
        #expect(throws: NidoError.self) { try AgentActivityLog.append(entry(), thumbnailPNG: nil, in: bundle) }
        #expect(try Data(contentsOf: elsewhere.appendingPathComponent("mine")) == Data("keep".utf8))
    }

    // MARK: - Reading a thumbnail

    @Test func thumbnailDataReadsOnlyARealSmallFile() throws {
        let (tmp, bundle) = try makeBundle()
        defer { try? FileManager.default.removeItem(at: tmp) }
        try AgentActivityLog.append(entry("screenshot", detail: ["maxLongEdge": "1280"]),
                                    thumbnailPNG: testPNG(width: 64, height: 40), in: bundle)
        let name = try #require(try AgentActivityLog.read(in: bundle, limit: nil).first?.thumb)
        let data = try #require(AgentActivityLog.thumbnailData(name, in: bundle))
        #expect(data.prefix(2) == Data([0xFF, 0xD8]))
        // Not a name the log gives, or no such file: nothing.
        #expect(AgentActivityLog.thumbnailData("../agent-log.jsonl", in: bundle) == nil)
        #expect(AgentActivityLog.thumbnailData("00000000000000000001.jpg", in: bundle) == nil)

        let thumbs = bundle.agentLogURL.appendingPathComponent("thumbs", isDirectory: true)
        let outside = tmp.appendingPathComponent("outside.jpg")
        try data.write(to: outside)

        // A symlink named like a thumbnail is not followed.
        let linked = "00000000000000000002.jpg"
        try FileManager.default.createSymbolicLink(at: thumbs.appendingPathComponent(linked), withDestinationURL: outside)
        #expect(AgentActivityLog.thumbnailData(linked, in: bundle) == nil)

        // A FIFO never blocks the reader.
        let fifo = "00000000000000000003.jpg"
        #expect(mkfifo(thumbs.appendingPathComponent(fifo).path, 0o600) == 0)
        #expect(AgentActivityLog.thumbnailData(fifo, in: bundle) == nil)

        // More than a thumbnail can be: not read.
        let big = "00000000000000000004.jpg"
        let bigURL = thumbs.appendingPathComponent(big)
        try Data(count: AgentActivityLog.maxThumbnailBytes + 1).write(to: bigURL)
        chmod(bigURL.path, 0o600)
        #expect(AgentActivityLog.thumbnailData(big, in: bundle) == nil)
        let small = "00000000000000000005.jpg"
        try Data(count: 16).write(to: thumbs.appendingPathComponent(small))
        #expect(AgentActivityLog.thumbnailData(small, in: bundle)?.count == 16)

        // A symlinked thumbs/ folder is not followed either.
        let elsewhere = tmp.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.moveItem(at: thumbs, to: elsewhere)
        try FileManager.default.createSymbolicLink(at: thumbs, withDestinationURL: elsewhere)
        #expect(FileManager.default.fileExists(atPath: thumbs.appendingPathComponent(name).path))
        #expect(AgentActivityLog.thumbnailData(name, in: bundle) == nil)
    }

    /// The writer may make a file again while the folder is being removed: one more try.
    @Test func clearRetriesOnceWhenTheFolderRefills() throws {
        let (tmp, bundle) = try makeBundle()
        defer { try? FileManager.default.removeItem(at: tmp) }
        try AgentActivityLog.append(entry(), thumbnailPNG: nil, in: bundle)

        var calls = 0
        try AgentActivityLog.clear(in: bundle) { url in
            calls += 1
            if calls == 1 {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSUnderlyingErrorKey: POSIXError(.ENOTEMPTY)])
            }
            try FileManager.default.removeItem(at: url)
        }
        #expect(calls == 2)
        #expect(!FileManager.default.fileExists(atPath: bundle.agentLogURL.path))

        // Another failure is not retried.
        try AgentActivityLog.append(entry(), thumbnailPNG: nil, in: bundle)
        calls = 0
        #expect(throws: POSIXError.self) {
            try AgentActivityLog.clear(in: bundle) { _ in
                calls += 1
                throw POSIXError(.EACCES)
            }
        }
        #expect(calls == 1)
        // Two refills in a row: the second failure is the answer.
        calls = 0
        #expect(throws: POSIXError.self) {
            try AgentActivityLog.clear(in: bundle) { _ in
                calls += 1
                throw POSIXError(.ENOTEMPTY)
            }
        }
        #expect(calls == 2)
    }

    // MARK: - The command's `client`

    @Test func clientFieldOptional() throws {
        let id = UUID()
        let old = #"{"vmID":"\#(id.uuidString)","bundlePath":"/b","action":{"op":"status"}}"#
        let decoded = try JSONDecoder().decode(AgentCommand.self, from: Data(old.utf8))
        #expect(decoded.client == nil)
        #expect(decoded.session == nil)
        #expect(decoded.action == .status)

        let command = AgentCommand(vmID: id, bundlePath: "/b", action: .status, client: "mcp", session: "abc")
        let again = try JSONDecoder().decode(AgentCommand.self, from: JSONEncoder().encode(command))
        #expect(again == command)
        // Without them, nothing new on the wire: an older owner reads it as before.
        let plain = String(decoding: try JSONEncoder().encode(AgentCommand(vmID: id, bundlePath: "/b", action: .status)),
                           as: UTF8.self)
        #expect(!plain.contains("client") && !plain.contains("session"))
    }
}
