// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import NidoAgentKit

@Test func requestJSONIsStable() throws {
    let req = AgentRequest(v: 1, action: .click(x: 10, y: 20, button: .left, count: 2),
                           image: PixelSize(1280, 800), screen: ScreenSize(width: 1440, height: 900))
    let data = try JSONEncoder().encode(req)
    let json = try #require(String(data: data, encoding: .utf8))
    #expect(json.contains("\"op\":\"click\""))
    #expect(try JSONDecoder().decode(AgentRequest.self, from: data) == req)
}

@Test func everyActionRoundTrips() throws {
    let actions: [AgentAction] = [
        .status, .screenshot(maxLongEdge: 800),
        .click(x: 1, y: 2, button: .right, count: 1),
        .drag(fromX: 1, fromY: 2, toX: 3, toY: 4),
        .scroll(dx: 0, dy: -5, x: nil, y: nil),
        .scroll(dx: 1, dy: 2, x: 3, y: 4),
        .type(text: "hi"), .key(combo: "cmd+space"),
        .setClipboard(text: "abcde-fghjk", clearAfter: 60),
        .zoom(x: 1, y: 2, width: 3, height: 4, maxLongEdge: 800),
        .uiTree(maxElements: 300),
        .putFile(path: "a/b.txt", size: 3), .getFile(path: "a/b.txt", maxBytes: 1 << 20),
        .listFiles(path: nil), .listFiles(path: "a"),
    ]
    for a in actions {
        let data = try JSONEncoder().encode(a)
        #expect(try JSONDecoder().decode(AgentAction.self, from: data) == a)
    }
}

/// The owner's clipboard request: `op` "setClipboard" with the text and the seconds after which
/// the helper clears the pasteboard.
@Test func setClipboardJSONIsStable() throws {
    let req = AgentRequest(action: .setClipboard(text: "abcde-fghjk", clearAfter: 60))
    let data = try JSONEncoder().encode(req)
    let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let action = try #require(object["action"] as? [String: Any])
    #expect(action["op"] as? String == "setClipboard")
    #expect(action["text"] as? String == "abcde-fghjk")
    #expect(action["clearAfter"] as? Int == 60)
    #expect(try JSONDecoder().decode(AgentRequest.self, from: data) == req)
}

@Test func unknownOpIsRejected() {
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(AgentAction.self, from: Data(#"{"op":"explode"}"#.utf8))
    }
}

@Test func protocolConstants() {
    #expect(AgentProtocol.version == 1)
    #expect(AgentProtocol.port == 7710)
    #expect(AgentProtocol.maxFrameBytes == 32 << 20)
    #expect(AgentProtocol.defaultMaxLongEdge == 1280)
    #expect(AgentProtocol.maxLongEdgeRange == 64...4096)
    #expect(AgentProtocol.maxLongEdgeRange.contains(AgentProtocol.defaultMaxLongEdge))
    #expect(AgentProtocol.maxWaitMilliseconds == 10_000)
    #expect(AgentProtocol.uiTreeElementsRange == 1...1000)
    #expect(AgentProtocol.defaultUITreeElements == 300)
    #expect(AgentProtocol.uiTreeElementsRange.contains(AgentProtocol.defaultUITreeElements))
    #expect(AgentProtocol.minimumUITreeHelperVersion == "1.0.5")
    #expect(AgentProtocol.minimumFilesHelperVersion == "1.0.6")
    #expect(AgentProtocol.helperVersion == "1.0.6")
    #expect(AgentProtocol.maxTransferBytes == 16 << 20)
    #expect(AgentProtocol.maxTransferBytes < AgentProtocol.maxFrameBytes)
    #expect(AgentProtocol.maxListedFiles == 500)
}

/// The version the helper reports in `status` is the one in its bundle's Info.plist, which the
/// host reads from the bundled app to decide whether to install (`installDecision`): two places,
/// kept equal here.
@Test func helperVersionMatchesInfoPlist() throws {
    let plist = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources/Info.plist")
    let info = try #require(
        try PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as? [String: Any])
    #expect(info["CFBundleShortVersionString"] as? String == AgentProtocol.helperVersion)
    if let build = info["CFBundleVersion"] as? String {
        #expect(!build.isEmpty && build.allSatisfy(\.isASCII) && build.allSatisfy(\.isNumber))
    }
}
