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
