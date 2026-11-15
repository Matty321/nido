// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import NidoAgentKit

private func socketPair() throws -> (Int32, Int32) {
    var fds: [Int32] = [0, 0]
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { throw AgentFrame.FrameError.io(errno: errno) }
    return (fds[0], fds[1])
}

@Test func frameRoundTrip() throws {
    let (a, b) = try socketPair()
    defer { close(a); close(b) }
    var payload = Data(count: 10 << 20)
    for i in stride(from: 0, to: payload.count, by: 1) { payload[i] = UInt8.random(in: 0...255) }
    let expected = payload
    // The writer blocks on a full socket buffer, so it runs on its own thread.
    let writer = Thread { try? AgentFrame.write(expected, to: a) }
    writer.start()
    let got = try AgentFrame.read(from: b)
    #expect(got == expected)
}

@Test func frameRejectsOversize() throws {
    let (a, b) = try socketPair()
    defer { close(a); close(b) }
    var len = UInt32(AgentProtocol.maxFrameBytes + 1).bigEndian
    _ = withUnsafeBytes(of: &len) { Darwin.write(a, $0.baseAddress, 4) }
    #expect(throws: AgentFrame.FrameError.tooLarge(33554433)) { try AgentFrame.read(from: b) }
}

@Test func frameClosedMidway() throws {
    let (a, b) = try socketPair()
    defer { close(b) }
    var two: [UInt8] = [0, 0]
    _ = Darwin.write(a, &two, 2)
    close(a)
    #expect(throws: AgentFrame.FrameError.closed) { try AgentFrame.read(from: b) }
}

@Test func jsonFrameRoundTrip() throws {
    let (a, b) = try socketPair()
    defer { close(a); close(b) }
    let reply = AgentReply(ok: false, error: .timeout, message: "slow")
    try AgentFrame.writeJSON(reply, to: a)
    #expect(try AgentFrame.readJSON(AgentReply.self, from: b) == reply)
}
