// SPDX-License-Identifier: Apache-2.0
import Testing
@testable import NidoAgentKit

@Test func comboPressesModifiersAroundTheKey() throws {
    let events = KeyEvents.sequence(for: try KeyMap.parseCombo("cmd+shift+4"))
    #expect(events == [
        KeyEvent(keyCode: 56, keyDown: true, modifiers: [.shift]),
        KeyEvent(keyCode: 55, keyDown: true, modifiers: [.shift, .command]),
        KeyEvent(keyCode: 21, keyDown: true, modifiers: [.shift, .command]),
        KeyEvent(keyCode: 21, keyDown: false, modifiers: [.shift, .command]),
        KeyEvent(keyCode: 55, keyDown: false, modifiers: [.shift]),
        KeyEvent(keyCode: 56, keyDown: false, modifiers: []),
    ])
}

@Test func bareModifierCarriesItsOwnFlag() throws {
    let events = KeyEvents.sequence(for: try KeyMap.parseCombo("shift"))
    #expect(events == [
        KeyEvent(keyCode: 56, keyDown: true, modifiers: [.shift]),
        KeyEvent(keyCode: 56, keyDown: false, modifiers: []),
    ])
}

@Test func plainKeyHasNoModifiers() throws {
    let events = KeyEvents.sequence(for: try KeyMap.parseCombo("return"))
    #expect(events == [
        KeyEvent(keyCode: 36, keyDown: true, modifiers: []),
        KeyEvent(keyCode: 36, keyDown: false, modifiers: []),
    ])
}

@Test func everyModifierInPressOrder() throws {
    let events = KeyEvents.sequence(for: try KeyMap.parseCombo("fn+cmd+shift+option+ctrl+a"))
    #expect(events.map(\.keyCode) == [59, 58, 56, 55, 63, 0, 0, 63, 55, 56, 58, 59])
    #expect(events.first?.modifiers == [.control])
    #expect(events[4].modifiers == [.control, .option, .shift, .command, .function])
    #expect(events.last?.modifiers == [])
}

@Test func bareFunctionKey() throws {
    let events = KeyEvents.sequence(for: try KeyMap.parseCombo("fn"))
    #expect(events == [
        KeyEvent(keyCode: 63, keyDown: true, modifiers: [.function]),
        KeyEvent(keyCode: 63, keyDown: false, modifiers: []),
    ])
}
