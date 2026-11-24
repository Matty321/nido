// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import NidoAgentKit

// MARK: - Fakes

private struct FakeScreen: ScreenSource {
    var size = ScreenSize(width: 1440, height: 900)
    var png = Data([0x89, 0x50, 0x4E, 0x47])

    func screenSize() -> ScreenSize { size }

    func capture(maxLongEdge: Int) async throws -> (png: Data, image: PixelSize) {
        let space = CoordinateSpace(display: PixelSize(size.width, size.height), maxLongEdge: maxLongEdge)
        return (png, space.image)
    }

    /// Records the region it was asked for.
    let regions = RegionLog()
    var regionImage = PixelSize(400, 200)

    func capture(region: CGRect, maxLongEdge: Int) async throws -> (png: Data, image: PixelSize) {
        regions.record(region)
        return (png, regionImage)
    }
}

private final class RegionLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [CGRect] = []
    func record(_ r: CGRect) { lock.withLock { items.append(r) } }
    var recorded: [CGRect] { lock.withLock { items } }
}

private struct FakePermissions: PermissionState {
    var screenRecording = true
    var accessibility = true
}

private enum InputCall: Equatable {
    case click(x: Double, y: Double, button: MouseButton, count: Int)
    case drag(fromX: Double, fromY: Double, toX: Double, toY: Double)
    case scroll(dx: Double, dy: Double, x: Double?, y: Double?)
    case type([TextPiece])
    case key(KeyStroke)
}

private final class FakeInput: InputSink, @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [InputCall] = []
    private var currentLayout: KeyLayout?

    var recorded: [InputCall] { lock.withLock { calls } }
    var layout: KeyLayout? {
        get { lock.withLock { currentLayout } }
        set { lock.withLock { currentLayout = newValue } }
    }

    func keyLayout() -> KeyLayout? { layout }

    private func record(_ call: InputCall) { lock.withLock { calls.append(call) } }

    func click(at p: (x: Double, y: Double), button: MouseButton, count: Int) throws {
        record(.click(x: p.x, y: p.y, button: button, count: count))
    }
    func drag(from: (x: Double, y: Double), to: (x: Double, y: Double)) throws {
        record(.drag(fromX: from.x, fromY: from.y, toX: to.x, toY: to.y))
    }
    func scroll(dx: Double, dy: Double, at p: (x: Double, y: Double)?) throws {
        record(.scroll(dx: dx, dy: dy, x: p?.x, y: p?.y))
    }
    func type(_ pieces: [TextPiece]) throws {
        record(.type(pieces))
    }
    func key(_ stroke: KeyStroke) throws {
        record(.key(stroke))
    }
}

private let shotImage = PixelSize(1280, 800)
private let shotScreen = ScreenSize(width: 1440, height: 900)

/// Records the clipboard requests that reach the pasteboard.
private final class FakeClipboard: ClipboardSink, @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [(text: String, clearAfter: Int)] = []
    var recorded: [(text: String, clearAfter: Int)] { lock.withLock { calls } }

    func set(_ text: String, clearAfter seconds: Int) async {
        lock.withLock { calls.append((text, seconds)) }
    }

    /// What `readPlain` answers.
    var pasteboardText: PasteboardText {
        get { lock.withLock { content } }
        set { lock.withLock { content = newValue } }
    }
    private var content: PasteboardText = .none
    private var plain: [String] = []
    /// The plain writes that reached the pasteboard.
    var plainWrites: [String] { lock.withLock { plain } }

    func readPlain() async -> PasteboardText { pasteboardText }
    /// False makes the write fail, as when the pasteboard refuses the string.
    var writeSucceeds = true
    func writePlain(_ text: String) async -> Bool {
        lock.withLock { plain.append(text) }
        return writeSucceeds
    }
}

private func dispatcher(screen: FakeScreen = FakeScreen(), input: FakeInput = FakeInput(),
                        permissions: FakePermissions = FakePermissions(),
                        clipboard: FakeClipboard = FakeClipboard()) -> AgentDispatcher {
    AgentDispatcher(screen: screen, input: input, permissions: permissions, clipboard: clipboard)
}

private func pointed(_ action: AgentAction) -> AgentRequest {
    AgentRequest(action: action, image: shotImage, screen: shotScreen)
}

// MARK: - Brief tests

@Test func versionMismatchRefused() async {
    let (reply, png) = await dispatcher().handle(AgentRequest(v: 2, action: .status))
    #expect(reply.ok == false)
    #expect(reply.error == .versionMismatch)
    #expect(reply.message?.contains("update Nido Agent") == true)
    #expect(reply.message?.contains("nido agent setup") == true)
    #expect(png == nil)
}

@Test func screenshotNeedsScreenRecording() async {
    let d = dispatcher(permissions: FakePermissions(screenRecording: false, accessibility: true))
    let (reply, png) = await d.handle(AgentRequest(action: .screenshot(maxLongEdge: 1280)))
    #expect(reply.ok == false)
    #expect(reply.error == .permissionMissing)
    #expect(reply.message?.contains("Screen Recording") == true)
    #expect(png == nil)
}

@Test func clickNeedsAccessibility() async {
    let input = FakeInput()
    let d = dispatcher(input: input, permissions: FakePermissions(screenRecording: true, accessibility: false))
    let (reply, _) = await d.handle(pointed(.click(x: 10, y: 10, button: .left, count: 1)))
    #expect(reply.error == .permissionMissing)
    #expect(reply.message?.contains("Accessibility") == true)
    #expect(input.recorded.isEmpty)
}

@Test func staleScreenRefused() async {
    let input = FakeInput()
    let d = dispatcher(screen: FakeScreen(size: ScreenSize(width: 1920, height: 1200)), input: input)
    let (reply, _) = await d.handle(pointed(.click(x: 640, y: 400, button: .left, count: 1)))
    #expect(reply.ok == false)
    #expect(reply.error == .screenChanged)
    #expect(reply.message == "the screen changed: take a new screenshot")
    #expect(input.recorded.isEmpty)
}

@Test func clickMapsToPoints() async {
    let input = FakeInput()
    let (reply, _) = await dispatcher(input: input).handle(pointed(.click(x: 640, y: 400, button: .left, count: 1)))
    #expect(reply.ok == true)
    #expect(input.recorded == [.click(x: 720, y: 450, button: .left, count: 1)])
}

@Test func typeSplitsAndReturns() async {
    let input = FakeInput()
    let (reply, _) = await dispatcher(input: input).handle(AgentRequest(action: .type(text: "hi\n")))
    #expect(reply.ok == true)
    #expect(input.recorded == [.type([.text("hi"), .returnKey])])
}

@Test func oversizeTextRefused() async {
    let input = FakeInput()
    let text = String(repeating: "a", count: 4097)
    let (reply, _) = await dispatcher(input: input).handle(AgentRequest(action: .type(text: text)))
    #expect(reply.error == .badRequest)
    #expect(input.recorded.isEmpty)
}

@Test func statusReportsBoth() async {
    let d = dispatcher(permissions: FakePermissions(screenRecording: false, accessibility: true))
    let (reply, png) = await d.handle(AgentRequest(action: .status))
    #expect(reply.ok == true)
    #expect(png == nil)
    let status = try? #require(reply.status)
    #expect(status?.helperVersion == AgentProtocol.helperVersion)
    #expect(status?.protocolVersion == 1)
    #expect(status?.screenRecording == false)
    #expect(status?.accessibility == true)
    #expect(status?.screen == ScreenSize(width: 1440, height: 900))
}

// MARK: - Further rules

@Test func statusNeedsNoPermission() async {
    let d = dispatcher(permissions: FakePermissions(screenRecording: false, accessibility: false))
    let (reply, _) = await d.handle(AgentRequest(action: .status))
    #expect(reply.ok == true)
}

@Test func screenshotReturnsImageScreenAndPNG() async {
    let (reply, png) = await dispatcher().handle(AgentRequest(action: .screenshot(maxLongEdge: 1280)))
    #expect(reply.ok == true)
    #expect(reply.image == PixelSize(1280, 800))
    #expect(reply.screen == ScreenSize(width: 1440, height: 900))
    #expect(png == Data([0x89, 0x50, 0x4E, 0x47]))
}

@Test func screenshotNeverUpscales() async {
    let (reply, _) = await dispatcher().handle(AgentRequest(action: .screenshot(maxLongEdge: 4000)))
    #expect(reply.image == PixelSize(1440, 900))
}

@Test func screenshotWithBadSizeRefused() async {
    let (reply, png) = await dispatcher().handle(AgentRequest(action: .screenshot(maxLongEdge: 0)))
    #expect(reply.error == .badRequest)
    #expect(png == nil)
}

@Test func typeAndKeyNeedAccessibility() async {
    let input = FakeInput()
    let d = dispatcher(input: input, permissions: FakePermissions(screenRecording: true, accessibility: false))
    for action: AgentAction in [.type(text: "a"), .key(combo: "return"), .scroll(dx: 0, dy: -5, x: nil, y: nil)] {
        let (reply, _) = await d.handle(AgentRequest(action: action))
        #expect(reply.error == .permissionMissing)
    }
    #expect(input.recorded.isEmpty)
}

@Test func coordinatesWithoutShotRefused() async {
    let input = FakeInput()
    let d = dispatcher(input: input)
    let (noImage, _) = await d.handle(AgentRequest(action: .click(x: 1, y: 1, button: .left, count: 1), screen: shotScreen))
    #expect(noImage.error == .badRequest)
    let (noScreen, _) = await d.handle(AgentRequest(action: .drag(fromX: 1, fromY: 1, toX: 2, toY: 2), image: shotImage))
    #expect(noScreen.error == .badRequest)
    let (scroll, _) = await d.handle(AgentRequest(action: .scroll(dx: 0, dy: 1, x: 5, y: 5)))
    #expect(scroll.error == .badRequest)
    #expect(input.recorded.isEmpty)
}

@Test func imageThatDoesNotMatchScreenRefused() async {
    let input = FakeInput()
    let request = AgentRequest(action: .click(x: 1, y: 1, button: .left, count: 1),
                               image: PixelSize(1000, 1000), screen: shotScreen)
    let (reply, _) = await dispatcher(input: input).handle(request)
    #expect(reply.error == .badRequest)
    #expect(input.recorded.isEmpty)
}

@Test func clickCountOutOfRangeRefused() async {
    let input = FakeInput()
    let (reply, _) = await dispatcher(input: input).handle(pointed(.click(x: 1, y: 1, button: .left, count: 0)))
    #expect(reply.error == .badRequest)
    #expect(input.recorded.isEmpty)
}

@Test func rightClickKeepsButtonAndCount() async {
    let input = FakeInput()
    _ = await dispatcher(input: input).handle(pointed(.click(x: 0, y: 0, button: .right, count: 2)))
    #expect(input.recorded == [.click(x: 0, y: 0, button: .right, count: 2)])
}

@Test func dragMapsBothEnds() async {
    let input = FakeInput()
    let (reply, _) = await dispatcher(input: input).handle(pointed(.drag(fromX: 0, fromY: 0, toX: 640, toY: 400)))
    #expect(reply.ok == true)
    #expect(input.recorded == [.drag(fromX: 0, fromY: 0, toX: 720, toY: 450)])
}

@Test func scrollWithoutPointPassesThrough() async {
    let input = FakeInput()
    let (reply, _) = await dispatcher(input: input).handle(AgentRequest(action: .scroll(dx: 2, dy: -30, x: nil, y: nil)))
    #expect(reply.ok == true)
    #expect(input.recorded == [.scroll(dx: 2, dy: -30, x: nil, y: nil)])
}

@Test func scrollAtPointMapsIt() async {
    let input = FakeInput()
    let (reply, _) = await dispatcher(input: input).handle(pointed(.scroll(dx: 0, dy: -30, x: 640, y: 400)))
    #expect(reply.ok == true)
    #expect(input.recorded == [.scroll(dx: 0, dy: -30, x: 720, y: 450)])
}

@Test func scrollWithHalfAPointRefused() async {
    let input = FakeInput()
    let (reply, _) = await dispatcher(input: input).handle(pointed(.scroll(dx: 0, dy: -30, x: 640, y: nil)))
    #expect(reply.error == .badRequest)
    #expect(input.recorded.isEmpty)
}

@Test func keyParsesCombo() async {
    let input = FakeInput()
    let (reply, _) = await dispatcher(input: input).handle(AgentRequest(action: .key(combo: "cmd+space")))
    #expect(reply.ok == true)
    #expect(input.recorded == [.key(KeyStroke(keyCode: 49, modifiers: [.command], characters: " "))])
}

@Test func unknownKeyRefused() async {
    let input = FakeInput()
    let (reply, _) = await dispatcher(input: input).handle(AgentRequest(action: .key(combo: "cmd+nosuchkey")))
    #expect(reply.error == .badRequest)
    #expect(reply.message?.isEmpty == false)
    #expect(input.recorded.isEmpty)
}

@Test func textAtTheLimitAccepted() async {
    let input = FakeInput()
    // 1024 four-byte scalars: exactly 4096 UTF-8 bytes.
    let text = String(repeating: "😀", count: 1024)
    let (reply, _) = await dispatcher(input: input).handle(AgentRequest(action: .type(text: text)))
    #expect(reply.ok == true)
    let oneMore = text + "a"
    let (over, _) = await dispatcher(input: input).handle(AgentRequest(action: .type(text: oneMore)))
    #expect(over.error == .badRequest)
}

@Test func nonFiniteCoordinatesRefused() async {
    let input = FakeInput()
    let (reply, _) = await dispatcher(input: input).handle(pointed(.click(x: .nan, y: 1, button: .left, count: 1)))
    #expect(reply.error == .badRequest)
    let (scroll, _) = await dispatcher(input: input).handle(AgentRequest(action: .scroll(dx: .infinity, dy: 0, x: nil, y: nil)))
    #expect(scroll.error == .badRequest)
    #expect(input.recorded.isEmpty)
}

private struct BrokenInput: InputSink {
    struct Failure: Error {}
    func click(at: (x: Double, y: Double), button: MouseButton, count: Int) throws { throw Failure() }
    func drag(from: (x: Double, y: Double), to: (x: Double, y: Double)) throws { throw Failure() }
    func scroll(dx: Double, dy: Double, at: (x: Double, y: Double)?) throws { throw Failure() }
    func type(_ pieces: [TextPiece]) throws { throw Failure() }
    func key(_ stroke: KeyStroke) throws { throw Failure() }
}

private struct BrokenScreen: ScreenSource {
    struct Failure: Error {}
    func screenSize() -> ScreenSize { ScreenSize(width: 1440, height: 900) }
    func capture(maxLongEdge: Int) async throws -> (png: Data, image: PixelSize) { throw Failure() }
    func capture(region: CGRect, maxLongEdge: Int) async throws -> (png: Data, image: PixelSize) { throw Failure() }
}

@Test func inputFailureIsInternalError() async {
    let d = AgentDispatcher(screen: FakeScreen(), input: BrokenInput(), permissions: FakePermissions())
    let (reply, _) = await d.handle(AgentRequest(action: .key(combo: "return")))
    #expect(reply.ok == false)
    #expect(reply.error == .internalError)
}

@Test func captureFailureIsInternalError() async {
    let d = AgentDispatcher(screen: BrokenScreen(), input: FakeInput(), permissions: FakePermissions())
    let (reply, png) = await d.handle(AgentRequest(action: .screenshot(maxLongEdge: 1280)))
    #expect(reply.error == .internalError)
    #expect(png == nil)
}

private struct LyingScreen: ScreenSource {
    func screenSize() -> ScreenSize { ScreenSize(width: 1440, height: 900) }
    func capture(maxLongEdge: Int) async throws -> (png: Data, image: PixelSize) { (Data([1]), PixelSize(100, 100)) }
    func capture(region: CGRect, maxLongEdge: Int) async throws -> (png: Data, image: PixelSize) { (Data([1]), PixelSize(100, 100)) }
}

@Test func captureOfTheWrongSizeIsScreenChanged() async {
    // The display changed between reading its size and capturing it.
    let d = AgentDispatcher(screen: LyingScreen(), input: FakeInput(), permissions: FakePermissions())
    let (reply, png) = await d.handle(AgentRequest(action: .screenshot(maxLongEdge: 1280)))
    #expect(reply.error == .screenChanged)
    #expect(png == nil)
}

@Test func keyFollowsTheInputLayout() async {
    let input = FakeInput()
    // AZERTY: the key with the US code of "q" (12) types "a".
    input.layout = KeyLayout(translate: { [0: "q", 12: "a"][$0] })
    let (reply, _) = await dispatcher(input: input).handle(AgentRequest(action: .key(combo: "cmd+a")))
    #expect(reply.ok == true)
    #expect(input.recorded == [.key(KeyStroke(keyCode: 12, modifiers: [.command], characters: "a"))])
}

// MARK: - The clipboard

/// Writing the guest's pasteboard needs neither permission: it works before they are granted.
@Test func setClipboardNeedsNoPermission() async {
    let clipboard = FakeClipboard()
    let input = FakeInput()
    let d = dispatcher(input: input, permissions: FakePermissions(screenRecording: false, accessibility: false),
                       clipboard: clipboard)
    let (reply, png) = await d.handle(AgentRequest(action: .setClipboard(text: "abcde-fghjk", clearAfter: 60)))
    #expect(reply == AgentReply(ok: true))
    #expect(png == nil)
    #expect(clipboard.recorded.map(\.text) == ["abcde-fghjk"])
    #expect(clipboard.recorded.map(\.clearAfter) == [60])
    #expect(input.recorded.isEmpty)
}

/// Empty or oversized text, or a delay out of range, is refused before the pasteboard is touched,
/// and the refusal never repeats the text.
@Test func setClipboardRefusesBadValues() async {
    let clipboard = FakeClipboard()
    let d = dispatcher(clipboard: clipboard)
    let long = String(repeating: "s", count: AgentDispatcher.maxTextBytes + 1)
    for action: AgentAction in [
        .setClipboard(text: "", clearAfter: 60),
        .setClipboard(text: long, clearAfter: 60),
        .setClipboard(text: "secret-value", clearAfter: 0),
        .setClipboard(text: "secret-value", clearAfter: AgentDispatcher.maxClipboardSeconds + 1),
    ] {
        let (reply, _) = await d.handle(AgentRequest(action: action))
        #expect(reply.error == .badRequest)
        #expect(reply.message?.contains("secret-value") == false)
        #expect(reply.message?.contains(long) == false)
    }
    #expect(clipboard.recorded.isEmpty)
}

/// A helper without a pasteboard (the dispatcher's default) refuses, it never pretends.
@Test func setClipboardWithoutPasteboardFails() async {
    let d = AgentDispatcher(screen: FakeScreen(), input: FakeInput(), permissions: FakePermissions())
    let (reply, _) = await d.handle(AgentRequest(action: .setClipboard(text: "abcde", clearAfter: 60)))
    #expect(reply.ok == false)
    #expect(reply.error == .internalError)
}

// MARK: - The agent's clipboard

@Test func readReturnsText() async {
    let clipboard = FakeClipboard()
    clipboard.pasteboardText = .text("hello é")
    let (reply, data) = await dispatcher(clipboard: clipboard).handle(AgentRequest(action: .readClipboard))
    #expect(reply == AgentReply(ok: true, truncated: false, clipboard: "hello é"))
    #expect(data == nil)
}

@Test func readNeedsNoPermission() async {
    let clipboard = FakeClipboard()
    clipboard.pasteboardText = .text("x")
    let d = dispatcher(permissions: FakePermissions(screenRecording: false, accessibility: false), clipboard: clipboard)
    let (reply, _) = await d.handle(AgentRequest(action: .readClipboard))
    #expect(reply.ok == true)
}

@Test func concealedItemIsRefused() async {
    let clipboard = FakeClipboard()
    clipboard.pasteboardText = .concealed
    let (reply, _) = await dispatcher(clipboard: clipboard).handle(AgentRequest(action: .readClipboard))
    #expect(reply.ok == false)
    #expect(reply.clipboard == nil)
    #expect(reply.message == "the clipboard holds a concealed item: its text is not shown")
}

@Test func emptyStringClipboardHasNoText() async {
    let clipboard = FakeClipboard()
    clipboard.pasteboardText = .text("")
    let (reply, _) = await dispatcher(clipboard: clipboard).handle(AgentRequest(action: .readClipboard))
    #expect(reply.ok == false)
    #expect(reply.clipboard == nil)
    #expect(reply.message == "the clipboard has no text")
}

@Test func deniedPasteAccessIsExplained() async {
    let clipboard = FakeClipboard()
    clipboard.pasteboardText = .denied
    let (reply, _) = await dispatcher(clipboard: clipboard).handle(AgentRequest(action: .readClipboard))
    #expect(reply.ok == false)
    #expect(reply.clipboard == nil)
    #expect(reply.message == "the VM doesn't let Nido Agent read the clipboard: allow it in System Settings › Privacy & Security › Paste from Other Apps")
}

@Test func failedWriteIsReported() async {
    let clipboard = FakeClipboard()
    clipboard.writeSucceeds = false
    let (reply, _) = await dispatcher(clipboard: clipboard).handle(AgentRequest(action: .writeClipboard(text: "hi")))
    #expect(reply.ok == false)
    #expect(reply.message == "the clipboard could not be written")
}

@Test func emptyClipboardHasNoText() async {
    let clipboard = FakeClipboard()
    clipboard.pasteboardText = .none
    let (reply, _) = await dispatcher(clipboard: clipboard).handle(AgentRequest(action: .readClipboard))
    #expect(reply.ok == false)
    #expect(reply.clipboard == nil)
    #expect(reply.message == "the clipboard has no text")
}

@Test func readCutsAtACharacterBoundary() async throws {
    let clipboard = FakeClipboard()
    clipboard.pasteboardText = .text(String(repeating: "a", count: AgentProtocol.maxClipboardBytes - 1) + "é")
    let (reply, _) = await dispatcher(clipboard: clipboard).handle(AgentRequest(action: .readClipboard))
    let text = try #require(reply.clipboard)
    #expect(reply.truncated == true)
    #expect(text.utf8.count == AgentProtocol.maxClipboardBytes - 1)
    #expect(text.allSatisfy { $0 == "a" })
}

@Test func readOfExactlyTheLimitIsNotTruncated() async throws {
    let clipboard = FakeClipboard()
    clipboard.pasteboardText = .text(String(repeating: "a", count: AgentProtocol.maxClipboardBytes))
    let (reply, _) = await dispatcher(clipboard: clipboard).handle(AgentRequest(action: .readClipboard))
    #expect(reply.clipboard?.utf8.count == AgentProtocol.maxClipboardBytes)
    #expect(reply.truncated == false)
}

@Test func writePutsPlainText() async {
    let clipboard = FakeClipboard()
    let (reply, _) = await dispatcher(clipboard: clipboard).handle(AgentRequest(action: .writeClipboard(text: "hi")))
    #expect(reply == AgentReply(ok: true))
    #expect(clipboard.plainWrites == ["hi"])
    #expect(clipboard.recorded.isEmpty)
}

@Test func writeLimit() async {
    let clipboard = FakeClipboard()
    let d = dispatcher(clipboard: clipboard)
    let max = AgentProtocol.maxClipboardBytes
    for text in ["", String(repeating: "a", count: max + 1)] {
        let (reply, _) = await d.handle(AgentRequest(action: .writeClipboard(text: text)))
        #expect(reply.error == .badRequest)
    }
    #expect(clipboard.plainWrites.isEmpty)
    let (ok, _) = await d.handle(AgentRequest(action: .writeClipboard(text: String(repeating: "a", count: max))))
    #expect(ok.ok == true)
    #expect(clipboard.plainWrites.count == 1)
}

@Test func clipboardOpsWithoutPasteboardFail() async {
    let d = AgentDispatcher(screen: FakeScreen(), input: FakeInput(), permissions: FakePermissions())
    for action: AgentAction in [.readClipboard, .writeClipboard(text: "a")] {
        let (reply, _) = await d.handle(AgentRequest(action: action))
        #expect(reply.error == .internalError)
    }
}

// MARK: - zoom

private let zoomShotImage = PixelSize(512, 320)
private let zoomShotScreen = ScreenSize(width: 1024, height: 640)

private func zoomRequest(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> AgentRequest {
    AgentRequest(action: .zoom(x: x, y: y, width: w, height: h, maxLongEdge: 1280),
                 image: zoomShotImage, screen: zoomShotScreen)
}

@Test func zoomNeedsLastShot() async {
    let screen = FakeScreen(size: zoomShotScreen)
    let (reply, png) = await dispatcher(screen: screen)
        .handle(AgentRequest(action: .zoom(x: 1, y: 1, width: 10, height: 10, maxLongEdge: 1280)))
    #expect(reply.ok == false)
    #expect(reply.error == .noScreenshot)
    #expect(reply.message?.contains("take a screenshot first") == true)
    #expect(png == nil)
    #expect(screen.regions.recorded.isEmpty)
}

@Test func zoomCapturesMappedRegion() async {
    let screen = FakeScreen(size: zoomShotScreen)
    let (reply, png) = await dispatcher(screen: screen).handle(zoomRequest(10, 20, 100, 50))
    #expect(reply.ok == true)
    #expect(screen.regions.recorded == [CGRect(x: 20, y: 40, width: 200, height: 100)])
    #expect(reply.image == screen.regionImage)
    #expect(reply.screen == zoomShotScreen)
    #expect(png == screen.png)
}

@Test func zoomOffScreenIsBadRequest() async {
    let screen = FakeScreen(size: zoomShotScreen)
    let (reply, png) = await dispatcher(screen: screen).handle(zoomRequest(600, 20, 100, 50))
    #expect(reply.error == .badRequest)
    #expect(png == nil)
    #expect(screen.regions.recorded.isEmpty)
}

@Test func zoomNeedsScreenRecording() async {
    let d = dispatcher(screen: FakeScreen(size: zoomShotScreen),
                       permissions: FakePermissions(screenRecording: false, accessibility: true))
    let (reply, _) = await d.handle(zoomRequest(10, 20, 100, 50))
    #expect(reply.error == .permissionMissing)
    #expect(reply.message?.contains("Screen Recording") == true)
}

@Test func zoomWhenScreenChangedIsScreenChanged() async {
    let d = dispatcher(screen: FakeScreen(size: ScreenSize(width: 1920, height: 1200)))
    let (reply, _) = await d.handle(zoomRequest(10, 20, 100, 50))
    #expect(reply.error == .screenChanged)
}

// MARK: - uiTree

/// Answers a fixed tree and records what it was asked for.
private final class FakeAccessibility: AccessibilitySource, @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [(space: CoordinateSpace, maxElements: Int)] = []
    var recorded: [(space: CoordinateSpace, maxElements: Int)] { lock.withLock { calls } }
    let tree = UITree(app: "Finder", elements: [
        UIElement(id: 0, role: "button", name: "Save", value: nil, enabled: true, focused: false,
                  frame: PixelRect(x: 50, y: 100, w: 40, h: 12)),
    ], truncated: false)
    var failure: (any Error)?

    func uiTree(space: CoordinateSpace, maxElements: Int) async throws -> UITree {
        lock.withLock { calls.append((space, maxElements)) }
        if let failure { throw failure }
        return tree
    }
}

private struct NoFrontmostApp: Error {}

private func uiTreeDispatcher(_ accessibility: FakeAccessibility, screen: FakeScreen = FakeScreen(size: zoomShotScreen),
                              permissions: FakePermissions = FakePermissions()) -> AgentDispatcher {
    AgentDispatcher(screen: screen, input: FakeInput(), permissions: permissions, accessibility: accessibility)
}

private func uiTreeRequest(_ maxElements: Int = 300) -> AgentRequest {
    AgentRequest(action: .uiTree(maxElements: maxElements), image: zoomShotImage, screen: zoomShotScreen)
}

@Test func uiTreeNeedsLastShot() async {
    let accessibility = FakeAccessibility()
    let (reply, png) = await uiTreeDispatcher(accessibility).handle(AgentRequest(action: .uiTree(maxElements: 300)))
    #expect(reply.ok == false)
    #expect(reply.error == .noScreenshot)
    #expect(reply.message?.contains("take a screenshot first") == true)
    #expect(png == nil)
    #expect(accessibility.recorded.isEmpty)
}

@Test func uiTreeNeedsAccessibility() async {
    let accessibility = FakeAccessibility()
    let d = uiTreeDispatcher(accessibility, permissions: FakePermissions(screenRecording: true, accessibility: false))
    let (reply, png) = await d.handle(uiTreeRequest())
    #expect(reply.ok == false)
    #expect(reply.error == .permissionMissing)
    #expect(reply.message?.contains("Accessibility") == true)
    #expect(png == nil)
    #expect(accessibility.recorded.isEmpty)
}

/// Reading the tree needs no Screen Recording: it never captures the screen.
@Test func uiTreeReturnsTree() async {
    let accessibility = FakeAccessibility()
    let d = uiTreeDispatcher(accessibility, permissions: FakePermissions(screenRecording: false, accessibility: true))
    let (reply, png) = await d.handle(uiTreeRequest(42))
    #expect(reply.ok == true)
    #expect(reply.tree == accessibility.tree)
    #expect(reply.image == nil)
    #expect(png == nil)
    #expect(accessibility.recorded.count == 1)
    #expect(accessibility.recorded.first?.maxElements == 42)
    #expect(accessibility.recorded.first?.space == CoordinateSpace(display: PixelSize(1024, 640), maxLongEdge: 512))
}

@Test func uiTreeMaxElementsOutOfRangeRefused() async {
    for bad in [0, -1, 1001] {
        let accessibility = FakeAccessibility()
        let (reply, _) = await uiTreeDispatcher(accessibility).handle(uiTreeRequest(bad))
        #expect(reply.error == .badRequest)
        #expect(reply.message?.contains("1 to 1000") == true)
        #expect(accessibility.recorded.isEmpty)
    }
    for good in [1, 1000] {
        let (reply, _) = await uiTreeDispatcher(FakeAccessibility()).handle(uiTreeRequest(good))
        #expect(reply.ok == true)
    }
}

@Test func uiTreeWhenScreenChangedIsScreenChanged() async {
    let accessibility = FakeAccessibility()
    let d = uiTreeDispatcher(accessibility, screen: FakeScreen(size: ScreenSize(width: 1920, height: 1200)))
    let (reply, _) = await d.handle(uiTreeRequest())
    #expect(reply.error == .screenChanged)
    #expect(accessibility.recorded.isEmpty)
}

@Test func uiTreeFailureIsInternalError() async {
    let accessibility = FakeAccessibility()
    accessibility.failure = NoFrontmostApp()
    let (reply, _) = await uiTreeDispatcher(accessibility).handle(uiTreeRequest())
    #expect(reply.ok == false)
    #expect(reply.error == .internalError)
    #expect(reply.tree == nil)
}

/// A helper without an accessibility reader (the dispatcher's default) refuses, it never pretends.
@Test func uiTreeWithoutSourceFails() async {
    let d = AgentDispatcher(screen: FakeScreen(size: zoomShotScreen), input: FakeInput(), permissions: FakePermissions())
    let (reply, _) = await d.handle(uiTreeRequest())
    #expect(reply.ok == false)
    #expect(reply.error == .internalError)
}

// MARK: - Locked screen

private func lockedDispatcher(_ locked: Bool, accessibility: FakeAccessibility = FakeAccessibility(),
                              input: FakeInput = FakeInput()) -> AgentDispatcher {
    AgentDispatcher(screen: FakeScreen(size: zoomShotScreen), input: input, permissions: FakePermissions(),
                    accessibility: accessibility, screenLocked: { locked })
}

/// On a locked screen the capture fails ("the main display is not shareable") and the tree is
/// that of the lock screen: the three say so, without capturing or walking anything.
@Test func lockedScreenRefusesScreenshotZoomAndUITree() async {
    let accessibility = FakeAccessibility()
    let d = lockedDispatcher(true, accessibility: accessibility)
    for request in [AgentRequest(action: .screenshot(maxLongEdge: 1280)), zoomRequest(0, 0, 100, 100),
                    uiTreeRequest(), AgentRequest(action: .uiTree(maxElements: 300))] {
        let (reply, png) = await d.handle(request)
        #expect(reply.ok == false)
        #expect(reply.error == .notReady)
        #expect(reply.message == "the VM's screen is locked: log in through its window")
        #expect(png == nil)
    }
    #expect(accessibility.recorded.isEmpty)
}

@Test func unlockedScreenIsCaptured() async {
    let d = lockedDispatcher(false)
    #expect(await d.handle(AgentRequest(action: .screenshot(maxLongEdge: 1280))).0.ok)
    #expect(await d.handle(zoomRequest(0, 0, 100, 100)).0.ok)
    #expect(await d.handle(uiTreeRequest()).0.ok)
}

/// Input and status are not refused: they work on the lock screen as on any other.
@Test func lockedScreenLeavesInputAndStatusAlone() async {
    let input = FakeInput()
    let d = lockedDispatcher(true, input: input)
    #expect(await d.handle(AgentRequest(action: .status)).0.ok)
    let actions: [AgentRequest] = [
        AgentRequest(action: .click(x: 10, y: 10, button: .left, count: 1), image: zoomShotImage, screen: zoomShotScreen),
        AgentRequest(action: .scroll(dx: 0, dy: -10, x: nil, y: nil)),
        AgentRequest(action: .type(text: "a")),
        AgentRequest(action: .key(combo: "tab")),
    ]
    for request in actions {
        #expect(await d.handle(request).0.ok)
    }
    #expect(input.recorded.count == 4)
}

/// Checkpoints are the VM owner's: one that reaches Nido Agent is refused, nothing is touched.
@Test func checkpointOpsAreHostOnly() async {
    let input = FakeInput()
    let d = dispatcher(input: input)
    for action in [AgentAction.checkpoint(name: nil), .rollback(name: "x"), .checkpoints] {
        let (reply, png) = await d.handle(AgentRequest(action: action))
        #expect(reply.ok == false)
        #expect(reply.error == .badRequest)
        #expect(reply.message == "host-only action")
        #expect(png == nil)
    }
    #expect(input.recorded.isEmpty)
}

// MARK: - Files

/// A dispatcher whose transfer folder is a fresh temporary directory; `cleanup` removes it.
private func fileDispatcher(permissions: FakePermissions = FakePermissions(), locked: Bool = false)
    -> (AgentDispatcher, root: URL, cleanup: () -> Void) {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("nido-dispatch-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    let root = base.appendingPathComponent("NidoTransfer")
    let d = AgentDispatcher(screen: FakeScreen(), input: FakeInput(), permissions: permissions,
                            transfer: TransferFolder(root: root), screenLocked: { locked })
    return (d, root, { try? FileManager.default.removeItem(at: base) })
}

@Test func putFileWritesTheDataFrame() async throws {
    let (d, root, cleanup) = fileDispatcher()
    defer { cleanup() }
    let bytes = Data("hello\u{0}world".utf8)
    let (reply, out) = await d.handle(AgentRequest(action: .putFile(path: "in/hello.bin", size: bytes.count)), data: bytes)
    #expect(reply.ok)
    #expect(reply.bytes == bytes.count)
    #expect(out == nil)
    #expect(try Data(contentsOf: root.appendingPathComponent("in/hello.bin")) == bytes)
}

@Test func putFileSizeMismatchWritesNothing() async {
    let (d, root, cleanup) = fileDispatcher()
    defer { cleanup() }
    let cases: [(Int, Data?)] = [(5, Data("abcd".utf8)), (3, Data("abcd".utf8)), (4, nil)]
    for (size, data) in cases {
        let (reply, _) = await d.handle(AgentRequest(action: .putFile(path: "f.txt", size: size)), data: data)
        #expect(reply.ok == false)
        #expect(reply.error == .badRequest)
    }
    let (tooBig, _) = await d.handle(
        AgentRequest(action: .putFile(path: "f.txt", size: AgentProtocol.maxTransferBytes + 1)),
        data: Data(count: AgentProtocol.maxTransferBytes + 1))
    #expect(tooBig.error == .badRequest)
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("f.txt").path))
}

@Test func putFileBadPathRefused() async {
    let (d, _, cleanup) = fileDispatcher()
    defer { cleanup() }
    for path in ["/etc/passwd", "../x", "a//b", ""] {
        let (reply, _) = await d.handle(AgentRequest(action: .putFile(path: path, size: 1)), data: Data("x".utf8))
        #expect(reply.error == .badRequest, "\(path)")
    }
}

@Test func getFileReturnsBytesAndData() async throws {
    let (d, _, cleanup) = fileDispatcher()
    defer { cleanup() }
    let bytes = Data((0..<300).map { UInt8($0 % 256) })
    _ = await d.handle(AgentRequest(action: .putFile(path: "out.bin", size: bytes.count)), data: bytes)
    let (reply, out) = await d.handle(AgentRequest(action: .getFile(path: "out.bin", maxBytes: 1 << 20)))
    #expect(reply.ok)
    #expect(reply.bytes == 300)
    #expect(out == bytes)

    let (small, none) = await d.handle(AgentRequest(action: .getFile(path: "out.bin", maxBytes: 299)))
    #expect(small.error == .badRequest)
    #expect(none == nil)
    let (missing, _) = await d.handle(AgentRequest(action: .getFile(path: "nope", maxBytes: 1 << 20)))
    #expect(missing.error == .badRequest)
    for maxBytes in [0, -1, AgentProtocol.maxTransferBytes + 1] {
        let (bad, _) = await d.handle(AgentRequest(action: .getFile(path: "out.bin", maxBytes: maxBytes)))
        #expect(bad.error == .badRequest, "\(maxBytes)")
    }
}

/// An empty file still has its data frame (zero bytes), so the host always reads one.
@Test func getFileOfAnEmptyFileHasAnEmptyFrame() async {
    let (d, _, cleanup) = fileDispatcher()
    defer { cleanup() }
    _ = await d.handle(AgentRequest(action: .putFile(path: "empty", size: 0)), data: Data())
    let (reply, out) = await d.handle(AgentRequest(action: .getFile(path: "empty", maxBytes: 10)))
    #expect(reply.ok)
    #expect(reply.bytes == 0)
    #expect(out == Data())
}

@Test func listFilesAnswersEntries() async {
    let (d, _, cleanup) = fileDispatcher()
    defer { cleanup() }
    _ = await d.handle(AgentRequest(action: .putFile(path: "docs/a.txt", size: 1)), data: Data("a".utf8))
    let (top, out) = await d.handle(AgentRequest(action: .listFiles(path: nil)))
    #expect(top.ok)
    #expect(top.files?.map(\.name) == ["docs"])
    #expect(top.files?.first?.kind == "folder")
    #expect(top.truncated == false)
    #expect(out == nil)
    let (inner, _) = await d.handle(AgentRequest(action: .listFiles(path: "docs")))
    #expect(inner.files?.map(\.name) == ["a.txt"])
    let (bad, _) = await d.handle(AgentRequest(action: .listFiles(path: "../")))
    #expect(bad.error == .badRequest)
}

/// Files need no permission and work on a locked screen: nothing is captured or posted.
@Test func filesNeedNoPermissionNorUnlockedScreen() async {
    let (d, _, cleanup) = fileDispatcher(permissions: FakePermissions(screenRecording: false, accessibility: false),
                                         locked: true)
    defer { cleanup() }
    #expect(await d.handle(AgentRequest(action: .putFile(path: "a", size: 1)), data: Data("a".utf8)).0.ok)
    #expect(await d.handle(AgentRequest(action: .getFile(path: "a", maxBytes: 1))).0.ok)
    #expect(await d.handle(AgentRequest(action: .listFiles(path: nil))).0.ok)
}

/// A helper built without a transfer folder refuses, it never pretends.
@Test func filesWithoutFolderFail() async {
    let d = dispatcher()
    let cases: [(AgentAction, Data?)] = [
        (.putFile(path: "a", size: 1), Data("a".utf8)), (.getFile(path: "a", maxBytes: 1), nil), (.listFiles(path: nil), nil),
    ]
    for (action, data) in cases {
        let (reply, out) = await d.handle(AgentRequest(action: action), data: data)
        #expect(reply.error == .internalError)
        #expect(out == nil)
    }
}

/// Data that comes with another op is ignored, and the old ops answer as before.
@Test func oldOpsUnaffectedByFiles() async {
    let input = FakeInput()
    let d = dispatcher(input: input)
    let (status, _) = await d.handle(AgentRequest(action: .status), data: Data("x".utf8))
    #expect(status.ok)
    #expect(status.status?.helperVersion == "1.0.8")
    #expect(status.files == nil && status.bytes == nil && status.truncated == nil)
    let (typed, _) = await d.handle(AgentRequest(action: .type(text: "hi")))
    #expect(typed.ok)
    #expect(input.recorded.count == 1)
}
