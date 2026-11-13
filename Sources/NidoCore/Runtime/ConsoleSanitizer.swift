// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Makes untrusted guest console output safe to print on the host terminal (`nido start
/// --console`): every escape sequence is dropped (ESC, CSI, OSC, DCS, APC, PM, SOS and their
/// 8-bit C1 forms), as are C1 controls, invalid UTF-8 and every C0 control except TAB, LF and CR.
/// Printable UTF-8 text passes unchanged. So the guest cannot set the clipboard (OSC 52), the
/// window title, ask for reports that the terminal would type back, or reach terminal-emulator
/// parsing bugs.
///
/// Stateful across chunks (a sequence or character may be split anywhere) and bounded: at most
/// 4 pending bytes of an incomplete character; an escape sequence longer than `maxSequence`
/// bytes is abandoned and what follows is treated as (sanitised) text again.
public struct ConsoleSanitizer: Sendable {
    enum Mode: Sendable {
        case ground, escape, escapeIntermediate, csi, string
    }

    /// Longest escape sequence followed before giving up on it.
    static let maxSequence = 4096

    private var mode: Mode = .ground
    /// Bytes of an incomplete UTF-8 character (ground) or of a possible C1 ST (string).
    private var pending: [UInt8] = []
    private var expected = 0
    private var sequenceLength = 0

    public init() {}

    /// `text` with every control character (C0 including TAB/LF/CR, DEL, C1) written as `\u{XX}`:
    /// a host path or name from `config.json` printed in the terminal or a warning can never carry
    /// an escape sequence.
    public static func escapingControls(_ text: String) -> String {
        var result = ""
        result.unicodeScalars.reserveCapacity(text.unicodeScalars.count)
        for scalar in text.unicodeScalars {
            if scalar.properties.generalCategory == .control {
                result += "\\u{" + String(scalar.value, radix: 16, uppercase: true) + "}"
            } else {
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    /// `text` without the characters that could disguise an echoed name or input in a terminal
    /// or a log line: controls (Cc), format characters such as bidi overrides and zero-width
    /// spaces (Cf), and line and paragraph separators (Zl, Zp).
    public static func echoable(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: text.unicodeScalars.lazy.filter(isEchoable))
        return String(scalars)
    }

    /// False for the characters `echoable` drops.
    public static func isEchoable(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .control, .format, .lineSeparator, .paragraphSeparator: false
        default: true
        }
    }

    /// Bytes held back for the next chunk (always ≤ 4).
    public var pendingByteCount: Int { pending.count }

    public mutating func sanitize(_ data: Data) -> Data {
        var out = Data()
        out.reserveCapacity(data.count)
        for byte in data { feed(byte, into: &out) }
        return out
    }

    private mutating func enter(_ new: Mode) {
        mode = new
        sequenceLength = 0
        pending.removeAll(keepingCapacity: true)
        expected = 0
    }

    private mutating func feed(_ byte: UInt8, into out: inout Data) {
        var reprocess = true
        while reprocess {
            reprocess = false
            switch mode {
            case .ground:
                reprocess = ground(byte, into: &out)
            case .escape:
                switch byte {
                case 0x5B: enter(.csi)  // [
                case 0x5D, 0x50, 0x5F, 0x5E, 0x58: enter(.string)  // ] P _ ^ X
                case 0x1B: enter(.escape)
                case 0x20...0x2F: enter(.escapeIntermediate)
                case 0x30...0x7E: enter(.ground)  // final byte of a two-byte sequence
                default:
                    enter(.ground)
                    reprocess = byte != 0x18 && byte != 0x1A  // CAN/SUB just cancel
                }
            case .escapeIntermediate:
                switch byte {
                case 0x20...0x2F: if bump() { enter(.ground) }
                case 0x30...0x7E: enter(.ground)
                case 0x1B: enter(.escape)
                default:
                    enter(.ground)
                    reprocess = byte != 0x18 && byte != 0x1A
                }
            case .csi:
                switch byte {
                case 0x20...0x3F: if bump() { enter(.ground) }
                case 0x40...0x7E: enter(.ground)
                case 0x1B: enter(.escape)
                default:
                    enter(.ground)
                    reprocess = byte != 0x18 && byte != 0x1A
                }
            case .string:
                if pending == [0xC2] {
                    pending.removeAll(keepingCapacity: true)
                    if byte == 0x9C {  // C1 ST
                        enter(.ground)
                        continue
                    }
                }
                switch byte {
                case 0x07, 0x18, 0x1A: enter(.ground)  // BEL ends an OSC; CAN/SUB cancel
                case 0x1B: enter(.escape)  // ESC \ (ST) or any new sequence ends the string
                case 0xC2: pending = [0xC2]
                default: if bump() { enter(.ground) }
                }
            }
        }
    }

    /// Counts one more byte of the current sequence; true when it is too long to follow.
    private mutating func bump() -> Bool {
        sequenceLength += 1
        return sequenceLength > Self.maxSequence
    }

    /// Text state. Returns true when `byte` must be processed again (an interrupted character).
    private mutating func ground(_ byte: UInt8, into out: inout Data) -> Bool {
        if expected > 0 {
            guard byte & 0xC0 == 0x80 else {
                pending.removeAll(keepingCapacity: true)
                expected = 0
                return true
            }
            pending.append(byte)
            guard pending.count == expected else { return false }
            let bytes = pending
            pending.removeAll(keepingCapacity: true)
            expected = 0
            guard let scalar = String(validating: bytes, as: UTF8.self)?.unicodeScalars.first else { return false }
            switch scalar.value {
            case 0x9B: enter(.csi)
            case 0x9D, 0x90, 0x9E, 0x9F, 0x98: enter(.string)
            case 0x80...0x9F: break  // other C1 controls
            default: out.append(contentsOf: bytes)
            }
            return false
        }
        switch byte {
        case 0x1B: enter(.escape)
        case 0x09, 0x0A, 0x0D: out.append(byte)
        case 0x20...0x7E: out.append(byte)
        case 0xC2...0xDF: begin(byte, length: 2)
        case 0xE0...0xEF: begin(byte, length: 3)
        case 0xF0...0xF4: begin(byte, length: 4)
        default: break  // other C0 controls, DEL, stray continuation or invalid bytes
        }
        return false
    }

    private mutating func begin(_ lead: UInt8, length: Int) {
        pending = [lead]
        expected = length
    }
}
