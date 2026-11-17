// SPDX-License-Identifier: Apache-2.0
import Foundation

public enum AgentProtocol {
    public static let version = 1
    public static let helperVersion = "1.0.4"
    /// The first Nido Agent that understands `zoom`.
    public static let minimumZoomHelperVersion = "1.0.4"
    public static let port: UInt32 = 7710
    public static let maxFrameBytes = 32 << 20
    public static let defaultMaxLongEdge = 1280
    /// The long edges, in pixels, a screenshot may be asked at (`nido act screenshot --max`, the
    /// MCP tool's `max_long_edge`).
    public static let maxLongEdgeRange = 64...4096
    /// The longest `wait` of `nido act` and of the MCP tool, in milliseconds. Done on the Mac;
    /// the helper never waits.
    public static let maxWaitMilliseconds = 10_000
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

    private enum CodingKeys: String, CodingKey {
        case op, maxLongEdge, x, y, width, height, button, count, fromX, fromY, toX, toY, dx, dy, text, combo, clearAfter
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

    public init(v: Int = AgentProtocol.version, action: AgentAction, image: PixelSize? = nil, screen: ScreenSize? = nil) {
        self.v = v
        self.action = action
        self.image = image
        self.screen = screen
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

/// A screenshot reply has `ok`, `image` and `screen`; its PNG follows as a second binary frame.
public struct AgentReply: Codable, Equatable, Sendable {
    public var ok: Bool
    public var status: AgentStatus?
    public var image: PixelSize?
    public var screen: ScreenSize?
    public var error: AgentErrorCode?
    public var message: String?

    public init(ok: Bool, status: AgentStatus? = nil, image: PixelSize? = nil, screen: ScreenSize? = nil,
                error: AgentErrorCode? = nil, message: String? = nil) {
        self.ok = ok
        self.status = status
        self.image = image
        self.screen = screen
        self.error = error
        self.message = message
    }
}
