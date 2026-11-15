// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import NidoAgentKit

/// The unshifted characters of a few keys of a French AZERTY layout, by key code (the code is the
/// key's position on a US keyboard): where US has q, a, z, w the AZERTY keys type a, q, w, z, and
/// the top row types & é " ' (the digits need shift).
private let azerty: [UInt16: String] = [
    0: "q", 12: "a", 13: "z", 6: "w", 1: "s", 46: ",", 18: "&", 19: "é", 20: "\"",
    36: "\r", 48: "\t", 49: " ",
    // Keypad: types digits without shift, but is never used for a combo.
    83: "1", 84: "2",
]

private func layout(_ table: [UInt16: String]) -> KeyLayout {
    KeyLayout(translate: { table[$0] })
}

@Test func layoutFindsTheKeyThatTypesTheCharacter() {
    let azerty = layout(azerty)
    #expect(azerty.keyCode(for: "a") == 12)
    #expect(azerty.keyCode(for: "q") == 0)
    #expect(azerty.keyCode(for: "z") == 13)
    #expect(azerty.keyCode(for: "w") == 6)
    #expect(azerty.keyCode(for: "é") == 19)
    #expect(azerty.keyCode(for: "1") == nil)  // keypad keys are left out
    #expect(azerty.keyCode(for: "m") == nil)
}

@Test func comboLettersFollowTheLayout() throws {
    let azerty = layout(azerty)
    // On AZERTY the US code of "a" (0) types "q": cmd+a must not become cmd+Q.
    #expect(try KeyMap.parseCombo("cmd+a", layout: azerty) == KeyStroke(keyCode: 12, modifiers: [.command], characters: "a"))
    #expect(try KeyMap.parseCombo("cmd+q", layout: azerty) == KeyStroke(keyCode: 0, modifiers: [.command], characters: "q"))
    #expect(try KeyMap.parseCombo("cmd+shift+z", layout: azerty) == KeyStroke(keyCode: 13, modifiers: [.command, .shift], characters: "z"))
    #expect(try KeyMap.parseCombo("cmd+A", layout: azerty).keyCode == 12)
    #expect(try KeyMap.parseCombo("ctrl+,", layout: azerty).keyCode == 46)
}

@Test func comboFallsBackToUSCodeWhenTheLayoutLacksTheCharacter() throws {
    let azerty = layout(azerty)
    // "1" needs shift on AZERTY (and the keypad is left out): the US code, as without a layout.
    #expect(try KeyMap.parseCombo("cmd+1", layout: azerty) == KeyMap.parseCombo("cmd+1"))
    #expect(try KeyMap.parseCombo("cmd+m", layout: azerty) == KeyMap.parseCombo("cmd+m"))
    #expect(try KeyMap.parseCombo("cmd+?", layout: azerty) == KeyMap.parseCombo("cmd+?"))
    #expect(try KeyMap.parseCombo("cmd+a", layout: nil) == KeyMap.parseCombo("cmd+a"))
}

@Test func namedKeysKeepTheirCodes() throws {
    // A layout whose code 0 types "\r" must not move return; space and tab neither.
    let odd = layout([0: "\r", 1: " ", 2: "\t", 3: "x"])
    #expect(try KeyMap.parseCombo("return", layout: odd).keyCode == 36)
    #expect(try KeyMap.parseCombo("cmd+space", layout: odd).keyCode == 49)
    #expect(try KeyMap.parseCombo("tab", layout: odd).keyCode == 48)
    #expect(try KeyMap.parseCombo("f5", layout: odd).keyCode == 96)
    #expect(try KeyMap.parseCombo("shift", layout: odd).keyCode == KeyModifiers.shift.keyCode)
    #expect(try KeyMap.parseCombo("cmd+x", layout: odd).keyCode == 3)
}

/// A punctuation name is the character it names: `comma` follows the layout as `,` does.
@Test func punctuationNamesFollowTheLayout() throws {
    let azerty = layout(azerty)
    #expect(try KeyMap.parseCombo("ctrl+comma", layout: azerty) == KeyStroke(keyCode: 46, modifiers: [.control], characters: ","))
    #expect(try KeyMap.parseCombo("cmd+period", layout: azerty) == KeyMap.parseCombo("cmd+period"))
}

@Test func lowestCodeWinsForACharacterOnTwoKeys() {
    let twice = layout([50: "<", 10: "<"])
    #expect(twice.keyCode(for: "<") == 10)
}
