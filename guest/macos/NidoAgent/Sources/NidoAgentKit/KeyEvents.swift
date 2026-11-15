// SPDX-License-Identifier: Apache-2.0
import Foundation

/// One key event to post: a virtual key code, up or down, and the modifiers held while it is posted.
public struct KeyEvent: Equatable, Sendable {
    public var keyCode: UInt16
    public var keyDown: Bool
    public var modifiers: KeyModifiers

    public init(keyCode: UInt16, keyDown: Bool, modifiers: KeyModifiers) {
        self.keyCode = keyCode
        self.keyDown = keyDown
        self.modifiers = modifiers
    }
}

public enum KeyEvents {
    /// The events that press `stroke` as a person would: each modifier key goes down in
    /// `KeyModifiers.pressOrder` with the held flags building up, then the key goes down and up
    /// with all of them, then the modifiers go up in reverse order with the flags clearing.
    /// A bare modifier (its key code, no other modifier for it) carries its own flag on key down.
    public static func sequence(for stroke: KeyStroke) -> [KeyEvent] {
        let modifiers = KeyModifiers.pressOrder.filter { stroke.modifiers.contains($0) }
        var events: [KeyEvent] = []
        var held: KeyModifiers = []
        for modifier in modifiers {
            held.insert(modifier)
            events.append(KeyEvent(keyCode: modifier.keyCode, keyDown: true, modifiers: held))
        }

        if let own = KeyModifiers.pressOrder.first(where: { $0.keyCode == stroke.keyCode }), !held.contains(own) {
            events.append(KeyEvent(keyCode: stroke.keyCode, keyDown: true, modifiers: held.union(own)))
            events.append(KeyEvent(keyCode: stroke.keyCode, keyDown: false, modifiers: held))
        } else {
            events.append(KeyEvent(keyCode: stroke.keyCode, keyDown: true, modifiers: held))
            events.append(KeyEvent(keyCode: stroke.keyCode, keyDown: false, modifiers: held))
        }

        for modifier in modifiers.reversed() {
            held.remove(modifier)
            events.append(KeyEvent(keyCode: modifier.keyCode, keyDown: false, modifiers: held))
        }
        return events
    }
}
