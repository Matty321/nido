// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Length-prefixed frames over a file descriptor: 4-byte big-endian length, then the bytes.
public enum AgentFrame {
    public enum FrameError: Error, Equatable {
        case tooLarge(Int)
        case closed
        case io(errno: Int32)
    }

    public static func write(_ data: Data, to fd: Int32) throws {
        guard data.count <= UInt32.max else { throw FrameError.tooLarge(data.count) }
        var header = UInt32(data.count).bigEndian
        try withUnsafeBytes(of: &header) { try writeAll($0, to: fd) }
        try data.withUnsafeBytes { try writeAll($0, to: fd) }
    }

    public static func read(from fd: Int32, maxBytes: Int = AgentProtocol.maxFrameBytes) throws -> Data {
        var header = [UInt8](repeating: 0, count: 4)
        try header.withUnsafeMutableBytes { try readAll(into: $0, from: fd) }
        let length = Int(UInt32(bigEndian: header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }))
        guard length <= maxBytes else { throw FrameError.tooLarge(length) }
        var body = Data(count: length)
        try body.withUnsafeMutableBytes { try readAll(into: $0, from: fd) }
        return body
    }

    public static func writeJSON<T: Encodable>(_ value: T, to fd: Int32) throws {
        try write(JSONEncoder().encode(value), to: fd)
    }

    public static func readJSON<T: Decodable>(_ type: T.Type, from fd: Int32) throws -> T {
        try JSONDecoder().decode(type, from: read(from: fd))
    }

    private static func writeAll(_ buffer: UnsafeRawBufferPointer, to fd: Int32) throws {
        var offset = 0
        while offset < buffer.count {
            let n = Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
            if n < 0 {
                if errno == EINTR { continue }
                throw FrameError.io(errno: errno)
            }
            offset += n
        }
    }

    private static func readAll(into buffer: UnsafeMutableRawBufferPointer, from fd: Int32) throws {
        var offset = 0
        while offset < buffer.count {
            let n = Darwin.read(fd, buffer.baseAddress! + offset, buffer.count - offset)
            if n < 0 {
                if errno == EINTR { continue }
                throw FrameError.io(errno: errno)
            }
            if n == 0 { throw FrameError.closed }
            offset += n
        }
    }
}
