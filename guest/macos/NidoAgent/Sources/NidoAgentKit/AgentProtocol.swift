// SPDX-License-Identifier: Apache-2.0
import Foundation

public enum AgentProtocol {
    public static let version = 1
    public static let helperVersion = "1.0.6"
    /// The first Nido Agent that understands `zoom`.
    public static let minimumZoomHelperVersion = "1.0.4"
    /// The first Nido Agent that understands `uiTree`.
    public static let minimumUITreeHelperVersion = "1.0.5"
    /// The first Nido Agent that understands `putFile`, `getFile` and `listFiles`.
    public static let minimumFilesHelperVersion = "1.0.6"
    public static let port: UInt32 = 7710
    public static let maxFrameBytes = 32 << 20
    public static let defaultMaxLongEdge = 1280
    /// The long edges, in pixels, a screenshot may be asked at (`nido act screenshot --max`, the
    /// MCP tool's `max_long_edge`).
    public static let maxLongEdgeRange = 64...4096
    /// The longest `wait` of `nido act` and of the MCP tool, in milliseconds. Done on the Mac;
    /// the helper never waits.
    public static let maxWaitMilliseconds = 10_000
    /// How many elements a `uiTree` may be asked for (`nido act ui-tree --max`, the MCP tool's
    /// `max_elements`).
    public static let uiTreeElementsRange = 1...1000
    public static let defaultUITreeElements = 300
    /// The largest file `putFile` writes and `getFile` reads (`nido act put-file`/`get-file`).
    public static let maxTransferBytes = 16 << 20
    /// The most entries a `listFiles` answer carries, newest first; `truncated` beyond.
    public static let maxListedFiles = 500
}

/// Screen size in points.
public struct ScreenSize: Codable, Equatable, Sendable {
    public var width: Int
    public var height: Int
    public init(width: Int, height: Int) { self.width = width; self.height = height }
}

public enum MouseButton: String, Codable, Sendable { case left, right }

public enum AgentAction: Codable, Equatable, Sendable {
    case status
    case screenshot(maxLongEdge: Int)
    case click(x: Double, y: Double, button: MouseButton, count: Int)
    case drag(fromX: Double, fromY: Double, toX: Double, toY: Double)
    case scroll(dx: Double, dy: Double, x: Double?, y: Double?)
    case type(text: String)
    case key(combo: String)
    /// Puts `text` on the guest's pasteboard, marked concealed, and clears it after `clearAfter`
    /// seconds unless something else was copied meanwhile. Only the VM's owner sends it, over its
    /// own vsock: the control socket of `nido act` and `nido mcp` refuses it. Nido Agent 1.0.2 and
    /// older answer `badRequest`.
    case setClipboard(text: String, clearAfter: Int)
    /// A region of the latest screenshot (pixels of that screenshot), captured again at the
    /// display's full pixel density and scaled down to `maxLongEdge`. Never changes the
    /// coordinate space: clicks keep referring to the latest screenshot. Nido Agent 1.0.3 and
    /// older answer `badRequest`.
    case zoom(x: Double, y: Double, width: Double, height: Double, maxLongEdge: Int)
    /// The controls of the frontmost app's windows (Accessibility), at most `maxElements` of
    /// them, with frames in pixels of the latest screenshot. Never changes the coordinate space.
    /// Nido Agent 1.0.4 and older answer `badRequest`.
    case uiTree(maxElements: Int)
    /// Host-only: the VM's owner takes a live snapshot marked as made by an agent, named `name`
    /// or `agent-<yyyyMMdd-HHmmss>`. Never sent to Nido Agent, which answers `badRequest`.
    case checkpoint(name: String?)
    /// Host-only: the owner goes back to the agent checkpoint `name` (the newest when nil),
    /// restarting the VM. Never sent to Nido Agent.
    case rollback(name: String?)
    /// Host-only: the agent checkpoints, newest first. Never sent to Nido Agent.
    case checkpoints
    /// Writes the bytes of the binary frame that follows the request (exactly `size` of them, at
    /// most `AgentProtocol.maxTransferBytes`) to `path` in `~/NidoTransfer`, replacing a file
    /// there. Nido Agent 1.0.5 and older answer `badRequest` (and never read the frame).
    case putFile(path: String, size: Int)
    /// The file at `path` in `~/NidoTransfer`, at most `maxBytes`: the reply carries `bytes`
    /// and is followed by one binary frame with them. Nido Agent 1.0.5 and older answer `badRequest`.
    case getFile(path: String, maxBytes: Int)
    /// One level of `~/NidoTransfer` (its top when `path` is nil), newest first. Nido Agent 1.0.5
    /// and older answer `badRequest`.
    case listFiles(path: String?)

    private enum CodingKeys: String, CodingKey {
        case op, maxLongEdge, x, y, width, height, button, count, fromX, fromY, toX, toY, dx, dy, text, combo, clearAfter
        case maxElements, name, path, size, maxBytes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let op = try c.decode(String.self, forKey: .op)
        switch op {
        case "status":
            self = .status
        case "screenshot":
            self = .screenshot(maxLongEdge: try c.decode(Int.self, forKey: .maxLongEdge))
        case "click":
            self = .click(x: try c.decode(Double.self, forKey: .x), y: try c.decode(Double.self, forKey: .y),
                          button: try c.decode(MouseButton.self, forKey: .button),
                          count: try c.decode(Int.self, forKey: .count))
        case "drag":
            self = .drag(fromX: try c.decode(Double.self, forKey: .fromX), fromY: try c.decode(Double.self, forKey: .fromY),
                         toX: try c.decode(Double.self, forKey: .toX), toY: try c.decode(Double.self, forKey: .toY))
        case "scroll":
            self = .scroll(dx: try c.decode(Double.self, forKey: .dx), dy: try c.decode(Double.self, forKey: .dy),
                           x: try c.decodeIfPresent(Double.self, forKey: .x),
                           y: try c.decodeIfPresent(Double.self, forKey: .y))
        case "type":
            self = .type(text: try c.decode(String.self, forKey: .text))
        case "key":
            self = .key(combo: try c.decode(String.self, forKey: .combo))
        case "setClipboard":
            self = .setClipboard(text: try c.decode(String.self, forKey: .text),
                                 clearAfter: try c.decode(Int.self, forKey: .clearAfter))
        case "zoom":
            self = .zoom(x: try c.decode(Double.self, forKey: .x), y: try c.decode(Double.self, forKey: .y),
                         width: try c.decode(Double.self, forKey: .width),
                         height: try c.decode(Double.self, forKey: .height),
                         maxLongEdge: try c.decode(Int.self, forKey: .maxLongEdge))
        case "uiTree":
            self = .uiTree(maxElements: try c.decode(Int.self, forKey: .maxElements))
        case "checkpoint":
            self = .checkpoint(name: try c.decodeIfPresent(String.self, forKey: .name))
        case "rollback":
            self = .rollback(name: try c.decodeIfPresent(String.self, forKey: .name))
        case "checkpoints":
            self = .checkpoints
        case "putFile":
            self = .putFile(path: try c.decode(String.self, forKey: .path), size: try c.decode(Int.self, forKey: .size))
        case "getFile":
            self = .getFile(path: try c.decode(String.self, forKey: .path),
                            maxBytes: try c.decode(Int.self, forKey: .maxBytes))
        case "listFiles":
            self = .listFiles(path: try c.decodeIfPresent(String.self, forKey: .path))
        default:
            throw DecodingError.dataCorruptedError(forKey: .op, in: c, debugDescription: "unknown op '\(op)'")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .status:
            try c.encode("status", forKey: .op)
        case .screenshot(let maxLongEdge):
            try c.encode("screenshot", forKey: .op)
            try c.encode(maxLongEdge, forKey: .maxLongEdge)
        case .click(let x, let y, let button, let count):
            try c.encode("click", forKey: .op)
            try c.encode(x, forKey: .x)
            try c.encode(y, forKey: .y)
            try c.encode(button, forKey: .button)
            try c.encode(count, forKey: .count)
        case .drag(let fromX, let fromY, let toX, let toY):
            try c.encode("drag", forKey: .op)
            try c.encode(fromX, forKey: .fromX)
            try c.encode(fromY, forKey: .fromY)
            try c.encode(toX, forKey: .toX)
            try c.encode(toY, forKey: .toY)
        case .scroll(let dx, let dy, let x, let y):
            try c.encode("scroll", forKey: .op)
            try c.encode(dx, forKey: .dx)
            try c.encode(dy, forKey: .dy)
            try c.encodeIfPresent(x, forKey: .x)
            try c.encodeIfPresent(y, forKey: .y)
        case .type(let text):
            try c.encode("type", forKey: .op)
            try c.encode(text, forKey: .text)
        case .key(let combo):
            try c.encode("key", forKey: .op)
            try c.encode(combo, forKey: .combo)
        case .setClipboard(let text, let clearAfter):
            try c.encode("setClipboard", forKey: .op)
            try c.encode(text, forKey: .text)
            try c.encode(clearAfter, forKey: .clearAfter)
        case .zoom(let x, let y, let width, let height, let maxLongEdge):
            try c.encode("zoom", forKey: .op)
            try c.encode(x, forKey: .x)
            try c.encode(y, forKey: .y)
            try c.encode(width, forKey: .width)
            try c.encode(height, forKey: .height)
            try c.encode(maxLongEdge, forKey: .maxLongEdge)
        case .uiTree(let maxElements):
            try c.encode("uiTree", forKey: .op)
            try c.encode(maxElements, forKey: .maxElements)
        case .checkpoint(let name):
            try c.encode("checkpoint", forKey: .op)
            try c.encodeIfPresent(name, forKey: .name)
        case .rollback(let name):
            try c.encode("rollback", forKey: .op)
            try c.encodeIfPresent(name, forKey: .name)
        case .checkpoints:
            try c.encode("checkpoints", forKey: .op)
        case .putFile(let path, let size):
            try c.encode("putFile", forKey: .op)
            try c.encode(path, forKey: .path)
            try c.encode(size, forKey: .size)
        case .getFile(let path, let maxBytes):
            try c.encode("getFile", forKey: .op)
            try c.encode(path, forKey: .path)
            try c.encode(maxBytes, forKey: .maxBytes)
        case .listFiles(let path):
            try c.encode("listFiles", forKey: .op)
            try c.encodeIfPresent(path, forKey: .path)
        }
    }
}

public struct AgentRequest: Codable, Equatable, Sendable {
    public var v: Int
    public var action: AgentAction
    /// Size of the screenshot the coordinates refer to.
    public var image: PixelSize?
    /// Size (points) of the screen that screenshot was taken of.
    public var screen: ScreenSize?
    /// The bytes a `putFile` sends as the binary frame after this request (`AgentClient` on the
    /// Mac). Never part of the request's JSON.
    public var payload: Data?

    public init(v: Int = AgentProtocol.version, action: AgentAction, image: PixelSize? = nil, screen: ScreenSize? = nil,
                payload: Data? = nil) {
        self.v = v
        self.action = action
        self.image = image
        self.screen = screen
        self.payload = payload
    }

    private enum CodingKeys: String, CodingKey {
        case v, action, image, screen
    }
}

public struct AgentStatus: Codable, Equatable, Sendable {
    public var helperVersion: String
    public var protocolVersion: Int
    public var screenRecording: Bool
    public var accessibility: Bool
    public var screen: ScreenSize

    public init(helperVersion: String, protocolVersion: Int, screenRecording: Bool, accessibility: Bool, screen: ScreenSize) {
        self.helperVersion = helperVersion
        self.protocolVersion = protocolVersion
        self.screenRecording = screenRecording
        self.accessibility = accessibility
        self.screen = screen
    }
}

public enum AgentErrorCode: String, Codable, Sendable {
    case badRequest, versionMismatch, screenChanged, noScreenshot, permissionMissing
    case notReady, agentAccessOff, notRunning, timeout, internalError
}

/// A rectangle in pixels of the latest screenshot, origin top left.
public struct PixelRect: Codable, Equatable, Sendable {
    public var x: Int
    public var y: Int
    public var w: Int
    public var h: Int
    public init(x: Int, y: Int, w: Int, h: Int) { self.x = x; self.y = y; self.w = w; self.h = h }
}

/// One control of a `uiTree` answer. The text comes from the guest's apps: the host cleans it
/// before it reaches a terminal or an agent.
public struct UIElement: Codable, Equatable, Sendable {
    /// Index in this answer only.
    public var id: Int
    /// Short role: `button`, `textField`, `secureTextField`, `staticText`, ...
    public var role: String
    /// Title, else description, else label.
    public var name: String?
    /// Text value, at most 200 characters; never set for a secure text field.
    public var value: String?
    public var enabled: Bool
    public var focused: Bool
    public var frame: PixelRect

    public init(id: Int, role: String, name: String?, value: String?, enabled: Bool, focused: Bool, frame: PixelRect) {
        self.id = id
        self.role = role
        self.name = name
        self.value = value
        self.enabled = enabled
        self.focused = focused
        self.frame = frame
    }
}

/// The frontmost app's controls in reading order; `truncated` when a limit (elements, depth,
/// time, an app that stopped answering) cut the list.
public struct UITree: Codable, Equatable, Sendable {
    public var app: String
    public var elements: [UIElement]
    public var truncated: Bool

    public init(app: String, elements: [UIElement], truncated: Bool) {
        self.app = app
        self.elements = elements
        self.truncated = truncated
    }
}

/// One item of a `listFiles` answer: a regular file or a folder of `~/NidoTransfer` (symbolic
/// links and other special files are never listed). The name comes from the guest: the host
/// cleans it before it reaches a terminal or an agent.
public struct TransferEntry: Codable, Equatable, Sendable {
    public var name: String
    /// `file` or `folder`.
    public var kind: String
    /// In bytes; 0 for a folder.
    public var size: Int
    public var modified: Date

    public static let file = "file"
    public static let folder = "folder"

    public init(name: String, kind: String, size: Int, modified: Date) {
        self.name = name
        self.kind = kind
        self.size = size
        self.modified = modified
    }
}

/// A screenshot reply has `ok`, `image` and `screen`; its PNG follows as a second binary frame.
/// A `uiTree` reply has `ok` and `tree`, and no PNG. A `putFile` reply has `bytes` (written); a
/// `getFile` reply has `bytes` and the file follows as a second binary frame; a `listFiles` reply
/// has `files` and `truncated`.
public struct AgentReply: Codable, Equatable, Sendable {
    public var ok: Bool
    public var status: AgentStatus?
    public var image: PixelSize?
    public var screen: ScreenSize?
    public var error: AgentErrorCode?
    public var message: String?
    public var tree: UITree?
    public var files: [TransferEntry]?
    public var truncated: Bool?
    public var bytes: Int?

    public init(ok: Bool, status: AgentStatus? = nil, image: PixelSize? = nil, screen: ScreenSize? = nil,
                error: AgentErrorCode? = nil, message: String? = nil, tree: UITree? = nil,
                files: [TransferEntry]? = nil, truncated: Bool? = nil, bytes: Int? = nil) {
        self.ok = ok
        self.status = status
        self.image = image
        self.screen = screen
        self.error = error
        self.message = message
        self.tree = tree
        self.files = files
        self.truncated = truncated
        self.bytes = bytes
    }
}
