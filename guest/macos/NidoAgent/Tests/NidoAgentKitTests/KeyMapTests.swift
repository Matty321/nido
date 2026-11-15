// SPDX-License-Identifier: Apache-2.0
import Testing
@testable import NidoAgentKit

@Test func lowercaseAndShifted() throws {
    let s = try KeyMap.strokes(for: "aA!")
    #expect(s.map(\.keyCode) == [0, 0, 18])
    #expect(s.map(\.modifiers) == [[], [.shift], [.shift]])
}

@Test func newlineIsReturn() throws {
    #expect(try KeyMap.strokes(for: "a\r\nb").map(\.keyCode) == [0, 36, 11])
}

@Test func unsupportedCharacter() {
    #expect(throws: KeyMapError.unsupportedCharacter("è")) { try KeyMap.strokes(for: "è") }
}

@Test func combos() throws {
    #expect(try KeyMap.parseCombo("cmd+space") == KeyStroke(keyCode: 49, modifiers: [.command], characters: " "))
    let shot = try KeyMap.parseCombo("Cmd+Shift+4")
    #expect(shot.keyCode == 21)
    #expect(shot.modifiers == [.command, .shift])
    #expect(try KeyMap.parseCombo("cmd+A").modifiers == [.command])
    #expect(try KeyMap.parseCombo("ctrl+c").keyCode == 8)
    #expect(try KeyMap.parseCombo("return").keyCode == 36)
    #expect(try KeyMap.parseCombo("F12").keyCode == 111)
    let plus = try KeyMap.parseCombo("cmd++")
    #expect(plus.keyCode == 24)
    #expect(plus.modifiers == [.command, .shift])
    #expect(try KeyMap.parseCombo("?").modifiers == [.shift])
    #expect(try KeyMap.parseCombo("shift").keyCode == 56)
}

@Test func badCombos() {
    #expect(throws: KeyMapError.self) { try KeyMap.parseCombo("hyper+x") }
    #expect(throws: KeyMapError.self) { try KeyMap.parseCombo("cmd+nope") }
    #expect(throws: KeyMapError.self) { try KeyMap.parseCombo("") }
}

@Test func sequence() throws {
    let seq = try KeyMap.parseSequence("cmd+a delete, down,return")
    #expect(seq.map(\.keyCode) == [0, 51, 125, 36])
}

@Test func arrowsAndModifiedArrows() throws {
    #expect(try KeyMap.parseCombo("up").keyCode == 126)
    #expect(try KeyMap.parseCombo("down").keyCode == 125)
    let ctrlRight = try KeyMap.parseCombo("ctrl+right")
    #expect(ctrlRight.keyCode == 124)
    #expect(ctrlRight.modifiers == [.control])
    #expect(try KeyMap.parseCombo("forwarddelete").keyCode == 117)
    let shiftTab = try KeyMap.parseCombo("shift+tab")
    #expect(shiftTab.keyCode == 48)
    #expect(shiftTab.modifiers == [.shift])
}

@Test func optionKey() throws {
    let s = try KeyMap.parseCombo("option+f")
    #expect(s.keyCode == 3)
    #expect(s.modifiers == [.option])
    #expect(try KeyMap.parseCombo("alt+f") == s)
}

@Test func comboWithAccentedKeyIsAccepted() throws {
    try KeyMap.validateCombo("cmd+é")
    try KeyMap.validateCombo("é")
    try KeyMap.validateCombo("cmd+a")
    try KeyMap.validateCombo("cmd++")
    #expect(throws: KeyMapError.self) { try KeyMap.parseCombo("cmd+é") }
}

@Test func unknownNamedKeyStillRefused() {
    #expect(throws: KeyMapError.self) { try KeyMap.validateCombo("cmd+nope") }
    #expect(throws: KeyMapError.self) { try KeyMap.validateCombo("hyper+é") }
    #expect(throws: KeyMapError.self) { try KeyMap.validateCombo("") }
    #expect(throws: KeyMapError.self) { try KeyMap.validateCombo("cmd+\u{7}") }
}
