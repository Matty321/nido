// SPDX-License-Identifier: Apache-2.0
import Foundation
import NidoAgentKit
import Testing

@testable import NidoCore

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
}

struct MCPServerTests {
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

    @Test func listsEightTools() throws {
        let reply = try call(server(FakeActions()), #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
        let tools = try #require((reply["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        #expect(tools.compactMap { $0["name"] as? String } == ["status", "screenshot", "click", "drag", "scroll", "type", "key", "wait"])
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
}
