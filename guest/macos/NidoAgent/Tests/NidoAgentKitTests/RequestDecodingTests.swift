// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import NidoAgentKit

private func decode(_ json: String) -> RequestDecoding {
    AgentDispatcher.decodeRequest(Data(json.utf8))
}

private func refusal(_ decoding: RequestDecoding) -> AgentReply? {
    if case .refused(let reply) = decoding { return reply }
    return nil
}

@Test func newerProtocolWithUnknownOpIsVersionMismatch() {
    let reply = refusal(decode(#"{"v":2,"op":"newthing"}"#))
    #expect(reply?.error == .versionMismatch)
    #expect(reply?.message?.contains("update Nido Agent") == true)
}

@Test func newerProtocolWithUnknownActionIsVersionMismatch() {
    let reply = refusal(decode(#"{"v":2,"action":{"op":"newthing"}}"#))
    #expect(reply?.error == .versionMismatch)
}

@Test func garbageAtCurrentVersionIsBadRequestWithFieldPath() {
    let reply = refusal(decode(#"{"v":1,"action":{"op":"click","x":"left","y":1,"button":"left","count":1}}"#))
    #expect(reply?.error == .badRequest)
    let message = reply?.message ?? ""
    #expect(message.contains("action.x"))
    #expect(!message.contains("DecodingError"))
    #expect(!message.contains("codingPath"))
    #expect(message.count < 200)
}

@Test func missingFieldIsBadRequest() {
    let reply = refusal(decode(#"{"v":1,"action":{"op":"click","x":1,"y":1,"button":"left"}}"#))
    #expect(reply?.error == .badRequest)
    #expect(reply?.message?.contains("action.count") == true)
}

@Test func unknownOpAtCurrentVersionIsBadRequest() {
    let reply = refusal(decode(#"{"v":1,"action":{"op":"explode"}}"#))
    #expect(reply?.error == .badRequest)
    #expect(reply?.message?.contains("explode") == true)
}

@Test func notJSONIsBadRequest() {
    let reply = refusal(decode("hello"))
    #expect(reply?.error == .badRequest)
    #expect(reply?.message?.isEmpty == false)
    #expect(reply?.message?.contains("DecodingError") == false)
}

@Test func missingVersionIsBadRequest() {
    #expect(refusal(decode(#"{"action":{"op":"status"}}"#))?.error == .badRequest)
}

@Test func validRequestDecodes() throws {
    let request = AgentRequest(action: .click(x: 1, y: 2, button: .left, count: 1),
                               image: PixelSize(1280, 800), screen: ScreenSize(width: 1440, height: 900))
    let data = try JSONEncoder().encode(request)
    #expect(AgentDispatcher.decodeRequest(data) == .request(request))
}

@Test func clipboardOpsDecodeFromJSON() {
    #expect(decode(#"{"v":1,"action":{"op":"readClipboard"}}"#) == .request(AgentRequest(action: .readClipboard)))
    #expect(decode(#"{"v":1,"action":{"op":"writeClipboard","text":"hi"}}"#)
        == .request(AgentRequest(action: .writeClipboard(text: "hi"))))
    #expect(refusal(decode(#"{"v":1,"action":{"op":"writeClipboard"}}"#))?.ok == false)
}

@Test func zoomRoundTrips() throws {
    let action = AgentAction.zoom(x: 10, y: 20, width: 300, height: 200, maxLongEdge: 1280)
    let data = try JSONEncoder().encode(action)
    #expect(try JSONDecoder().decode(AgentAction.self, from: data) == action)
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(AgentAction.self, from: Data(#"{"op":"zoom","x":1,"y":2,"width":3}"#.utf8))
    }
}

@Test func uiTreeRoundTrips() throws {
    let action = AgentAction.uiTree(maxElements: 300)
    let data = try JSONEncoder().encode(action)
    let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["op"] as? String == "uiTree")
    #expect(object["maxElements"] as? Int == 300)
    #expect(try JSONDecoder().decode(AgentAction.self, from: data) == action)
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(AgentAction.self, from: Data(#"{"op":"uiTree"}"#.utf8))
    }
}

@Test func uiTreeReplyRoundTrips() throws {
    let tree = UITree(app: "Finder", elements: [
        UIElement(id: 0, role: "button", name: "Save", value: nil, enabled: true, focused: false,
                  frame: PixelRect(x: 1, y: 2, w: 3, h: 4)),
    ], truncated: false)
    let reply = AgentReply(ok: true, tree: tree)
    let data = try JSONEncoder().encode(reply)
    #expect(try JSONDecoder().decode(AgentReply.self, from: data) == reply)
    // A reply without a tree has no "tree" key: older hosts read it as before.
    let plain = try #require(String(data: try JSONEncoder().encode(AgentReply(ok: true)), encoding: .utf8))
    #expect(!plain.contains("tree"))
}

@Test func checkpointOpsRoundTrip() throws {
    let actions: [AgentAction] = [
        .checkpoint(name: nil), .checkpoint(name: "before-install"),
        .rollback(name: nil), .rollback(name: "before-install"),
        .checkpoints,
    ]
    for action in actions {
        let data = try JSONEncoder().encode(action)
        #expect(try JSONDecoder().decode(AgentAction.self, from: data) == action)
    }
    let named = try #require(try JSONSerialization.jsonObject(
        with: JSONEncoder().encode(AgentAction.checkpoint(name: "x"))) as? [String: Any])
    #expect(named["op"] as? String == "checkpoint")
    #expect(named["name"] as? String == "x")
    // Without a name the key is left out.
    let plain = try #require(String(data: try JSONEncoder().encode(AgentAction.rollback(name: nil)), encoding: .utf8))
    #expect(plain == #"{"op":"rollback"}"#)
    #expect(try JSONDecoder().decode(AgentAction.self, from: Data(#"{"op":"checkpoints"}"#.utf8)) == .checkpoints)
}

@Test func fileOpsRoundTrip() throws {
    let actions: [AgentAction] = [
        .putFile(path: "dir/file.txt", size: 12),
        .getFile(path: "dir/file.txt", maxBytes: 1 << 20),
        .listFiles(path: nil), .listFiles(path: "dir"),
    ]
    for action in actions {
        let data = try JSONEncoder().encode(action)
        #expect(try JSONDecoder().decode(AgentAction.self, from: data) == action)
        let request = AgentRequest(action: action)
        #expect(AgentDispatcher.decodeRequest(try JSONEncoder().encode(request)) == .request(request))
    }
    let put = try #require(try JSONSerialization.jsonObject(
        with: JSONEncoder().encode(AgentAction.putFile(path: "a", size: 3))) as? [String: Any])
    #expect(put["op"] as? String == "putFile")
    #expect(put["path"] as? String == "a")
    #expect(put["size"] as? Int == 3)
    let get = try #require(try JSONSerialization.jsonObject(
        with: JSONEncoder().encode(AgentAction.getFile(path: "a", maxBytes: 9))) as? [String: Any])
    #expect(get["op"] as? String == "getFile")
    #expect(get["maxBytes"] as? Int == 9)
    let list = try #require(String(data: try JSONEncoder().encode(AgentAction.listFiles(path: nil)), encoding: .utf8))
    #expect(list == #"{"op":"listFiles"}"#)
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(AgentAction.self, from: Data(#"{"op":"putFile","path":"a"}"#.utf8))
    }
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(AgentAction.self, from: Data(#"{"op":"getFile","maxBytes":3}"#.utf8))
    }
}

@Test func fileRepliesRoundTrip() throws {
    let listed = AgentReply(ok: true, files: [
        TransferEntry(name: "a.txt", kind: "file", size: 3, modified: Date(timeIntervalSince1970: 1_700_000_000)),
        TransferEntry(name: "docs", kind: "folder", size: 0, modified: Date(timeIntervalSince1970: 1_600_000_000.5)),
    ], truncated: true)
    #expect(try JSONDecoder().decode(AgentReply.self, from: JSONEncoder().encode(listed)) == listed)
    let got = AgentReply(ok: true, bytes: 42)
    #expect(try JSONDecoder().decode(AgentReply.self, from: JSONEncoder().encode(got)) == got)
    // A reply without them has none of the keys: older hosts read it as before.
    let plain = try #require(String(data: try JSONEncoder().encode(AgentReply(ok: true)), encoding: .utf8))
    #expect(!plain.contains("files") && !plain.contains("truncated") && !plain.contains("bytes"))
}

/// What the listener reads after a request frame: one data frame after a `putFile` whose size
/// is within the limit, nothing after any other request.
@Test func dataFrameExpectedOnlyAfterPutFile() {
    let max = AgentProtocol.maxTransferBytes
    for size in [0, 3, max] {
        #expect(AgentDispatcher.dataFrame(after: AgentRequest(action: .putFile(path: "a", size: size)))
            == .frame(maxBytes: max))
    }
    for size in [-1, max + 1] {
        guard case .refused(let reply) = AgentDispatcher.dataFrame(after: AgentRequest(action: .putFile(path: "a", size: size)))
        else {
            Issue.record("size \(size) not refused")
            continue
        }
        #expect(reply.error == .badRequest)
    }
    let others: [AgentAction] = [.status, .getFile(path: "a", maxBytes: 3), .listFiles(path: nil), .screenshot(maxLongEdge: 800)]
    for action in others {
        #expect(AgentDispatcher.dataFrame(after: AgentRequest(action: action)) == .nothing)
    }
}
