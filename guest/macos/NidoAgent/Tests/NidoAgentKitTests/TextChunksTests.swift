// SPDX-License-Identifier: Apache-2.0
import Testing
@testable import NidoAgentKit

@Test func textChunksKeepGraphemes() {
    let family = "👩‍👩‍👧‍👦"
    let pieces = TextChunks.split("ab\(family)c\nd", maxUTF16: 4)
    var joined = ""
    for case .text(let t) in pieces {
        joined += t
        // A piece that contains part of the emoji contains all of it.
        if t.contains("👩") { #expect(t.contains(family)) }
    }
    #expect(joined == "ab\(family)cd")
    #expect(pieces.contains(.text(family)))
    #expect(pieces.contains(.returnKey))
}

@Test func textChunksRespectLimit() {
    let pieces = TextChunks.split(String(repeating: "x", count: 45), maxUTF16: 20)
    #expect(pieces == [.text(String(repeating: "x", count: 20)), .text(String(repeating: "x", count: 20)), .text("xxxxx")])
}

@Test func textChunksTab() {
    #expect(TextChunks.split("a\tb") == [.text("a"), .tab, .text("b")])
}

@Test func textChunksCRLFIsOneReturn() {
    #expect(TextChunks.split("a\r\nb") == [.text("a"), .returnKey, .text("b")])
}
