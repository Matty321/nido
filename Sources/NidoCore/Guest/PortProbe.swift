// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation

/// One TCP connection attempt, closed at once: no data is sent.
public enum PortProbe {
    public enum Result: Equatable, Sendable {
        /// The connection was accepted.
        case open
        /// The host answered that nothing listens on the port (`ECONNREFUSED`).
        case refused
        /// No answer within the timeout, no route, or `host` is not an IPv4 address.
        case noAnswer
    }

    /// How Nido probes a macOS guest's SSH (`nido ssh`, agent setup). On Apple's NAT a TCP
    /// connection to the guest is enough: the guest itself refuses it when Remote Login is off. On
    /// the controlled network the endpoint is gvproxy's forward on 127.0.0.1, which accepts every
    /// connection and closes it when the guest refuses: there the probe waits up to 2 s for the
    /// SSH banner (`awaitingBanner`).
    public static func remoteLogin(controlledNetwork: Bool) -> @Sendable (SSHEndpoint) -> Result {
        { @Sendable endpoint in
            tcp(host: endpoint.host, port: endpoint.port, timeout: .seconds(2), awaitingBanner: controlledNetwork)
        }
    }

    /// Connects to `host` (an IPv4 address, as in the DHCP leases) on `port`, waiting at most
    /// `timeout`. With `awaitingBanner` (a forward that accepts on behalf of the guest, such as
    /// gvproxy's), an accepted connection then waits at most `timeout` again for the server's first
    /// bytes (the SSH banner): the connection closed or reset before them is `.refused`, nothing
    /// within the timeout is `.noAnswer`.
    public static func tcp(host: String, port: UInt16, timeout: Duration, awaitingBanner: Bool = false) -> Result {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else { return .noAnswer }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return .noAnswer }
        defer { _ = Darwin.close(fd) }
        var noSigPipe: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { return .noAnswer }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        let (seconds, attoseconds) = timeout.components
        let milliseconds = Int32(clamping: seconds * 1000 + attoseconds / 1_000_000_000_000_000)
        if connected == 0 { return awaitingBanner ? banner(fd, milliseconds: milliseconds) : .open }
        if errno == ECONNREFUSED { return .refused }
        guard errno == EINPROGRESS else { return .noAnswer }

        var pollFD = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        var ready: Int32
        repeat {
            ready = poll(&pollFD, 1, milliseconds)
        } while ready < 0 && errno == EINTR
        guard ready > 0 else { return .noAnswer }
        var socketError: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0 else { return .noAnswer }
        switch socketError {
        case 0: return awaitingBanner ? banner(fd, milliseconds: milliseconds) : .open
        case ECONNREFUSED: return .refused
        default: return .noAnswer
        }
    }

    /// Waits on the connected `fd` for the server's first bytes: some arrive, `.open`; the peer
    /// closes or resets first, `.refused`; none within `milliseconds`, `.noAnswer`.
    private static func banner(_ fd: Int32, milliseconds: Int32) -> Result {
        var pollFD = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        var ready: Int32
        repeat {
            ready = poll(&pollFD, 1, milliseconds)
        } while ready < 0 && errno == EINTR
        guard ready > 0 else { return .noAnswer }
        var byte: UInt8 = 0
        var received: Int
        repeat {
            received = recv(fd, &byte, 1, MSG_PEEK)
        } while received < 0 && errno == EINTR
        if received > 0 { return .open }
        if received == 0 || errno == ECONNRESET { return .refused }
        return .noAnswer
    }
}
