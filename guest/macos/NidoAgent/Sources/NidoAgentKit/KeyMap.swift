// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Modifier keys, mirrored from NSEvent.ModifierFlags so the core stays AppKit-free.
public struct KeyModifiers: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let shift = KeyModifiers(rawValue: 1 << 0)
    public static let control = KeyModifiers(rawValue: 1 << 1)
    public static let option = KeyModifiers(rawValue: 1 << 2)
    public static let command = KeyModifiers(rawValue: 1 << 3)
    public static let function = KeyModifiers(rawValue: 1 << 4)

    /// Order in which modifiers are pressed (and released in reverse).
    public static let pressOrder: [KeyModifiers] = [.control, .option, .shift, .command, .function]

    /// macOS virtual key code of the left-hand variant of a single modifier.
    public var keyCode: UInt16 {
        switch self {
        case .shift: return 56
        case .control: return 59
        case .option: return 58
        case .command: return 55
        case .function: return 63
        default: return 0
        }
    }

    public var names: [String] {
        var out: [String] = []
        if contains(.control) { out.append("ctrl") }
        if contains(.option) { out.append("option") }
        if contains(.shift) { out.append("shift") }
        if contains(.command) { out.append("cmd") }
        if contains(.function) { out.append("fn") }
        return out
    }
}

/// One physical key press (with held modifiers), expressed as a macOS virtual key code.
public struct KeyStroke: Equatable, Sendable, CustomStringConvertible {
    public var keyCode: UInt16
    public var modifiers: KeyModifiers
    /// Characters NSEvent should carry (best effort; the VM uses the key code).
    public var characters: String

    public init(keyCode: UInt16, modifiers: KeyModifiers = [], characters: String = "") {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.characters = characters
    }

    public var description: String {
        (modifiers.names + ["#\(keyCode)"]).joined(separator: "+")
    }
}

public enum KeyMapError: Error, CustomStringConvertible, Equatable {
    case unknownKey(String)
    case unsupportedCharacter(Character)
    case emptyCombo

    public var description: String {
        switch self {
        case .unknownKey(let k):
            return "unknown key '\(k)'. Use a single character or a name like return, tab, space, escape, delete, up, down, left, right, home, end, pageup, pagedown, f1-f12"
        case .unsupportedCharacter(let c):
            return "cannot type '\(c)' (U+\(String(c.unicodeScalars.first!.value, radix: 16, uppercase: true))): only characters on a US keyboard layout can be typed"
        case .emptyCombo:
            return "empty key combination"
        }
    }
}

/// Maps text and key names to macOS virtual key codes for a US (ANSI) keyboard layout.
///
/// The guest interprets key codes through its own keyboard layout, so typed text
/// matches only when the guest uses the "U.S." or "ABC" input source. A combo sent to the guest
/// goes through `parseCombo(_:layout:)`, which follows the guest's layout for character keys.
public enum KeyMap {
    /// Named, layout-independent keys.
    public static let named: [String: (code: UInt16, chars: String)] = {
        func f(_ c: Int) -> String { String(UnicodeScalar(UInt32(c))!) }
        var m: [String: (UInt16, String)] = [
            "return": (36, "\r"), "enter": (36, "\r"), "ret": (36, "\r"),
            "keypadenter": (76, f(0x03)),
            "tab": (48, "\t"),
            "space": (49, " "), "spacebar": (49, " "),
            "delete": (51, f(0x7F)), "backspace": (51, f(0x7F)), "bksp": (51, f(0x7F)),
            "forwarddelete": (117, f(0xF728)), "fwddelete": (117, f(0xF728)), "del": (117, f(0xF728)),
            "escape": (53, f(0x1B)), "esc": (53, f(0x1B)),
            "left": (123, f(0xF702)), "right": (124, f(0xF703)),
            "down": (125, f(0xF701)), "up": (126, f(0xF700)),
            "home": (115, f(0xF729)), "end": (119, f(0xF72B)),
            "pageup": (116, f(0xF72C)), "pgup": (116, f(0xF72C)),
            "pagedown": (121, f(0xF72D)), "pgdn": (121, f(0xF72D)),
            "capslock": (57, ""),
            "plus": (24, "+"), "minus": (27, "-"), "comma": (43, ","), "period": (47, "."),
            "slash": (44, "/"), "backslash": (42, "\\"), "semicolon": (41, ";"),
            "quote": (39, "'"), "backtick": (50, "`"), "grave": (50, "`"),
            "leftbracket": (33, "["), "rightbracket": (30, "]"), "equal": (24, "="),
            "volumeup": (72, ""), "volumedown": (73, ""), "mute": (74, ""),
        ]
        let fkeys: [UInt16] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90]
        for (i, code) in fkeys.enumerated() { m["f\(i + 1)"] = (code, f(0xF704 + i)) }
        return m
    }()

    /// Characters produced without shift on a US ANSI keyboard.
    public static let unshifted: [Character: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26,
        "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35,
        "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44,
        "n": 45, "m": 46, ".": 47, "`": 50, " ": 49, "\t": 48, "\n": 36, "\r": 36,
    ]

    /// Characters produced with shift, mapped to the unshifted base character.
    public static let shiftedBase: [Character: Character] = [
        "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8",
        "(": "9", ")": "0", "_": "-", "+": "=", "{": "[", "}": "]", "|": "\\",
        ":": ";", "\"": "'", "<": ",", ">": ".", "?": "/", "~": "`",
    ]

    /// Key stroke for typing a single character.
    public static func stroke(for ch: Character) throws -> KeyStroke {
        if let code = unshifted[ch] {
            return KeyStroke(keyCode: code, modifiers: [], characters: ch == "\n" ? "\r" : String(ch))
        }
        if ch.isUppercase, ch.isASCII, let lower = ch.lowercased().first, let code = unshifted[lower] {
            return KeyStroke(keyCode: code, modifiers: [.shift], characters: String(ch))
        }
        if let base = shiftedBase[ch], let code = unshifted[base] {
            return KeyStroke(keyCode: code, modifiers: [.shift], characters: String(ch))
        }
        throw KeyMapError.unsupportedCharacter(ch)
    }

    /// Key strokes for typing a string. Throws on the first character that cannot be typed.
    public static func strokes(for text: String) throws -> [KeyStroke] {
        // Treat CRLF as a single Return.
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        return try normalized.map { try stroke(for: $0) }
    }

    public static func modifier(named raw: String) -> KeyModifiers? {
        switch raw.lowercased() {
        case "cmd", "command", "⌘", "super", "meta", "win", "windows": return .command
        case "shift", "⇧": return .shift
        case "opt", "option", "alt", "⌥": return .option
        case "ctrl", "control", "ctl", "⌃": return .control
        case "fn", "function", "globe": return .function
        default: return nil
        }
    }

    /// Parses a combination such as `cmd+space`, `cmd+shift+4`, `ctrl+c`, `return`, `?`, `cmd++`.
    public static func parseCombo(_ input: String) throws -> KeyStroke {
        guard !input.trimmingCharacters(in: .whitespaces).isEmpty else { throw KeyMapError.emptyCombo }
        let tokens = comboTokens(input)
        guard let keyToken = tokens.last, !keyToken.isEmpty else { throw KeyMapError.unknownKey(input) }

        var mods: KeyModifiers = []
        for t in tokens.dropLast() {
            guard let m = modifier(named: t) else { throw KeyMapError.unknownKey(t) }
            mods.insert(m)
        }

        // A bare modifier (e.g. "shift") presses just that modifier key.
        if tokens.count == 1, let m = modifier(named: keyToken) {
            return KeyStroke(keyCode: m.keyCode, modifiers: [], characters: "")
        }

        let lowered = keyToken.lowercased()
        if let n = named[lowered] {
            return KeyStroke(keyCode: n.code, modifiers: mods, characters: n.chars)
        }
        if keyToken.count == 1, let ch = keyToken.first {
            // Letters are case-insensitive in combos: use "shift+a" for capital A.
            let normalized: Character = (ch.isLetter && ch.isASCII) ? Character(ch.lowercased()) : ch
            var stroke = try stroke(for: normalized)
            stroke.modifiers.formUnion(mods)
            return stroke
        }
        throw KeyMapError.unknownKey(keyToken)
    }

    /// Host-side check of a combo before it is sent: the same grammar as `parseCombo(_:)`, but a
    /// single printable character is accepted even when the US layout has no key for it (`cmd+é`).
    /// The helper looks that character up in the guest's layout and answers `badRequest` when the
    /// layout has no such key.
    public static func validateCombo(_ input: String) throws {
        do {
            _ = try parseCombo(input)
        } catch KeyMapError.unsupportedCharacter {
            let tokens = comboTokens(input)
            guard let keyToken = tokens.last, keyToken.count == 1, let ch = keyToken.first,
                ch.unicodeScalars.allSatisfy({ !$0.properties.generalCategory.isControlOrFormat && !$0.properties.isWhitespace })
            else { throw KeyMapError.unknownKey(tokens.last ?? input) }
            for t in tokens.dropLast() where modifier(named: t) == nil { throw KeyMapError.unknownKey(t) }
        }
    }

    /// The words of a combo split at "+", trimmed: modifiers first, the key last. A trailing
    /// "++" means the "+" key itself.
    static func comboTokens(_ input: String) -> [String] {
        var s = input.trimmingCharacters(in: .whitespaces)
        var tokens: [String]
        if s.hasSuffix("++") {
            s.removeLast(2)
            tokens = s.isEmpty ? [] : s.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
            tokens.append("+")
        } else if s == "+" {
            tokens = ["+"]
        } else {
            tokens = s.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        }
        return tokens.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// Parses a space- or comma-separated list of combos: `"cmd+a delete"`, `"down,down,return"`.
    public static func parseSequence(_ input: String) throws -> [KeyStroke] {
        let parts = input.split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init).filter { !$0.isEmpty }
        guard !parts.isEmpty else { throw KeyMapError.emptyCombo }
        return try parts.map(parseCombo)
    }
}

private extension Unicode.GeneralCategory {
    var isControlOrFormat: Bool {
        switch self {
        case .control, .format, .surrogate, .privateUse, .unassigned, .lineSeparator, .paragraphSeparator: return true
        default: return false
        }
    }
}
