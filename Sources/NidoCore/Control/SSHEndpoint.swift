// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Where the Mac's ssh client reaches a VM: the guest's DHCP address and port 22 on Apple's NAT,
/// `127.0.0.1` and the `gvproxy` forward port for a controlled-network VM.
public struct SSHEndpoint: Equatable, Sendable {
    public let host: String
    public let port: UInt16

    public init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }
}
