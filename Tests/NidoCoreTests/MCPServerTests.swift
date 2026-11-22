// SPDX-License-Identifier: Apache-2.0
import Foundation
import NidoAgentKit
import Testing

@_spi(Testing) @testable import NidoCore

/// An `AgentActions` that records what it is asked and answers with a canned answer (or throws).
private final class FakeActions: AgentActions, @unchecked Sendable {
    var answer = AgentAnswer(ok: true)
    var failure: (any Error)?
    private(set) var sent: [AgentAction] = []

    func send(_ action: AgentAction) throws -> AgentAnswer {
        sent.append(action)
        if let failure { throw failure }
        return answer
    }

    /// What `putFile` was given: the guest path and the bytes.
    private(set) var put: [(path: String, data: Data)] = []
    /// What `getFile` was asked: the guest path and the bound.
    private(set) var got: [(path: String, maxBytes: Int)] = []
    /// The bytes `getFile` answers with when `answer` is ok.
    var fileData: Data?

    func putFile(_ data: Data, to path: String) throws -> AgentAnswer {
        put.append((path, data))
        if let failure { throw failure }
        return answer
    }

    func getFile(_ path: String, maxBytes: Int) throws -> (AgentAnswer, Data?) {
        got.append((path, maxBytes))
        if let failure { throw failure }
        return (answer, answer.ok ? fileData : nil)
    }
}

/// An `AgentNetworkReporting` with canned lines: `blocks` are handed out one per call.
private final class FakeNetwork: AgentNetworkReporting, @unchecked Sendable {
    var blocks: [String?] = []
    var status: String?
    func newBlocksLine() -> String? { blocks.isEmpty ? nil : blocks.removeFirst() }
    func statusLine() -> String? { status }
}

@Suite(.italian) struct MCPServerTests {
    private let png = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3])

    private func server(_ fake: FakeActions) -> MCPServer {
        let data = png
        return MCPServer(vmName: "mac", actions: fake, readPNG: { path in
            guard path == "/shots/1.png" else { throw CocoaError(.fileReadNoSuchFile) }
            return data
        })
    }

    private func call(_ server: MCPServer, _ line: String) throws -> [String: Any] {
        let reply = try #require(server.handle(line: line))
        return try #require(try JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any])
    }

    private func tool(_ server: MCPServer, _ name: String, _ arguments: String = "{}") throws -> [String: Any] {
        let reply = try call(server, #"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"\#(name)","arguments":\#(arguments)}}"#)
        return try #require(reply["result"] as? [String: Any])
    }

    private func texts(_ result: [String: Any]) -> [String] {
        ((result["content"] as? [[String: Any]]) ?? []).compactMap { $0["text"] as? String }
    }

    @Test func initializeNegotiates() throws {
        let s = server(FakeActions())
        func initialize(_ version: String) throws -> [String: Any] {
            let reply = try call(s, #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"\#(version)","capabilities":{},"clientInfo":{"name":"t","version":"0"}}}"#)
            return try #require(reply["result"] as? [String: Any])
        }
        let known = try initialize("2025-06-18")
        #expect(known["protocolVersion"] as? String == "2025-06-18")
        #expect((known["capabilities"] as? [String: Any])?["tools"] != nil)
        let info = try #require(known["serverInfo"] as? [String: Any])
        #expect(info["name"] as? String == "nido")
        #expect(info["version"] as? String == NidoVersion.current)
        #expect(try initialize("1999-01-01")["protocolVersion"] as? String == "2025-11-25")
    }

    @Test func listsTheTools() throws {
        let reply = try call(server(FakeActions()), #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
        let tools = try #require((reply["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        #expect(tools.compactMap { $0["name"] as? String } == [
            "status", "screenshot", "zoom", "ui_tree", "click", "drag", "scroll", "type", "key", "wait",
            "checkpoint", "rollback", "list_checkpoints", "put_file", "get_file", "list_files",
        ])
        for tool in tools {
            let schema = try #require(tool["inputSchema"] as? [String: Any])
            #expect(schema["type"] as? String == "object")
            #expect(schema["additionalProperties"] as? Bool == false)
        }
        let click = try #require(tools.first { $0["name"] as? String == "click" })
        #expect((click["description"] as? String)?.contains("in pixels of the latest screenshot") == true)
    }

    @Test func screenshotIsImageBlock() throws {
        let fake = FakeActions()
        fake.answer = AgentAnswer(ok: true, path: "/shots/1.png", image: PixelSize(1280, 800), screen: ScreenSize(width: 1440, height: 900))
        let result = try tool(server(fake), "screenshot")
        #expect(result["isError"] as? Bool != true)
        let content = try #require(result["content"] as? [[String: Any]])
        #expect(content[0]["type"] as? String == "image")
        #expect(content[0]["data"] as? String == png.base64EncodedString())
        #expect(content[0]["mimeType"] as? String == "image/png")
        #expect(content[1]["text"] as? String == "1280x800 screenshot of a 1440x900-point screen")
        #expect(fake.sent == [.screenshot(maxLongEdge: 1280)])
    }

    @Test func zoomToolMapsAndAnswersWithImage() throws {
        let fake = FakeActions()
        fake.answer = AgentAnswer(ok: true, path: "/shots/1.png", image: PixelSize(400, 200), screen: ScreenSize(width: 1440, height: 900))
        let s = server(fake)
        let result = try tool(s, "zoom", #"{"x":10,"y":20,"width":300,"height":150}"#)
        #expect(fake.sent == [.zoom(x: 10, y: 20, width: 300, height: 150, maxLongEdge: AgentProtocol.defaultMaxLongEdge)])
        let content = try #require(result["content"] as? [[String: Any]])
        #expect(content[0]["type"] as? String == "image")
        #expect(content[1]["text"] as? String
            == "400x200 zoom of the region 10,20,300,150 of the latest screenshot; click coordinates still refer to the latest screenshot")
        _ = try tool(s, "zoom", #"{"x":0,"y":0,"width":5,"height":5,"max_long_edge":640}"#)
        #expect(fake.sent.last == .zoom(x: 0, y: 0, width: 5, height: 5, maxLongEdge: 640))
    }

    @Test func uiTreeToolAnswersWithCompactText() throws {
        let fake = FakeActions()
        fake.answer = AgentAnswer(ok: true, tree: UITree(app: "Notes", elements: [
            UIElement(id: 0, role: "button", name: "Save", value: nil, enabled: false, focused: false,
                      frame: PixelRect(x: 10, y: 20, w: 80, h: 24)),
            UIElement(id: 1, role: "textField", name: nil, value: "hello", enabled: true, focused: true,
                      frame: PixelRect(x: 5, y: 60, w: 300, h: 22)),
            UIElement(id: 2, role: "textField", name: "To", value: "bob", enabled: true, focused: false,
                      frame: PixelRect(x: 0, y: 0, w: 1, h: 1)),
        ], truncated: false))
        let s = server(fake)
        let result = try tool(s, "ui_tree")
        #expect(fake.sent == [.uiTree(maxElements: AgentProtocol.defaultUITreeElements)])
        #expect(result["isError"] as? Bool != true)
        #expect(texts(result) == [
            "Notes: 3 elements (latest screenshot pixels; click the centre of a frame)\n"
                + "#0 button \"Save\" 10,20 80x24 disabled\n"
                + "#1 textField = \"hello\" 5,60 300x22 focused\n"
                + "#2 textField \"To\" = \"bob\" 0,0 1x1"
        ])
        _ = try tool(s, "ui_tree", #"{"max_elements":50}"#)
        #expect(fake.sent.last == .uiTree(maxElements: 50))
        fake.answer = AgentAnswer(ok: true, tree: UITree(app: "Notes", elements: [], truncated: true))
        #expect(texts(try tool(s, "ui_tree")) == ["Notes: 0 elements (latest screenshot pixels; click the centre of a frame) \u{2014} truncated"])
    }

    @Test func uiTreeOneLinePerElement() throws {
        let fake = FakeActions()
        fake.answer = AgentAnswer(ok: true, tree: UITree(app: "A\nB", elements: [
            UIElement(id: 0, role: "button", name: "Sa\u{1B}[31mve\nNow", value: nil, enabled: true, focused: false,
                      frame: PixelRect(x: 1, y: 2, w: 3, h: 4)),
        ], truncated: false))
        let text = try #require(texts(try tool(server(fake), "ui_tree")).first)
        #expect(text.split(separator: "\n").count == 2)
        #expect(!text.contains("\u{1B}"))
    }

    /// A name or value cannot close its quotes and print a fake frame: `"` and `\` are escaped.
    @Test func uiTreeEscapesQuotes() throws {
        let fake = FakeActions()
        fake.answer = AgentAnswer(ok: true, tree: UITree(app: "Safari", elements: [
            UIElement(id: 0, role: "link", name: #"Pay" 100,200 10x10"#, value: #"a\" b"#, enabled: true,
                      focused: false, frame: PixelRect(x: 1, y: 2, w: 3, h: 4)),
        ], truncated: false))
        let text = try #require(texts(try tool(server(fake), "ui_tree")).first)
        let line = try #require(text.split(separator: "\n").last)
        #expect(line == #"#0 link "Pay\" 100,200 10x10" = "a\\\" b" 1,2 3x4"#)
    }

    @Test func uiTreeNeverShowsASecureValue() throws {
        let fake = FakeActions()
        fake.answer = AgentAnswer(ok: true, tree: UITree(app: "Safari", elements: [
            UIElement(id: 0, role: "secureTextField", name: "Password", value: "hunter2", enabled: true, focused: true,
                      frame: PixelRect(x: 1, y: 2, w: 3, h: 4)),
        ], truncated: false))
        let text = try #require(texts(try tool(server(fake), "ui_tree")).first)
        #expect(!text.contains("hunter2"))
        #expect(text.contains("secureTextField \"Password\" 1,2 3x4 focused"))
    }

    @Test func uiTreeToolRefusesBadArguments() throws {
        let fake = FakeActions()
        let s = server(fake)
        for bad in [#"{"max_elements":0}"#, #"{"max_elements":1001}"#, #"{"max_elements":1.5}"#, #"{"max":5}"#] {
            #expect(try tool(s, "ui_tree", bad)["isError"] as? Bool == true, "\(bad)")
        }
        #expect(fake.sent.isEmpty)
        #expect(MCPServer.toolNames.contains("ui_tree"))
    }

    @Test func uiTreeWithoutTreeIsToolError() throws {
        let fake = FakeActions()
        fake.answer = AgentAnswer(ok: true)
        #expect(try tool(server(fake), "ui_tree")["isError"] as? Bool == true)
        fake.answer = AgentAnswer.failure(.versionMismatch, "too old")
        #expect(texts(try tool(server(fake), "ui_tree")) == ["versionMismatch: too old"])
    }

    @Test func zoomToolRefusesBadArguments() throws {
        let fake = FakeActions()
        let s = server(fake)
        for bad in [
            #"{"x":1,"y":2,"width":3}"#, #"{"x":-1,"y":2,"width":3,"height":4}"#, #"{"x":1,"y":2,"width":0,"height":4}"#,
            #"{"x":1,"y":2,"width":3,"height":4,"max_long_edge":10}"#, #"{"x":1,"y":2,"width":3,"height":4,"max_long_edge":9999}"#,
            #"{"x":1.5,"y":2,"width":3,"height":4}"#,
        ] {
            #expect(try tool(s, "zoom", bad)["isError"] as? Bool == true, "\(bad)")
        }
        #expect(fake.sent.isEmpty)
        let list = try call(s, #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
        let tools = try #require((list["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        let zoom = try #require(tools.first { $0["name"] as? String == "zoom" })
        let schema = try #require(zoom["inputSchema"] as? [String: Any])
        #expect(schema["required"] as? [String] == ["x", "y", "width", "height"])
    }

    @Test func screenshotWithoutReadablePathIsToolError() throws {
        let fake = FakeActions()
        fake.answer = AgentAnswer(ok: true, path: "/nope.png", image: PixelSize(1, 1), screen: ScreenSize(width: 1, height: 1))
        #expect(try tool(server(fake), "screenshot")["isError"] as? Bool == true)
        fake.answer = AgentAnswer(ok: true)
        #expect(try tool(server(fake), "screenshot")["isError"] as? Bool == true)
    }

    @Test func notReadyIsToolError() throws {
        let fake = FakeActions()
        fake.answer = .failure(.notReady, "waiting for login or Nido Agent")
        let result = try tool(server(fake), "click", #"{"x":1,"y":2}"#)
        #expect(result["isError"] as? Bool == true)
        #expect(texts(result) == ["notReady: waiting for login or Nido Agent"])
    }

    /// The helper's own reason (a locked screen) reaches the model as it is, not a generic text.
    @Test func lockedScreenReachesTheModel() throws {
        let fake = FakeActions()
        fake.answer = .failure(.notReady, "the VM's screen is locked: log in through its window")
        for (name, arguments) in [("screenshot", "{}"), ("zoom", #"{"x":1,"y":2,"width":30,"height":40}"#),
                                  ("ui_tree", "{}")] {
            let result = try tool(server(fake), name, arguments)
            #expect(result["isError"] as? Bool == true)
            #expect(texts(result) == ["notReady: the VM's screen is locked: log in through its window"])
        }
    }

    /// SECURITY: what the guest wrote in an answer reaches the model without control characters.
    @Test func guestTextIsCleaned() throws {
        let fake = FakeActions()
        fake.answer = .failure(.internalError, "x\u{1B}]52;c;eA==\u{07}\u{9B}y")
        let failed = try tool(server(fake), "click", #"{"x":1,"y":2}"#)
        fake.answer = AgentAnswer(ok: true, status: AgentStatus(
            helperVersion: "1\u{85}0", protocolVersion: 1, screenRecording: true, accessibility: true,
            screen: ScreenSize(width: 1, height: 1)))
        let status = try tool(server(fake), "status")
        for text in texts(failed) + texts(status) {
            #expect(!text.unicodeScalars.contains { $0.properties.generalCategory == .control })
        }
        #expect(texts(status).first?.contains(#""helperVersion":"1 0""#) == true)
    }

    private func readyStatus() -> AgentAnswer {
        AgentAnswer(ok: true, status: AgentStatus(
            helperVersion: "1", protocolVersion: 1, screenRecording: true, accessibility: true,
            screen: ScreenSize(width: 2, height: 3)))
    }

    /// `nido mcp --fresh`: a successful `status` tells the model which copy it drives.
    @Test func statusCarriesTheNote() throws {
        let fake = FakeActions()
        fake.answer = readyStatus()
        let s = MCPServer(vmName: "mac-fresh-1a2b", actions: fake, note: "This Mac is a copy.")
        let result = try tool(s, "status")
        #expect(result["isError"] as? Bool != true)
        let lines = texts(result)
        #expect(lines.count == 2)
        #expect(lines.first?.contains(#""helperVersion":"1""#) == true)
        #expect(lines.last == "This Mac is a copy.")

        fake.answer = .failure(.notReady, "waiting")
        #expect(texts(try tool(s, "status")) == ["notReady: waiting"])
    }

    @Test func instructionsCarryTheNote() throws {
        let s = MCPServer(vmName: "mac-fresh-1a2b", actions: FakeActions(), note: "This Mac is a copy.")
        let reply = try call(s, #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#)
        let result = try #require(reply["result"] as? [String: Any])
        #expect(result["instructions"] as? String
            == "Drives the screen of the macOS VM mac-fresh-1a2b. Take a screenshot first; coordinates are in pixels of the latest screenshot. This Mac is a copy.")
    }

    @Test func noNoteNoChange() throws {
        let fake = FakeActions()
        fake.answer = readyStatus()
        let s = server(fake)
        let lines = texts(try tool(s, "status"))
        #expect(lines.count == 1)
        #expect(lines.first?.contains(#""screen":{"height":3,"width":2}"#) == true)
        let reply = try call(s, #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#)
        #expect((reply["result"] as? [String: Any])?["instructions"] as? String
            == "Drives the screen of the macOS VM mac. Take a screenshot first; coordinates are in pixels of the latest screenshot.")
    }

    private func networked(_ fake: FakeActions, _ network: FakeNetwork, note: String? = nil) -> MCPServer {
        MCPServer(vmName: "mac", actions: fake, note: note, network: network)
    }

    @Test func blocksLineEndsEveryResult() throws {
        let fake = FakeActions()
        let network = FakeNetwork()
        network.blocks = ["Network: blocked a.example", "Network: blocked b.example"]
        let s = networked(fake, network)
        let ok = try tool(s, "click", #"{"x":1,"y":2}"#)
        #expect(texts(ok) == ["ok", "Network: blocked a.example"])
        #expect(ok["isError"] as? Bool != true)
        fake.answer = .failure(.notReady, "waiting")
        let failed = try tool(s, "click", #"{"x":1,"y":2}"#)
        #expect(failed["isError"] as? Bool == true)
        #expect(texts(failed) == ["notReady: waiting", "Network: blocked b.example"])
    }

    @Test func resultsWithoutBlocksAreUnchanged() throws {
        let plain = server(FakeActions())
        let withNetwork = MCPServer(vmName: "mac", actions: FakeActions(), network: FakeNetwork())
        let a = try tool(plain, "click", #"{"x":1,"y":2}"#)
        let b = try tool(withNetwork, "click", #"{"x":1,"y":2}"#)
        #expect(texts(a) == texts(b))
        #expect(texts(a) == ["ok"])
    }

    @Test func statusCarriesTheNetwork() throws {
        let fake = FakeActions()
        fake.answer = readyStatus()
        let network = FakeNetwork()
        network.status = "Network: controlled; no allowed domains"
        let withNote = texts(try tool(networked(fake, network, note: "A copy."), "status"))
        #expect(withNote.count == 3)
        #expect(withNote[1] == "A copy.")
        #expect(withNote[2] == "Network: controlled; no allowed domains")
        let without = texts(try tool(networked(fake, network), "status"))
        #expect(without.count == 2)
        #expect(without.last == "Network: controlled; no allowed domains")
        network.blocks = ["Network: blocked x.example"]
        let all = texts(try tool(networked(fake, network, note: "A copy."), "status"))
        #expect(all.count == 4)
        #expect(all.last == "Network: blocked x.example")
        fake.answer = .failure(.notReady, "waiting")
        #expect(texts(try tool(networked(fake, network), "status")) == ["notReady: waiting"])
    }

    @Test func badArgumentsStillReport() throws {
        let network = FakeNetwork()
        network.blocks = ["Network: blocked a.example", "Network: blocked b.example"]
        let s = networked(FakeActions(), network)
        let unknown = try tool(s, "nope")
        #expect(unknown["isError"] as? Bool == true)
        #expect(texts(unknown).last == "Network: blocked a.example")
        let bad = try tool(s, "click", #"{"x":"a","y":2}"#)
        #expect(bad["isError"] as? Bool == true)
        #expect(texts(bad).last == "Network: blocked b.example")
    }

    @Test func instructionsMentionTheNetwork() throws {
        func instructions(_ s: MCPServer) throws -> String {
            let reply = try call(s, #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#)
            return try #require((reply["result"] as? [String: Any])?["instructions"] as? String)
        }
        #expect(try instructions(networked(FakeActions(), FakeNetwork())).contains("Network: blocked"))
        #expect(try !instructions(server(FakeActions())).contains("Network: blocked"))
    }

    @Test func thrownErrorIsToolError() throws {
        let fake = FakeActions()
        fake.failure = AgentFailure(code: .internalError, message: "lost the connection")
        let result = try tool(server(fake), "status")
        #expect(result["isError"] as? Bool == true)
        #expect(texts(result) == ["internalError: lost the connection"])
    }

    @Test func clickArgumentsValidated() throws {
        let fake = FakeActions()
        let s = server(fake)
        for bad in [
            #"{"x":1,"y":2,"count":5}"#, #"{"x":1}"#, #"{"x":"1","y":2}"#, #"{"x":true,"y":2}"#,
            #"{"x":1,"y":2,"button":"middle"}"#, #"{"x":1,"y":2,"count":1.5}"#, #"{"x":1,"y":2,"extra":1}"#,
        ] {
            let result = try tool(s, "click", bad)
            #expect(result["isError"] as? Bool == true, "\(bad)")
        }
        #expect(fake.sent.isEmpty)
        let ok = try tool(s, "click", #"{"x":10,"y":20.5,"button":"right","count":2}"#)
        #expect(ok["isError"] as? Bool != true)
        #expect(fake.sent == [.click(x: 10, y: 20.5, button: .right, count: 2)])
    }

    @Test func otherToolsMapToActions() throws {
        let fake = FakeActions()
        let s = server(fake)
        _ = try tool(s, "drag", #"{"from_x":1,"from_y":2,"to_x":3,"to_y":4}"#)
        _ = try tool(s, "scroll", #"{"dx":0,"dy":-5}"#)
        _ = try tool(s, "scroll", #"{"dx":1,"dy":2,"x":3,"y":4}"#)
        _ = try tool(s, "type", #"{"text":"hi"}"#)
        _ = try tool(s, "key", #"{"combo":"cmd+space"}"#)
        fake.answer = AgentAnswer(ok: true, path: "/shots/1.png", image: PixelSize(1, 1), screen: ScreenSize(width: 1, height: 1))
        _ = try tool(s, "screenshot", #"{"max_long_edge":640}"#)
        #expect(fake.sent == [
            .drag(fromX: 1, fromY: 2, toX: 3, toY: 4), .scroll(dx: 0, dy: -5, x: nil, y: nil),
            .scroll(dx: 1, dy: 2, x: 3, y: 4), .type(text: "hi"), .key(combo: "cmd+space"),
            .screenshot(maxLongEdge: 640),
        ])
        // scroll with only one of x/y, bad combo, out-of-range edge: refused, nothing sent
        #expect(try tool(s, "scroll", #"{"dx":1,"dy":2,"x":3}"#)["isError"] as? Bool == true)
        #expect(try tool(s, "key", #"{"combo":"cmd+nonsense"}"#)["isError"] as? Bool == true)
        #expect(try tool(s, "screenshot", #"{"max_long_edge":10}"#)["isError"] as? Bool == true)
        #expect(fake.sent.count == 6)
    }

    @Test func keyComboWithGuestOnlyCharacterIsSent() throws {
        let fake = FakeActions()
        let s = server(fake)
        #expect(try tool(s, "key", #"{"combo":"cmd+é"}"#)["isError"] as? Bool != true)
        #expect(fake.sent == [.key(combo: "cmd+é")])
    }

    @Test func waitStaysInProcess() throws {
        let fake = FakeActions()
        let s = server(fake)
        #expect(try tool(s, "wait", #"{"ms":1}"#)["isError"] as? Bool != true)
        #expect(try tool(s, "wait", #"{"ms":10001}"#)["isError"] as? Bool == true)
        #expect(try tool(s, "wait", #"{"ms":-1}"#)["isError"] as? Bool == true)
        #expect(try tool(s, "wait")["isError"] as? Bool == true)
        #expect(fake.sent.isEmpty)
    }

    @Test func unknownToolIsToolError() throws {
        #expect(try tool(server(FakeActions()), "format_disk")["isError"] as? Bool == true)
    }

    /// Every tool error starts with a stable code the model can act on, whatever the language of
    /// the message after it.
    @Test func toolErrorsStartWithTheirCode() throws {
        let fake = FakeActions()
        fake.answer = .failure(.permissionMissing, "Nido Agent braucht die Berechtigung")
        #expect(texts(try tool(server(fake), "type", #"{"text":"x"}"#)) == ["permissionMissing: Nido Agent braucht die Berechtigung"])
        fake.answer = AgentAnswer(ok: false, error: .screenChanged)
        #expect(texts(try tool(server(fake), "click", #"{"x":1,"y":2}"#)) == ["screenChanged"])
        let bad = texts(try tool(server(fake), "click", #"{"x":"one","y":2}"#))
        #expect(bad.first?.hasPrefix("badRequest: ") == true)
        #expect(texts(try tool(server(fake), "format_disk")).first?.hasPrefix("badRequest: ") == true)
        fake.answer = AgentAnswer(ok: true)
        #expect(texts(try tool(server(fake), "screenshot")).first?.hasPrefix("internalError: ") == true)
    }

    @Test func notificationGetsNoReply() {
        #expect(server(FakeActions()).handle(line: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
    }

    @Test func pingAndUnknownMethod() throws {
        let s = server(FakeActions())
        let ping = try call(s, #"{"jsonrpc":"2.0","id":"a","method":"ping"}"#)
        #expect(ping["id"] as? String == "a")
        #expect((ping["result"] as? [String: Any])?.isEmpty == true)
        let unknown = try call(s, #"{"jsonrpc":"2.0","id":3,"method":"resources/list"}"#)
        #expect((unknown["error"] as? [String: Any])?["code"] as? Int == -32601)
    }

    @Test func garbageIsParseError() throws {
        let reply = try call(server(FakeActions()), "{")
        #expect((reply["error"] as? [String: Any])?["code"] as? Int == -32700)
        #expect(reply["id"] is NSNull)
    }

    @Test func runAnswersLinesUntilEOF() throws {
        let input = Pipe()
        let output = Pipe()
        let s = server(FakeActions())
        input.fileHandleForWriting.write(Data("""
            {"jsonrpc":"2.0","id":1,"method":"ping"}
            {"jsonrpc":"2.0","method":"notifications/initialized"}

            {"jsonrpc":"2.0","id":2,"method":"ping"}

            """.utf8))
        try input.fileHandleForWriting.close()
        s.run(input: input.fileHandleForReading, output: output.fileHandleForWriting)
        try output.fileHandleForWriting.close()
        let lines = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(separator: "\n")
        #expect(lines.count == 2)
    }

    /// A client gone mid-session (its end of stdout closed, SIGPIPE ignored as `nido mcp --fresh`
    /// does) ends the loop like EOF: no Objective-C exception, no later request handled.
    @Test func closedOutputEndsTheLoop() throws {
        let previous = signal(SIGPIPE, SIG_IGN)
        defer { signal(SIGPIPE, previous) }
        let input = Pipe()
        let output = Pipe()
        let fake = FakeActions()
        fake.answer = readyStatus()
        input.fileHandleForWriting.write(Data("""
            {"jsonrpc":"2.0","id":1,"method":"ping"}
            {"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"status","arguments":{}}}

            """.utf8))
        try input.fileHandleForWriting.close()
        try output.fileHandleForReading.close()
        server(fake).run(input: input.fileHandleForReading, output: output.fileHandleForWriting)
        #expect(fake.sent.isEmpty)
    }
}

// MARK: - Checkpoints

extension MCPServerTests {
    @Test func checkpointToolsAreListed() throws {
        for name in ["checkpoint", "rollback", "list_checkpoints"] {
            #expect(MCPServer.toolNames.contains(name), "\(name)")
        }
        let reply = try call(server(FakeActions()), #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
        let tools = try #require((reply["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        #expect(tools.compactMap { $0["name"] as? String } == MCPServer.toolNames)
        for name in ["checkpoint", "rollback"] {
            let tool = try #require(tools.first { $0["name"] as? String == name })
            let schema = try #require(tool["inputSchema"] as? [String: Any])
            let properties = try #require(schema["properties"] as? [String: Any])
            #expect((properties["name"] as? [String: Any])?["type"] as? String == "string")
            #expect((schema["required"] as? [String]) == [])
        }
    }

    /// `checkpoint` and `rollback` answer with the owner's message; the name is optional.
    @Test func checkpointAndRollbackMapToActions() throws {
        let fake = FakeActions()
        let s = server(fake)
        fake.answer = AgentAnswer(ok: true, message: "checkpoint before-brew saved in 4 s")
        let taken = try tool(s, "checkpoint", #"{"name":"before-brew"}"#)
        #expect(taken["isError"] as? Bool != true)
        #expect(texts(taken) == ["checkpoint before-brew saved in 4 s"])
        fake.answer = AgentAnswer(ok: true, message: "going back to x:\u{1B}[2J done")
        let back = try tool(s, "rollback")
        #expect(texts(back) == ["going back to x: [2J done"])
        _ = try tool(s, "checkpoint")
        _ = try tool(s, "rollback", #"{"name":"a1"}"#)
        #expect(fake.sent == [.checkpoint(name: "before-brew"), .rollback(name: nil), .checkpoint(name: nil), .rollback(name: "a1")])
        // A name that is not a string, or an unknown argument: refused, nothing sent.
        #expect(try tool(s, "checkpoint", #"{"name":5}"#)["isError"] as? Bool == true)
        #expect(try tool(s, "rollback", #"{"label":"x"}"#)["isError"] as? Bool == true)
        #expect(try tool(s, "list_checkpoints", #"{"name":"x"}"#)["isError"] as? Bool == true)
        #expect(fake.sent.count == 4)
        fake.answer = .failure(.notReady, "a checkpoint or rollback is in progress")
        let busy = try tool(s, "checkpoint")
        #expect(busy["isError"] as? Bool == true)
        #expect(texts(busy) == ["notReady: a checkpoint or rollback is in progress"])
    }

    /// One line per checkpoint, newest first as the owner lists them: the name and the local time.
    @Test func listCheckpointsText() throws {
        let fake = FakeActions()
        let s = MCPServer(vmName: "mac", actions: fake, timeZone: TimeZone(identifier: "Europe/Rome")!)
        fake.answer = AgentAnswer(ok: true, checkpoints: [
            AgentCheckpointInfo(name: "before-brew", createdAt: Date(timeIntervalSince1970: 1_800_003_600)),
            AgentCheckpointInfo(name: "agent-20270115-090000", createdAt: Date(timeIntervalSince1970: 1_800_000_000)),
        ])
        let listed = try tool(s, "list_checkpoints")
        #expect(listed["isError"] as? Bool != true)
        #expect(texts(listed) == ["before-brew 2027-01-15 10:00:00\nagent-20270115-090000 2027-01-15 09:00:00"])
        #expect(fake.sent == [.checkpoints])
        fake.answer = AgentAnswer(ok: true, checkpoints: [])
        #expect(texts(try tool(s, "list_checkpoints")) == [L10n.string("no agent checkpoints")])
        #expect(L10n.string("no agent checkpoints", language: "en") == "no agent checkpoints")
    }
}

// MARK: - Files

extension MCPServerTests {
    @Test func fileToolsAreListed() throws {
        for name in ["put_file", "get_file", "list_files"] {
            #expect(MCPServer.toolNames.contains(name), "\(name)")
        }
        #expect(MCPServer.maxInlineFileBytes == 1 << 20)
        let reply = try call(server(FakeActions()), #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
        let tools = try #require((reply["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        let put = try #require(tools.first { $0["name"] as? String == "put_file" })
        let schema = try #require(put["inputSchema"] as? [String: Any])
        #expect((schema["required"] as? [String]) == ["path"])
        let properties = try #require(schema["properties"] as? [String: Any])
        #expect(Set(properties.keys) == ["path", "text", "base64"])
        #expect((put["description"] as? String)?.contains("NidoTransfer") == true)
    }

    /// Text is written as UTF-8, base64 as its bytes; the answer names the path and the size.
    @Test func putFileSendsTextOrBase64() throws {
        let fake = FakeActions()
        let s = server(fake)
        fake.answer = AgentAnswer(ok: true, bytes: 6)
        let wrote = try tool(s, "put_file", #"{"path":"in/a.txt","text":"héllo"}"#)
        #expect(wrote["isError"] as? Bool != true)
        #expect(texts(wrote) == ["wrote in/a.txt (6 bytes)"])
        fake.answer = AgentAnswer(ok: true, bytes: 3)
        _ = try tool(s, "put_file", #"{"path":"b.bin","base64":"AAEC"}"#)
        // Line breaks in the base64 (as models wrap it) are ignored.
        _ = try tool(s, "put_file", #"{"path":"c.bin","base64":"AA\nEC"}"#)
        #expect(fake.put.map(\.path) == ["in/a.txt", "b.bin", "c.bin"])
        #expect(fake.put.map(\.data) == [Data("héllo".utf8), Data([0, 1, 2]), Data([0, 1, 2])])
        #expect(fake.sent.isEmpty)
    }

    /// Base64 without `=` padding (as models often send it) is accepted and gives the same bytes.
    @Test func putFileAcceptsUnpaddedBase64() throws {
        let fake = FakeActions()
        let s = server(fake)
        _ = try tool(s, "put_file", #"{"path":"a.bin","base64":"AAE"}"#)
        _ = try tool(s, "put_file", #"{"path":"b.bin","base64":"AA"}"#)
        _ = try tool(s, "put_file", #"{"path":"c.bin","base64":"AAEC\nAw"}"#)
        #expect(fake.put.map(\.data) == [Data([0, 1]), Data([0]), Data([0, 1, 2, 3])])
    }

    /// Both or neither of text and base64, invalid base64, a missing or non-string path: invalid
    /// arguments, nothing sent.
    @Test func putFileRefusesBadArguments() throws {
        let fake = FakeActions()
        let s = server(fake)
        for arguments in [
            #"{"path":"a","text":"x","base64":"AAEC"}"#, #"{"path":"a"}"#, #"{"path":"a","base64":"not base64!"}"#,
            #"{"path":"a","base64":"A"}"#, #"{"text":"x"}"#, #"{"path":5,"text":"x"}"#, #"{"path":"a","text":5}"#,
            #"{"path":"a","text":"x","mode":"0777"}"#,
        ] {
            let result = try tool(s, "put_file", arguments)
            #expect(result["isError"] as? Bool == true, "\(arguments)")
            #expect(texts(result).first?.hasPrefix("badRequest: Invalid arguments: ") == true, "\(arguments)")
        }
        #expect(fake.put.isEmpty)
    }

    /// More than 1 MiB is refused before anything is sent; exactly 1 MiB goes.
    @Test func putFileRefusesOverOneMiB() throws {
        let fake = FakeActions()
        let s = server(fake)
        let over = Data(repeating: 0x41, count: MCPServer.maxInlineFileBytes + 1).base64EncodedString()
        let refused = try tool(s, "put_file", #"{"path":"big.bin","base64":"\#(over)"}"#)
        #expect(refused["isError"] as? Bool == true)
        let hint = L10n.string("the file is larger than 1 MiB: use nido act \("mac") put-file to copy it from the Mac")
        #expect(texts(refused) == ["badRequest: \(hint)"])
        #expect(L10n.string("the file is larger than 1 MiB: use nido act \("mac") put-file to copy it from the Mac", language: "en")
            == "the file is larger than 1 MiB: use nido act mac put-file to copy it from the Mac")
        let text = String(repeating: "a", count: MCPServer.maxInlineFileBytes + 1)
        #expect(try tool(s, "put_file", #"{"path":"big.txt","text":"\#(text)"}"#)["isError"] as? Bool == true)
        #expect(fake.put.isEmpty)
        fake.answer = AgentAnswer(ok: true, bytes: MCPServer.maxInlineFileBytes)
        let exact = Data(repeating: 0x41, count: MCPServer.maxInlineFileBytes).base64EncodedString()
        #expect(try tool(s, "put_file", #"{"path":"ok.bin","base64":"\#(exact)"}"#)["isError"] as? Bool != true)
        #expect(fake.put.count == 1)
    }

    /// A refusal of the owner or the guest reaches the model with its code.
    @Test func putFileFailureIsToolError() throws {
        let fake = FakeActions()
        fake.answer = .failure(.badRequest, "the path may not have an empty, '.' or '..' component")
        let result = try tool(server(fake), "put_file", #"{"path":"../x","text":"x"}"#)
        #expect(result["isError"] as? Bool == true)
        #expect(texts(result) == ["badRequest: the path may not have an empty, '.' or '..' component"])
        fake.failure = AgentFailure(code: .internalError, message: "lost the connection")
        #expect(texts(try tool(server(fake), "put_file", #"{"path":"x","text":"x"}"#)) == ["internalError: lost the connection"])
    }

    /// Valid UTF-8 without NUL: a header line, then the text unchanged (controls included).
    @Test func getFileAnswersText() throws {
        let fake = FakeActions()
        let s = server(fake)
        let content = "line one\nperché\ttab \u{1B}[31mred\n"
        fake.fileData = Data(content.utf8)
        fake.answer = AgentAnswer(ok: true, bytes: fake.fileData!.count)
        let result = try tool(s, "get_file", #"{"path":"logs/out.txt"}"#)
        #expect(result["isError"] as? Bool != true)
        #expect(texts(result) == ["logs/out.txt (\(fake.fileData!.count) bytes)\n\(content)"])
        #expect(fake.got.map(\.path) == ["logs/out.txt"])
        #expect(fake.got.map(\.maxBytes) == [MCPServer.maxInlineFileBytes])
        fake.fileData = Data()
        fake.answer = AgentAnswer(ok: true, bytes: 0)
        #expect(texts(try tool(s, "get_file", #"{"path":"empty.txt"}"#)) == ["empty.txt (0 bytes)\n"])
    }

    /// A NUL byte or invalid UTF-8: base64, never mangled text.
    @Test func getFileAnswersBase64ForBinary() throws {
        let fake = FakeActions()
        let s = server(fake)
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00])
        fake.fileData = png
        fake.answer = AgentAnswer(ok: true, bytes: png.count)
        #expect(texts(try tool(s, "get_file", #"{"path":"shot.png"}"#)) == ["shot.png (10 bytes, base64)\n\(png.base64EncodedString())"])
        fake.fileData = Data("ab\u{0}c".utf8)
        #expect(texts(try tool(s, "get_file", #"{"path":"nul.txt"}"#)) == ["nul.txt (4 bytes, base64)\nYWIAYw=="])
        fake.fileData = Data([0x61, 0xC3, 0x28])
        #expect(texts(try tool(s, "get_file", #"{"path":"bad.txt"}"#)) == ["bad.txt (3 bytes, base64)\nYcMo"])
    }

    /// Over 1 MiB, whether the guest refuses it (its own wording, with the bound asked) or the
    /// bytes come back larger: the hint to use nido act.
    @Test func getFileOverOneMiBGivesTheHint() throws {
        let fake = FakeActions()
        let s = server(fake)
        let hint = L10n.string("the file is larger than 1 MiB: use nido act \("mac") get-file to copy it to the Mac")
        #expect(L10n.string("the file is larger than 1 MiB: use nido act \("mac") get-file to copy it to the Mac", language: "en")
            == "the file is larger than 1 MiB: use nido act mac get-file to copy it to the Mac")
        fake.answer = .failure(.badRequest, TransferFolder.tooLargeMessage(path: "big.zip", maxBytes: MCPServer.maxInlineFileBytes))
        let refused = try tool(s, "get_file", #"{"path":"big.zip"}"#)
        #expect(refused["isError"] as? Bool == true)
        #expect(texts(refused) == ["badRequest: \(hint)"])
        fake.fileData = Data(repeating: 1, count: MCPServer.maxInlineFileBytes + 1)
        fake.answer = AgentAnswer(ok: true, bytes: MCPServer.maxInlineFileBytes + 1)
        #expect(texts(try tool(s, "get_file", #"{"path":"big.zip"}"#)) == ["badRequest: \(hint)"])
        // Another refusal passes through as it is.
        fake.answer = .failure(.badRequest, "'x' does not exist in NidoTransfer")
        #expect(texts(try tool(s, "get_file", #"{"path":"x"}"#)) == ["badRequest: 'x' does not exist in NidoTransfer"])
        #expect(try tool(s, "get_file", #"{}"#)["isError"] as? Bool == true)
        #expect(try tool(s, "get_file", #"{"path":"x","max":1}"#)["isError"] as? Bool == true)
        #expect(fake.got.count == 3)
    }

    /// Contract with Nido Agent: the refusal the real `TransferFolder` throws for a 1 MiB + 1
    /// file, passed through as the owner would, gives the hint.
    @Test func getFileHintFollowsTheGuestsOwnRefusal() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nido-tests-mcp-transfer-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = TransferFolder(root: root)
        try folder.write(Data(repeating: 0x41, count: MCPServer.maxInlineFileBytes + 1), to: "out/big.bin")
        let refusal: TransferError
        do {
            _ = try folder.read("out/big.bin", maxBytes: MCPServer.maxInlineFileBytes)
            Issue.record("a file over 1 MiB was read")
            return
        } catch let error as TransferError {
            refusal = error
        }
        let fake = FakeActions()
        fake.answer = .failure(refusal.code, refusal.message)
        let result = try tool(server(fake), "get_file", #"{"path":"out/big.bin"}"#)
        #expect(result["isError"] as? Bool == true)
        let hint = L10n.string("the file is larger than 1 MiB: use nido act \("mac") get-file to copy it to the Mac")
        #expect(texts(result) == ["badRequest: \(hint)"])
        #expect(fake.got.map(\.maxBytes) == [MCPServer.maxInlineFileBytes])
    }

    /// The path shown in the header line is one line, whatever the agent sent.
    @Test func getFileHeaderIsOneLine() throws {
        let fake = FakeActions()
        fake.fileData = Data("x".utf8)
        fake.answer = AgentAnswer(ok: true, bytes: 1)
        let result = try tool(server(fake), "get_file", #"{"path":"a\nb.txt"}"#)
        #expect(texts(result) == ["a b.txt (1 bytes)\nx"])
        #expect(fake.got.map(\.path) == ["a\nb.txt"])
    }

    /// One line per entry, newest first as the guest lists them, folders with a `/`, local time,
    /// `… truncated` last; an empty folder has an answer of its own.
    @Test func listFilesText() throws {
        let fake = FakeActions()
        let s = MCPServer(vmName: "mac", actions: fake, timeZone: TimeZone(identifier: "Europe/Rome")!)
        fake.answer = AgentAnswer(ok: true, files: [
            TransferEntry(name: "report.pdf", kind: "file", size: 12345, modified: Date(timeIntervalSince1970: 1_800_003_600)),
            TransferEntry(name: "build", kind: "folder", size: 0, modified: Date(timeIntervalSince1970: 1_800_000_000)),
            TransferEntry(name: "a\u{1B}[2Jb", kind: "file", size: 1, modified: Date(timeIntervalSince1970: 1_799_999_940)),
        ], truncated: true)
        let listed = try tool(s, "list_files")
        #expect(listed["isError"] as? Bool != true)
        #expect(texts(listed) == [
            "report.pdf 12345 2027-01-15 10:00\nbuild/ 0 2027-01-15 09:00\na [2Jb 1 2027-01-15 08:59\n\u{2026} truncated"
        ])
        fake.answer = AgentAnswer(ok: true, files: [
            TransferEntry(name: "x", kind: "file", size: 2, modified: Date(timeIntervalSince1970: 1_800_000_000)),
        ], truncated: false)
        #expect(texts(try tool(s, "list_files", #"{"path":"build"}"#)) == ["x 2 2027-01-15 09:00"])
        #expect(fake.sent == [.listFiles(path: nil), .listFiles(path: "build")])
        fake.answer = AgentAnswer(ok: true, files: [])
        #expect(texts(try tool(s, "list_files")) == [L10n.string("the folder is empty")])
        #expect(L10n.string("the folder is empty", language: "en") == "the folder is empty")
        #expect(try tool(s, "list_files", #"{"path":3}"#)["isError"] as? Bool == true)
        #expect(fake.sent.count == 3)
        fake.answer = .failure(.badRequest, "'nope' does not exist in NidoTransfer")
        #expect(texts(try tool(s, "list_files", #"{"path":"nope"}"#)) == ["badRequest: 'nope' does not exist in NidoTransfer"])
    }
}
