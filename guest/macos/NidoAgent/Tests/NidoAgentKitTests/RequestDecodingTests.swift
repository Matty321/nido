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
