// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import NidoCore

@Suite struct SSHArgumentsTests {
    private static let vmID = UUID(uuidString: "0A1B2C3D-4E5F-6A7B-8C9D-0E1F2A3B4C5D")!

    private func expected(knownHosts: String, host: String, extra: [String] = []) -> [String] {
        [
            "ssh",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "HostKeyAlias=nido-0a1b2c3d-4e5f-6a7b-8c9d-0e1f2a3b4c5d",
            "-o", "UserKnownHostsFile=\"\(knownHosts)\"",
            "-o", "GlobalKnownHostsFile=/dev/null",
            "-o", "ForwardAgent=no",
            "-o", "ForwardX11=no",
            host,
        ] + extra
    }

    @Test func buildsExactArgumentVector() throws {
        let args = try SSHArguments.make(
            endpoint: SSHEndpoint(host: "192.168.64.5", port: 22), vmID: Self.vmID, knownHosts: URL(fileURLWithPath: "/tmp/kh"), extra: ["uname"])
        #expect(args == expected(knownHosts: "/tmp/kh", host: "nido@192.168.64.5", extra: ["uname"]))
    }

    /// ssh splits `UserKnownHostsFile` on whitespace: the path must be quoted inside the argument.
    @Test func quotesKnownHostsPathWithSpaces() throws {
        let path = "/Users/x/Library/Application Support/Nido/VMs/a.nidovm/known_hosts"
        let args = try SSHArguments.make(endpoint: SSHEndpoint(host: "10.0.0.2", port: 22), vmID: Self.vmID, knownHosts: URL(fileURLWithPath: path), extra: [])
        #expect(args == expected(knownHosts: path, host: "nido@10.0.0.2"))
    }

    @Test(arguments: ["/a\"b/known_hosts", "/a\\b/known_hosts", "/a%h/known_hosts", "/a\nb/known_hosts", "/a\rb/kh"])
    func rejectsPathsSSHWouldReinterpret(_ path: String) {
        #expect(throws: NidoError.unsafePath(path)) {
            _ = try SSHArguments.make(endpoint: SSHEndpoint(host: "10.0.0.2", port: 22), vmID: Self.vmID, knownHosts: URL(fileURLWithPath: path), extra: [])
        }
    }

    /// The host key is pinned to the VM, not to its address: a new DHCP address still needs the
    /// same key, and two VMs never share an entry.
    @Test func hostKeyIsPinnedToTheVM() throws {
        let other = UUID()
        let a = try SSHArguments.make(endpoint: SSHEndpoint(host: "10.0.0.2", port: 22), vmID: Self.vmID, knownHosts: URL(fileURLWithPath: "/kh"), extra: [])
        let b = try SSHArguments.make(endpoint: SSHEndpoint(host: "10.0.0.9", port: 22), vmID: Self.vmID, knownHosts: URL(fileURLWithPath: "/kh"), extra: [])
        let c = try SSHArguments.make(endpoint: SSHEndpoint(host: "10.0.0.2", port: 22), vmID: other, knownHosts: URL(fileURLWithPath: "/kh"), extra: [])
        func alias(_ argv: [String]) -> String? { argv.first { $0.hasPrefix("HostKeyAlias=") } }
        #expect(alias(a) == alias(b))
        #expect(alias(a) != alias(c))
        let background = try SSHArguments.background(
            identity: "/k/id", endpoint: SSHEndpoint(host: "10.0.0.9", port: 22), vmID: Self.vmID, knownHosts: URL(fileURLWithPath: "/kh"), remoteCommand: "x")
        #expect(alias(background) == alias(a))
    }

    /// A controlled-network VM must not get a path out through the Mac's ssh client: forwards
    /// from the user's ssh config (`RemoteForward`, `DynamicForward`, `Tunnel`, ...) are cleared.
    @Test func controlledNetworkClearsForwardings() throws {
        let forwardsOff = ["-o", "ClearAllForwardings=yes", "-o", "Tunnel=no", "-o", "PermitRemoteOpen=none"]
        let controlled = try SSHArguments.make(
            endpoint: SSHEndpoint(host: "10.0.0.2", port: 22), vmID: Self.vmID, knownHosts: URL(fileURLWithPath: "/kh"),
            controlledNetwork: true, extra: ["-v"])
        #expect(controlled == Array(expected(knownHosts: "/kh", host: "nido@10.0.0.2").dropLast())
            + forwardsOff + ["nido@10.0.0.2", "-v"])
        let open = try SSHArguments.make(endpoint: SSHEndpoint(host: "10.0.0.2", port: 22), vmID: Self.vmID, knownHosts: URL(fileURLWithPath: "/kh"), extra: [])
        #expect(open == expected(knownHosts: "/kh", host: "nido@10.0.0.2"))
        // Background commands never need a forward: always cleared.
        let background = try SSHArguments.background(
            identity: "/k/id", endpoint: SSHEndpoint(host: "10.0.0.9", port: 22), vmID: Self.vmID, knownHosts: URL(fileURLWithPath: "/kh"), remoteCommand: "x")
        let host = try #require(background.firstIndex(of: "nido@10.0.0.9"))
        #expect(Array(background[(host - 6)..<host]) == forwardsOff)
    }

    /// The gvproxy forward: `-p <port>` right before `user@host`, the rest as for any VM.
    @Test func forwardPortAddsDashP() throws {
        let kh = URL(fileURLWithPath: "/kh")
        let endpoint = SSHEndpoint(host: "127.0.0.1", port: 50123)
        let args = try SSHArguments.make(endpoint: endpoint, vmID: Self.vmID, knownHosts: kh, controlledNetwork: true, extra: ["-v"])
        let host = try #require(args.firstIndex(of: "nido@127.0.0.1"))
        #expect(Array(args[(host - 2)..<host]) == ["-p", "50123"])
        #expect(args.contains("HostKeyAlias=nido-0a1b2c3d-4e5f-6a7b-8c9d-0e1f2a3b4c5d"))
        #expect(args.contains("ClearAllForwardings=yes"))
        #expect(args.last == "-v")
        let background = try SSHArguments.background(
            identity: "/k/id", endpoint: endpoint, vmID: Self.vmID, knownHosts: kh, remoteCommand: "x")
        let bgHost = try #require(background.firstIndex(of: "nido@127.0.0.1"))
        #expect(Array(background[(bgHost - 2)..<bgHost]) == ["-p", "50123"])
        #expect(Array(background[(bgHost + 1)...]) == ["--", "x"])
    }
}
