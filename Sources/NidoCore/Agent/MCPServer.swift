// SPDX-License-Identifier: Apache-2.0
import Foundation
import NidoAgentKit

/// What `MCPServer` needs from the owner of the VM: one action in, one answer out.
/// `AgentControlClient` is the real one; tests use a fake.
public protocol AgentActions: Sendable {
    func send(_ action: AgentAction) throws -> AgentAnswer
    /// `send(_:)` with its own limit on the wait for the answer (`MacAgentSetup` asks `status`
    /// often and briefly). Conformers that have no such limit use the default, which ignores it.
    func send(_ action: AgentAction, timeout: Duration) throws -> AgentAnswer
}

extension AgentActions {
    public func send(_ action: AgentAction, timeout: Duration) throws -> AgentAnswer { try send(action) }
}

extension AgentControlClient: AgentActions {}

/// A Model Context Protocol server for one VM, spoken over stdio (`nido mcp <vm>`): JSON-RPC 2.0,
/// one JSON object per line, with a few tools that forward to the VM owner's control socket.
/// Minimal on purpose, with no dependency: `initialize`, `ping`, `tools/list` and `tools/call`.
///
/// A tool failure (refused action, owner not reachable, bad arguments) is a result with
/// `isError: true`, which the model can read; only a malformed request is a JSON-RPC error.
/// Its text starts with the error code (`notReady: <message>`): a stable token the model can act
/// on whatever the language of the message. The server never writes anything but protocol lines
/// to its output.
public final class MCPServer {
    /// The protocol revisions the server speaks, newest first.
    public static let protocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26"]

    /// The tool names, in the order `tools/list` returns them.
    public static let toolNames = ["status", "screenshot", "click", "drag", "scroll", "type", "key", "wait"]

    private let vmName: String
    private let actions: any AgentActions
    private let readPNG: (String) throws -> Data

    public init(
        vmName: String, actions: any AgentActions,
        readPNG: @escaping (String) throws -> Data = { try Data(contentsOf: URL(fileURLWithPath: $0)) }
    ) {
        self.vmName = vmName
        self.actions = actions
        self.readPNG = readPNG
    }

    /// Reads `input` line by line until EOF, answering each request on `output`. Blocks the
    /// calling thread (each tool call waits for the owner); empty lines are skipped.
    public func run(input: FileHandle, output: FileHandle) {
        var buffer = Data()
        func handleLines() {
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
                buffer = Data(buffer[buffer.index(after: newline)...])
                emit(line, to: output)
            }
        }
        while true {
            let chunk = input.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            handleLines()
        }
        if !buffer.isEmpty { emit(String(decoding: buffer, as: UTF8.self), to: output) }
    }

    private func emit(_ line: String, to output: FileHandle) {
        guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            let reply = handle(line: line)
        else { return }
        output.write(Data((reply + "\n").utf8))
    }

    /// The response to one request line, or nil for a notification (a message without `id`).
    public func handle(line: String) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)),
            let message = object as? [String: Any]
        else { return Self.error(id: NSNull(), code: -32700, message: "Parse error") }
        guard let id = message["id"] else { return nil }
        guard id is String || id is NSNumber, let method = message["method"] as? String else {
            return Self.error(id: id is NSNull ? id : NSNull(), code: -32600, message: "Invalid Request")
        }
        let params = message["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            let asked = params["protocolVersion"] as? String ?? ""
            return Self.result(id: id, [
                "protocolVersion": Self.protocolVersions.contains(asked) ? asked : Self.protocolVersions[0],
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": "nido", "version": NidoVersion.current],
                "instructions": "Drives the screen of the macOS VM \(vmName). Take a screenshot first; coordinates are in pixels of the latest screenshot.",
            ])
        case "ping":
            return Self.result(id: id, [:])
        case "tools/list":
            return Self.result(id: id, ["tools": Self.tools])
        case "tools/call":
            guard let name = params["name"] as? String else {
                return Self.error(id: id, code: -32602, message: "Invalid params: missing tool name")
            }
            return Self.result(id: id, callTool(name, params["arguments"] as? [String: Any] ?? [:]))
        default:
            return Self.error(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    // MARK: - Tools

    private func callTool(_ name: String, _ arguments: [String: Any]) -> [String: Any] {
        do {
            switch name {
            case "wait":
                let args = try Arguments(arguments, allowed: ["ms"])
                let ms = try args.integer("ms", in: 0...AgentProtocol.maxWaitMilliseconds)
                Thread.sleep(forTimeInterval: Double(ms) / 1000)
                return Self.text("ok")
            case "status":
                _ = try Arguments(arguments, allowed: [])
                let answer = send(.status)
                guard answer.ok else { return Self.failure(answer) }
                if let status = answer.status { return Self.text(Self.json(status)) }
                return Self.text("ok")
            case "screenshot":
                let args = try Arguments(arguments, allowed: ["max_long_edge"])
                let edge = try args.optionalInteger("max_long_edge", in: AgentProtocol.maxLongEdgeRange) ?? AgentProtocol.defaultMaxLongEdge
                return screenshot(send(.screenshot(maxLongEdge: edge)))
            case "click":
                let args = try Arguments(arguments, allowed: ["x", "y", "button", "count"])
                let button = try args.optionalString("button", in: ["left", "right"]).flatMap(MouseButton.init(rawValue:)) ?? .left
                return plain(send(.click(
                    x: try args.number("x"), y: try args.number("y"), button: button,
                    count: try args.optionalInteger("count", in: 1...3) ?? 1)))
            case "drag":
                let args = try Arguments(arguments, allowed: ["from_x", "from_y", "to_x", "to_y"])
                return plain(send(.drag(
                    fromX: try args.number("from_x"), fromY: try args.number("from_y"),
                    toX: try args.number("to_x"), toY: try args.number("to_y"))))
            case "scroll":
                let args = try Arguments(arguments, allowed: ["dx", "dy", "x", "y"])
                let x = try args.optionalNumber("x")
                let y = try args.optionalNumber("y")
                guard (x == nil) == (y == nil) else { throw Arguments.Invalid("x and y go together: give both or neither") }
                return plain(send(.scroll(dx: try args.number("dx"), dy: try args.number("dy"), x: x, y: y)))
            case "type":
                let args = try Arguments(arguments, allowed: ["text"])
                return plain(send(.type(text: try args.string("text"))))
            case "key":
                let args = try Arguments(arguments, allowed: ["combo"])
                let combo = try args.string("combo")
                do { try KeyMap.validateCombo(combo) } catch {
                    throw Arguments.Invalid("combo \"\(combo)\" is not a valid key combination: \(error.localizedDescription)")
                }
                return plain(send(.key(combo: combo)))
            default:
                return Self.toolError(.badRequest, "Unknown tool: \(name)")
            }
        } catch let invalid as Arguments.Invalid {
            return Self.toolError(.badRequest, "Invalid arguments: \(invalid.message)")
        } catch {
            return Self.toolError(.internalError, error.localizedDescription)
        }
    }

    /// The owner's answer to `action`, cleaned of control characters (the guest wrote part of it);
    /// a thrown error becomes a failed answer, never a crash.
    private func send(_ action: AgentAction) -> AgentAnswer {
        do {
            return try actions.send(action).cleaned
        } catch let failure as AgentFailure {
            return AgentAnswer.failure(failure.code, failure.message).cleaned
        } catch {
            return AgentAnswer.failure(.internalError, error.localizedDescription).cleaned
        }
    }

    private func plain(_ answer: AgentAnswer) -> [String: Any] {
        answer.ok ? Self.text("ok") : Self.failure(answer)
    }

    private func screenshot(_ answer: AgentAnswer) -> [String: Any] {
        guard answer.ok else { return Self.failure(answer) }
        guard let path = answer.path, let image = answer.image, let screen = answer.screen else {
            return Self.toolError(.internalError, "The owner answered without a screenshot.")
        }
        guard let png = try? readPNG(path) else {
            return Self.toolError(.internalError, "The screenshot file could not be read.")
        }
        return [
            "content": [
                ["type": "image", "data": png.base64EncodedString(), "mimeType": "image/png"],
                ["type": "text", "text": "\(image.width)x\(image.height) screenshot of a \(screen.width)x\(screen.height)-point screen"],
            ]
        ]
    }

    private static func failure(_ answer: AgentAnswer) -> [String: Any] {
        let code = answer.error ?? .internalError
        guard let message = answer.message, !message.isEmpty else { return text(code.rawValue, isError: true) }
        return toolError(code, message)
    }

    /// A tool error: `<code>: <message>`.
    private static func toolError(_ code: AgentErrorCode, _ message: String) -> [String: Any] {
        text("\(code.rawValue): \(message)", isError: true)
    }

    private static func text(_ text: String, isError: Bool = false) -> [String: Any] {
        var result: [String: Any] = ["content": [["type": "text", "text": text]]]
        if isError { result["isError"] = true }
        return result
    }

    private static func json(_ status: AgentStatus) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: (try? encoder.encode(status)) ?? Data("{}".utf8), as: UTF8.self)
    }

    // MARK: - Arguments

    /// The arguments of one tool call, checked by hand against its schema: unknown names, missing
    /// fields, wrong types (a boolean is not a number) and out-of-range values throw `Invalid`.
    private struct Arguments {
        struct Invalid: Error { let message: String; init(_ message: String) { self.message = message } }

        let values: [String: Any]

        init(_ values: [String: Any], allowed: Set<String>) throws {
            if let extra = values.keys.sorted().first(where: { !allowed.contains($0) }) {
                throw Invalid("unknown argument \"\(extra)\"")
            }
            self.values = values
        }

        func number(_ key: String) throws -> Double {
            guard let value = try optionalNumber(key) else { throw Invalid("\"\(key)\" is required") }
            return value
        }

        func optionalNumber(_ key: String) throws -> Double? {
            guard let raw = values[key], !(raw is NSNull) else { return nil }
            guard let number = raw as? NSNumber, !Self.isBoolean(number), number.doubleValue.isFinite else {
                throw Invalid("\"\(key)\" must be a number")
            }
            return number.doubleValue
        }

        func integer(_ key: String, in range: ClosedRange<Int>) throws -> Int {
            guard let value = try optionalInteger(key, in: range) else { throw Invalid("\"\(key)\" is required") }
            return value
        }

        func optionalInteger(_ key: String, in range: ClosedRange<Int>) throws -> Int? {
            guard let number = try optionalNumber(key) else { return nil }
            guard number == number.rounded(), let value = Int(exactly: number) else {
                throw Invalid("\"\(key)\" must be an integer")
            }
            guard range.contains(value) else {
                throw Invalid("\"\(key)\" must be between \(range.lowerBound) and \(range.upperBound)")
            }
            return value
        }

        func string(_ key: String) throws -> String {
            guard let raw = values[key] else { throw Invalid("\"\(key)\" is required") }
            guard let value = raw as? String else { throw Invalid("\"\(key)\" must be a string") }
            return value
        }

        func optionalString(_ key: String, in allowed: [String]) throws -> String? {
            guard values[key] != nil else { return nil }
            let value = try string(key)
            guard allowed.contains(value) else {
                throw Invalid("\"\(key)\" must be one of \(allowed.joined(separator: ", "))")
            }
            return value
        }

        private static func isBoolean(_ number: NSNumber) -> Bool {
            CFGetTypeID(number) == CFBooleanGetTypeID()
        }
    }

    // MARK: - Tool definitions

    private static let inPixels = "in pixels of the latest screenshot"

    private static func schema(_ properties: [String: Any], required: [String]) -> [String: Any] {
        ["type": "object", "properties": properties, "required": required, "additionalProperties": false]
    }

    private static func coordinate(_ what: String) -> [String: Any] {
        ["type": "number", "description": "\(what), \(inPixels)"]
    }

    private static var tools: [[String: Any]] { [
        [
            "name": "status",
            "description": "Report whether Nido Agent in the VM is ready (screen recording and accessibility permissions, screen size). If the result says it is waiting for login or Nido Agent, a human must act: log in to the VM or approve Nido Agent there; do not retry in a loop.",
            "inputSchema": schema([:], required: []),
        ],
        [
            "name": "screenshot",
            "description": "Take a screenshot of the VM's screen. Take one before clicking, and again after an action to see its effect. All coordinates of the other tools are \(inPixels).",
            "inputSchema": schema([
                "max_long_edge": ["type": "integer", "minimum": AgentProtocol.maxLongEdgeRange.lowerBound, "maximum": AgentProtocol.maxLongEdgeRange.upperBound,
                    "description": "Longest side of the returned image in pixels (default \(AgentProtocol.defaultMaxLongEdge))."]
            ], required: []),
        ],
        [
            "name": "click",
            "description": "Click at a point of the VM's screen. Coordinates are \(inPixels).",
            "inputSchema": schema([
                "x": coordinate("Horizontal position"), "y": coordinate("Vertical position"),
                "button": ["type": "string", "enum": ["left", "right"], "description": "Mouse button (default left)."],
                "count": ["type": "integer", "minimum": 1, "maximum": 3, "description": "Number of clicks, 2 for a double click (default 1)."],
            ], required: ["x", "y"]),
        ],
        [
            "name": "drag",
            "description": "Press at one point, move to another and release. Coordinates are \(inPixels).",
            "inputSchema": schema([
                "from_x": coordinate("Start, horizontal"), "from_y": coordinate("Start, vertical"),
                "to_x": coordinate("End, horizontal"), "to_y": coordinate("End, vertical"),
            ], required: ["from_x", "from_y", "to_x", "to_y"]),
        ],
        [
            "name": "scroll",
            "description": "Scroll by a distance, optionally at a point (x and y together; coordinates are \(inPixels)). Negative dy scrolls down.",
            "inputSchema": schema([
                "dx": ["type": "number", "description": "Horizontal scroll amount."],
                "dy": ["type": "number", "description": "Vertical scroll amount."],
                "x": coordinate("Horizontal position of the pointer"), "y": coordinate("Vertical position of the pointer"),
            ], required: ["dx", "dy"]),
        ],
        [
            "name": "type",
            "description": "Type text on the VM's keyboard, into the focused field. Use the key tool for Return, Tab, shortcuts.",
            "inputSchema": schema(["text": ["type": "string", "description": "The text to type."]], required: ["text"]),
        ],
        [
            "name": "key",
            "description": "Press a key or a key combination, for example \"return\", \"cmd+space\", \"cmd+shift+4\".",
            "inputSchema": schema(["combo": ["type": "string", "description": "Keys joined by +, modifiers first."]], required: ["combo"]),
        ],
        [
            "name": "wait",
            "description": "Wait before the next step, for example for a window to open. Done by Nido itself; the VM is not contacted.",
            "inputSchema": schema([
                "ms": ["type": "integer", "minimum": 0, "maximum": AgentProtocol.maxWaitMilliseconds, "description": "Milliseconds, 0 to \(AgentProtocol.maxWaitMilliseconds)."]
            ], required: ["ms"]),
        ],
    ] }

    // MARK: - JSON-RPC envelopes

    private static func result(id: Any, _ result: [String: Any]) -> String {
        encode(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private static func error(id: Any, code: Int, message: String) -> String {
        encode(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
    }

    private static func encode(_ object: [String: Any]) -> String {
        let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data ?? Data("{}".utf8), as: UTF8.self)
    }
}
