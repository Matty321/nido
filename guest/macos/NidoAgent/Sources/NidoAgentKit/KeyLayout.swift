// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Which key types which character, with no modifier, in one keyboard layout of the guest.
///
/// A key code names a key's position (the US layout's), not what it types: on a French AZERTY
/// layout the key with the US code of "a" types "q", so `cmd+a` sent with the US code would be
/// cmd+Q and quit the app. `KeyMap.parseCombo(_:layout:)` looks a combo's character up here
/// first and keeps the US code only when no key of the layout types it.
///
/// The table is built from a `translate` function (the helper wraps `UCKeyTranslate` over the
/// current layout; tests pass a dictionary), so the search itself needs no keyboard.
public struct KeyLayout: Equatable, Sendable {
    /// The keypad's codes: its digits and operators type the same characters on every layout,
    /// but an app may treat cmd+keypad-1 apart from cmd+1, so a combo never lands there.
    public static let keypadCodes: Set<UInt16> = [65, 67, 69, 71, 75, 76, 78, 81, 82, 83, 84, 85, 86, 87, 88, 89, 91, 92]

    /// The key code for each character a key of the layout types without modifiers.
    public let codes: [Character: UInt16]

    /// Asks `translate` for the character of each key code from 0 to 127 (nil or a string that is
    /// not exactly one character: none) and keeps, for each character, the lowest code outside
    /// the keypad. Control characters (return, tab, escape…) are left out: named keys keep their
    /// fixed codes whatever the layout.
    public init(translate: (UInt16) -> String?) {
        var codes: [Character: UInt16] = [:]
        for code in UInt16(0)...127 where !Self.keypadCodes.contains(code) {
            guard let text = translate(code), text.count == 1, let character = text.first,
                !character.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }),
                character != " ", codes[character] == nil
            else { continue }
            codes[character] = code
        }
        self.codes = codes
    }

    /// The key that types `character` without modifiers, if any.
    public func keyCode(for character: Character) -> UInt16? {
        codes[character]
    }
}

extension KeyMap {
    /// `parseCombo(_:)` for the guest's current layout: when the combo's key is a character (a
    /// letter, digit or punctuation, also by a name such as `comma`), the key code is the one
    /// that types that character in `layout`, with only the combo's own modifiers; when no key
    /// of `layout` types it (or `layout` is nil), the US key code and modifiers, as
    /// `parseCombo(_:)` gives them. Keys that type no character of a layout (return, tab, space,
    /// escape, arrows, f-keys…) never match one, so they keep their fixed codes.
    public static func parseCombo(_ input: String, layout: KeyLayout?) throws -> KeyStroke {
        let stroke = try parseCombo(input)
        guard let layout, let key = comboCharacter(input),
            let code = layout.keyCode(for: key.character)
        else { return stroke }
        return KeyStroke(keyCode: code, modifiers: key.modifiers, characters: String(key.character))
    }

    /// The character a combo's key types (lowercased for an ASCII letter, as `parseCombo` does;
    /// a named key's own characters when they are one) and the modifiers written in the combo;
    /// nil for a bare modifier or a key without a single character. Only called on a combo
    /// `parseCombo` accepted.
    static func comboCharacter(_ input: String) -> (character: Character, modifiers: KeyModifiers)? {
        let tokens = comboTokens(input)
        guard let key = tokens.last, !(tokens.count == 1 && modifier(named: key) != nil) else { return nil }
        let character: Character
        if let name = named[key.lowercased()] {
            guard name.chars.count == 1, let first = name.chars.first else { return nil }
            character = first
        } else {
            guard key.count == 1, let first = key.first else { return nil }
            character = (first.isLetter && first.isASCII) ? Character(first.lowercased()) : first
        }
        var modifiers: KeyModifiers = []
        for token in tokens.dropLast() {
            guard let modifier = modifier(named: token) else { return nil }
            modifiers.insert(modifier)
        }
        return (character, modifiers)
    }
}
