// SPDX-License-Identifier: Apache-2.0
import Foundation

/// The guest's screen: its size in points and a way to capture it.
public protocol ScreenSource: Sendable {
    /// Main display size in points.
    func screenSize() -> ScreenSize
    /// PNG of the main display, scaled to `CoordinateSpace(display: <points>, maxLongEdge:).image`.
    func capture(maxLongEdge: Int) async throws -> (png: Data, image: PixelSize)
    /// PNG of `region` (display points, origin top left) at the display's full pixel density,
    /// scaled down so its long edge is at most `maxLongEdge`; `image` is the exact PNG size.
    func capture(region: CGRect, maxLongEdge: Int) async throws -> (png: Data, image: PixelSize)
}

/// Posts input in the guest. Points are display coordinates in points, origin top left.
public protocol InputSink: Sendable {
    func click(at: (x: Double, y: Double), button: MouseButton, count: Int) throws
    func drag(from: (x: Double, y: Double), to: (x: Double, y: Double)) throws
    /// Negative `dy` scrolls down, negative `dx` scrolls left. `at`, when given, moves the pointer first.
    func scroll(dx: Double, dy: Double, at: (x: Double, y: Double)?) throws
    func type(_ pieces: [TextPiece]) throws
    func key(_ stroke: KeyStroke) throws
    /// The guest's current keyboard layout, for the key codes of combos (`KeyMap.parseCombo(_:layout:)`);
    /// nil when it cannot be read, and then combos use US key codes.
    func keyLayout() -> KeyLayout?
}

extension InputSink {
    public func keyLayout() -> KeyLayout? { nil }
}

/// The two privacy permissions Nido Agent uses, and nothing else.
public protocol PermissionState: Sendable {
    var screenRecording: Bool { get }
    var accessibility: Bool { get }
}

/// Puts text on the guest's pasteboard for a while (`ClipboardSetter` in the app).
public protocol ClipboardSink: Sendable {
    /// Writes `text`, marked concealed, and clears it after `seconds` unless it changed meanwhile.
    func set(_ text: String, clearAfter seconds: Int) async
}

/// A request frame decoded, or the reply that refuses it.
public enum RequestDecoding: Equatable, Sendable {
    case request(AgentRequest)
    case refused(AgentReply)
}

/// Turns one `AgentRequest` into one `AgentReply` (plus the PNG of a screenshot, or the bytes of
/// a `getFile`).
///
/// All decisions live here so they can be tested without a VM. Messages are read by the
/// agent model and stay in English.
public struct AgentDispatcher: Sendable {
    /// Longest text `type` accepts, in UTF-8 bytes.
    public static let maxTextBytes = 4096
    /// Largest scroll distance per request, in pixels.
    public static let maxScroll = 100_000.0
    /// Longest a `setClipboard` text may stay on the pasteboard, in seconds.
    public static let maxClipboardSeconds = 600

    private let screen: any ScreenSource
    private let input: any InputSink
    private let permissions: any PermissionState
    /// Nil: `setClipboard` fails (`internalError`).
    private let clipboard: (any ClipboardSink)?
    /// Nil: `uiTree` fails (`internalError`).
    private let accessibility: (any AccessibilitySource)?
    /// `~/NidoTransfer`. Nil: `putFile`, `getFile` and `listFiles` fail (`internalError`).
    private let transfer: TransferFolder?
    /// Whether the guest's session shows the lock screen. Then nothing on it can be captured
    /// ("the main display is not shareable") and its tree is the lock screen's: `screenshot`,
    /// `zoom` and `uiTree` answer `notReady` instead.
    private let screenLocked: @Sendable () -> Bool

    public init(screen: any ScreenSource, input: any InputSink, permissions: any PermissionState,
                clipboard: (any ClipboardSink)? = nil, accessibility: (any AccessibilitySource)? = nil,
                transfer: TransferFolder? = nil, screenLocked: @escaping @Sendable () -> Bool = { false }) {
        self.screen = screen
        self.input = input
        self.permissions = permissions
        self.clipboard = clipboard
        self.accessibility = accessibility
        self.transfer = transfer
        self.screenLocked = screenLocked
    }

    /// What the listener reads after a request frame, before handling it.
    public enum DataFrame: Equatable, Sendable {
        /// Nothing: the request is all there is.
        case nothing
        /// One binary frame (the bytes of a `putFile`), read with this bound whatever `size` says,
        /// so a frame of the wrong length is still read whole and the reply stays in step; the
        /// dispatcher then refuses it.
        case frame(maxBytes: Int)
        /// Refused before reading anything (a `putFile` whose `size` is out of bounds): the
        /// listener answers this and closes the connection.
        case refused(AgentReply)
    }

    /// Only a `putFile` is followed by a data frame.
    public static func dataFrame(after request: AgentRequest) -> DataFrame {
        guard case .putFile(_, let size) = request.action else { return .nothing }
        guard (0...AgentProtocol.maxTransferBytes).contains(size) else { return .refused(sizeRefusal) }
        return .frame(maxBytes: AgentProtocol.maxTransferBytes)
    }

    /// The answer to a `putFile` whose size is out of bounds (`size`, or the frame's length).
    public static let sizeRefusal = failure(
        .badRequest, "the file must be 0 to \(AgentProtocol.maxTransferBytes) bytes (16 MiB)")

    /// Decodes a request frame. The version is read first, on its own, so a newer host whose
    /// request does not decode here (a new op, a renamed field) hears "update Nido Agent"
    /// rather than "bad request".
    public static func decodeRequest(_ data: Data) -> RequestDecoding {
        struct Versioned: Decodable { let v: Int }
        let decoder = JSONDecoder()
        let version: Int
        do {
            version = try decoder.decode(Versioned.self, from: data).v
        } catch {
            return .refused(failure(.badRequest, "could not read the request: \(describe(error))"))
        }
        guard version == AgentProtocol.version else { return .refused(versionMismatch(version)) }
        do {
            return .request(try decoder.decode(AgentRequest.self, from: data))
        } catch {
            return .refused(failure(.badRequest, "could not read the request: \(describe(error))"))
        }
    }

    /// `data` is the frame read after the request (`dataFrame(after:)`): the bytes of a `putFile`,
    /// ignored for any other op.
    public func handle(_ request: AgentRequest, data: Data? = nil) async -> (AgentReply, Data?) {
        guard request.v == AgentProtocol.version else { return (Self.versionMismatch(request.v), nil) }
        switch request.action {
        case .status:
            return (status(), nil)
        case .screenshot(let maxLongEdge):
            return await screenshot(maxLongEdge: maxLongEdge)
        case .zoom(let x, let y, let width, let height, let maxLongEdge):
            return await zoom(request, x: x, y: y, width: width, height: height, maxLongEdge: maxLongEdge)
        case .click, .drag, .scroll, .type, .key:
            return (act(request), nil)
        case .setClipboard(let text, let clearAfter):
            return (await setClipboard(text, clearAfter: clearAfter), nil)
        case .uiTree(let maxElements):
            return (await uiTree(request, maxElements: maxElements), nil)
        case .checkpoint, .rollback, .checkpoints:
            // The VM's owner answers these itself and never forwards them.
            return (Self.failure(.badRequest, "host-only action"), nil)
        case .putFile(let path, let size):
            return (putFile(path, size: size, data: data), nil)
        case .getFile(let path, let maxBytes):
            return getFile(path, maxBytes: maxBytes)
        case .listFiles(let path):
            return (listFiles(path), nil)
        }
    }

    // MARK: - Actions

    private func status() -> AgentReply {
        AgentReply(ok: true, status: AgentStatus(
            helperVersion: AgentProtocol.helperVersion, protocolVersion: AgentProtocol.version,
            screenRecording: permissions.screenRecording, accessibility: permissions.accessibility,
            screen: screen.screenSize()))
    }

    private func screenshot(maxLongEdge: Int) async -> (AgentReply, Data?) {
        guard permissions.screenRecording else { return (Self.missing("Screen Recording"), nil) }
        guard !screenLocked() else { return (Self.locked, nil) }
        guard maxLongEdge > 0 else {
            return (Self.failure(.badRequest, "maxLongEdge must be a positive number of pixels"), nil)
        }
        let points = screen.screenSize()
        let expected = CoordinateSpace(display: PixelSize(points.width, points.height), maxLongEdge: maxLongEdge).image
        let shot: (png: Data, image: PixelSize)
        do {
            shot = try await screen.capture(maxLongEdge: maxLongEdge)
        } catch {
            return (Self.failure(.internalError, "could not capture the screen: \(error)"), nil)
        }
        // The capture measures the display again: a different size means it changed in between,
        // and the host's coordinate mapping would be off.
        guard shot.image == expected, screen.screenSize() == points else {
            return (Self.failure(.screenChanged, Self.screenChangedMessage), nil)
        }
        return (AgentReply(ok: true, image: shot.image, screen: points), shot.png)
    }

    /// Coordinates are those of the latest screenshot, as for a click; the reply carries that
    /// screenshot's `screen` and the zoomed image's own size.
    private func zoom(_ request: AgentRequest, x: Double, y: Double, width: Double, height: Double,
                      maxLongEdge: Int) async -> (AgentReply, Data?) {
        guard permissions.screenRecording else { return (Self.missing("Screen Recording"), nil) }
        guard !screenLocked() else { return (Self.locked, nil) }
        guard request.image != nil, request.screen != nil else {
            return (Self.failure(.noScreenshot, "take a screenshot first: coordinates refer to the last screenshot"), nil)
        }
        guard maxLongEdge > 0 else {
            return (Self.failure(.badRequest, "maxLongEdge must be a positive number of pixels"), nil)
        }
        guard [x, y, width, height].allSatisfy(\.isFinite) else {
            return (Self.failure(.badRequest, "coordinates must be finite numbers"), nil)
        }
        let rect: CGRect
        let points: ScreenSize
        do {
            let space = try coordinateSpace(request)
            points = screen.screenSize()
            guard let mapped = space.toDisplayRect(x: x, y: y, width: width, height: height) else {
                throw Refusal("the region is outside the screenshot (or smaller than one point)")
            }
            rect = mapped
        } catch let refusal as Refusal {
            return (refusal.reply, nil)
        } catch {
            return (Self.failure(.internalError, "\(error)"), nil)
        }
        do {
            let shot = try await screen.capture(region: rect, maxLongEdge: maxLongEdge)
            guard screen.screenSize() == points else {
                return (Self.failure(.screenChanged, Self.screenChangedMessage), nil)
            }
            return (AgentReply(ok: true, image: shot.image, screen: points), shot.png)
        } catch {
            return (Self.failure(.internalError, "could not capture the screen: \(error)"), nil)
        }
    }

    /// Frames are in pixels of the latest screenshot, as a click's coordinates: the request
    /// carries that screenshot's `image` and `screen`. Needs Accessibility only (nothing is
    /// captured); the reply has no PNG.
    private func uiTree(_ request: AgentRequest, maxElements: Int) async -> AgentReply {
        guard permissions.accessibility else { return Self.missing("Accessibility") }
        guard !screenLocked() else { return Self.locked }
        guard request.image != nil, request.screen != nil else {
            return Self.failure(.noScreenshot, "take a screenshot first: frames refer to the last screenshot")
        }
        let range = AgentProtocol.uiTreeElementsRange
        guard range.contains(maxElements) else {
            return Self.failure(.badRequest, "maxElements must be \(range.lowerBound) to \(range.upperBound)")
        }
        let space: CoordinateSpace
        let points: ScreenSize
        do {
            space = try coordinateSpace(request)
            points = screen.screenSize()
        } catch let refusal as Refusal {
            return refusal.reply
        } catch {
            return Self.failure(.internalError, "\(error)")
        }
        guard let accessibility else {
            return Self.failure(.internalError, "the accessibility tree is not available")
        }
        let tree: UITree
        do {
            tree = try await accessibility.uiTree(space: space, maxElements: maxElements)
        } catch {
            return Self.failure(.internalError, "could not read the frontmost app: \(error)")
        }
        // Frames were mapped against the screenshot's screen: a different screen now means
        // they would point elsewhere.
        guard screen.screenSize() == points else {
            return Self.failure(.screenChanged, Self.screenChangedMessage)
        }
        return AgentReply(ok: true, tree: tree)
    }

    /// Needs no permission: writing the pasteboard works before Screen Recording and Accessibility
    /// are allowed (the password it carries is what the user types to allow them). The text is
    /// never logged, nor repeated in a refusal.
    private func setClipboard(_ text: String, clearAfter: Int) async -> AgentReply {
        guard !text.isEmpty, text.utf8.count <= Self.maxTextBytes else {
            return Self.failure(.badRequest, "the clipboard text must be 1 to \(Self.maxTextBytes) UTF-8 bytes")
        }
        guard (1...Self.maxClipboardSeconds).contains(clearAfter) else {
            return Self.failure(.badRequest, "clearAfter must be 1 to \(Self.maxClipboardSeconds) seconds")
        }
        guard let clipboard else {
            return Self.failure(.internalError, "the clipboard is not available")
        }
        await clipboard.set(text, clearAfter: clearAfter)
        return AgentReply(ok: true)
    }

    // MARK: - Files

    /// Files need no permission and work on a locked screen: nothing is captured or posted.
    /// Nothing is written unless exactly `size` bytes came.
    private func putFile(_ path: String, size: Int, data: Data?) -> AgentReply {
        guard (0...AgentProtocol.maxTransferBytes).contains(size) else { return Self.sizeRefusal }
        guard let data, data.count == size else {
            return Self.failure(.badRequest,
                                "the file has \(data?.count ?? 0) bytes, not the \(size) announced: nothing was written")
        }
        guard let transfer else { return Self.noTransferFolder }
        do {
            try transfer.write(data, to: path)
        } catch {
            return Self.failure(error)
        }
        return AgentReply(ok: true, bytes: size)
    }

    private func getFile(_ path: String, maxBytes: Int) -> (AgentReply, Data?) {
        guard (1...AgentProtocol.maxTransferBytes).contains(maxBytes) else {
            return (Self.failure(.badRequest, "maxBytes must be 1 to \(AgentProtocol.maxTransferBytes)"), nil)
        }
        guard let transfer else { return (Self.noTransferFolder, nil) }
        do {
            let data = try transfer.read(path, maxBytes: maxBytes)
            return (AgentReply(ok: true, bytes: data.count), data)
        } catch {
            return (Self.failure(error), nil)
        }
    }

    private func listFiles(_ path: String?) -> AgentReply {
        guard let transfer else { return Self.noTransferFolder }
        do {
            let listed = try transfer.list(path, limit: AgentProtocol.maxListedFiles)
            return AgentReply(ok: true, files: listed.entries, truncated: listed.truncated)
        } catch {
            return Self.failure(error)
        }
    }

    private static let noTransferFolder = failure(.internalError, "the transfer folder is not available")

    /// A `TransferError` as it is, anything else an `internalError`.
    private static func failure(_ error: Error) -> AgentReply {
        guard let error = error as? TransferError else { return failure(.internalError, "\(error)") }
        return failure(error.code, error.message)
    }

    private func act(_ request: AgentRequest) -> AgentReply {
        guard permissions.accessibility else { return Self.missing("Accessibility") }
        do {
            switch request.action {
            case .click(let x, let y, let button, let count):
                guard (1...3).contains(count) else { throw Refusal("click count must be 1, 2 or 3") }
                let space = try coordinateSpace(request)
                try input.click(at: try map(x, y, in: space), button: button, count: count)
            case .drag(let fromX, let fromY, let toX, let toY):
                let space = try coordinateSpace(request)
                try input.drag(from: try map(fromX, fromY, in: space), to: try map(toX, toY, in: space))
            case .scroll(let dx, let dy, let x, let y):
                guard dx.isFinite, dy.isFinite, abs(dx) <= Self.maxScroll, abs(dy) <= Self.maxScroll else {
                    throw Refusal("dx and dy must be finite and at most \(Int(Self.maxScroll)) in size")
                }
                var point: (x: Double, y: Double)?
                switch (x, y) {
                case (nil, nil):
                    point = nil
                case (let x?, let y?):
                    point = try map(x, y, in: try coordinateSpace(request))
                default:
                    throw Refusal("give both x and y, or neither")
                }
                try input.scroll(dx: dx, dy: dy, at: point)
            case .type(let text):
                guard text.utf8.count <= Self.maxTextBytes else {
                    throw Refusal("text is longer than \(Self.maxTextBytes) UTF-8 bytes: type it in parts")
                }
                try input.type(TextChunks.split(text))
            case .key(let combo):
                let stroke: KeyStroke
                do {
                    stroke = try KeyMap.parseCombo(combo, layout: input.keyLayout())
                } catch let error as KeyMapError {
                    throw Refusal(error.description)
                }
                try input.key(stroke)
            case .status, .screenshot, .setClipboard, .zoom, .uiTree, .checkpoint, .rollback, .checkpoints,
                 .putFile, .getFile, .listFiles:
                throw Refusal("not an input action")
            }
        } catch let refusal as Refusal {
            return refusal.reply
        } catch {
            return Self.failure(.internalError, "could not post the input: \(error)")
        }
        return AgentReply(ok: true)
    }

    // MARK: - Coordinates

    /// The space the request's coordinates live in: the screenshot it was taken against.
    private func coordinateSpace(_ request: AgentRequest) throws -> CoordinateSpace {
        guard let image = request.image, let shotScreen = request.screen else {
            throw Refusal("coordinates need the image and screen size of the screenshot they refer to")
        }
        guard image.width > 0, image.height > 0, shotScreen.width > 0, shotScreen.height > 0 else {
            throw Refusal("image and screen sizes must be positive")
        }
        let space = CoordinateSpace(display: PixelSize(shotScreen.width, shotScreen.height),
                                    maxLongEdge: max(image.width, image.height))
        guard space.image == image else {
            throw Refusal("image size \(image) is not a screenshot of a \(shotScreen.width)x\(shotScreen.height) screen")
        }
        guard screen.screenSize() == shotScreen else {
            throw Refusal(Self.failure(.screenChanged, Self.screenChangedMessage))
        }
        return space
    }

    private func map(_ x: Double, _ y: Double, in space: CoordinateSpace) throws -> (x: Double, y: Double) {
        guard x.isFinite, y.isFinite else { throw Refusal("coordinates must be finite numbers") }
        return space.toDisplay(x: x, y: y)
    }

    // MARK: - Replies

    static let screenChangedMessage = "the screen changed: take a new screenshot"

    /// What `screenshot`, `zoom` and `uiTree` answer while the session's screen is locked.
    static let locked = failure(.notReady, "the VM's screen is locked: log in through its window")

    private static func failure(_ code: AgentErrorCode, _ message: String) -> AgentReply {
        AgentReply(ok: false, error: code, message: message)
    }

    private static func versionMismatch(_ version: Int) -> AgentReply {
        failure(.versionMismatch,
                "Nido speaks protocol version \(version), Nido Agent speaks version \(AgentProtocol.version): run nido agent setup on the Mac to update Nido Agent (or update Nido) so they match")
    }

    /// A short, readable reason a request did not decode: what went wrong and at which field.
    private static func describe(_ error: Error) -> String {
        guard let error = error as? DecodingError else { return "not a valid request" }
        func path(_ context: DecodingError.Context, _ last: CodingKey? = nil) -> String {
            let keys = context.codingPath + (last.map { [$0] } ?? [])
            return keys.map { $0.intValue.map(String.init) ?? $0.stringValue }.joined(separator: ".")
        }
        switch error {
        case .keyNotFound(let key, let context):
            return "missing field '\(path(context, key))'"
        case .typeMismatch(_, let context), .valueNotFound(_, let context):
            return "wrong type for field '\(path(context))'"
        case .dataCorrupted(let context):
            if context.codingPath.isEmpty { return "not valid JSON" }
            return "\(context.debugDescription) (field '\(path(context))')"
        @unknown default:
            return "not a valid request"
        }
    }

    private static func missing(_ permission: String) -> AgentReply {
        failure(.permissionMissing,
                "Nido Agent needs \(permission) permission in this Mac's System Settings (Privacy & Security > \(permission))")
    }

    /// A request refused before any input was posted.
    private struct Refusal: Error {
        let reply: AgentReply
        init(_ message: String) { reply = AgentDispatcher.failure(.badRequest, message) }
        init(_ reply: AgentReply) { self.reply = reply }
    }
}
