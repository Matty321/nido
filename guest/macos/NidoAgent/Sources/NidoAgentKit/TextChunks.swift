// SPDX-License-Identifier: Apache-2.0
import Foundation

public enum TextPiece: Equatable, Sendable {
    case text(String)
    case returnKey
    case tab
}

public enum TextChunks {
    /// Splits text into pieces of at most `maxUTF16` UTF-16 units, never inside a grapheme.
    /// Newlines become `.returnKey` (CRLF counts once) and tabs `.tab`. A grapheme longer
    /// than `maxUTF16` is its own piece.
    public static func split(_ text: String, maxUTF16: Int = 20) -> [TextPiece] {
        var pieces: [TextPiece] = []
        var current = ""
        var currentUnits = 0
        func flush() {
            if !current.isEmpty { pieces.append(.text(current)) }
            current = ""
            currentUnits = 0
        }
        for ch in text {
            if ch == "\n" || ch == "\r\n" || ch == "\r" {
                flush()
                pieces.append(.returnKey)
            } else if ch == "\t" {
                flush()
                pieces.append(.tab)
            } else {
                let units = ch.utf16.count
                if currentUnits + units > maxUTF16 { flush() }
                current.append(ch)
                currentUnits += units
            }
        }
        flush()
        return pieces
    }
}
