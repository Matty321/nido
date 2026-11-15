// SPDX-License-Identifier: Apache-2.0
import CoreGraphics
import Foundation
import NidoAgentKit

/// Posts mouse and keyboard events in the guest (needs Accessibility). Points are global
/// display coordinates in points, origin at the main display's top left, as CGEvent uses.
struct InputPoster: InputSink {
    enum InputError: Error, CustomStringConvertible {
        case eventCreationFailed(String)

        var description: String {
            switch self {
            case .eventCreationFailed(let what): "could not create the \(what) event"
            }
        }
    }

    /// Intermediate moves of a drag, and its total duration.
    static let dragSteps = 12
    static let dragDuration: TimeInterval = 0.2

    /// The guest's keyboard layout, for the key codes of combos (`key`).
    private let layouts = KeyboardLayouts()

    func click(at p: (x: Double, y: Double), button: MouseButton, count: Int) throws {
        let point = CGPoint(x: p.x, y: p.y)
        let (down, up, cgButton): (CGEventType, CGEventType, CGMouseButton) = switch button {
        case .left: (.leftMouseDown, .leftMouseUp, .left)
        case .right: (.rightMouseDown, .rightMouseUp, .right)
        }
        try post(mouse: .mouseMoved, at: point, button: .left)
        for clickState in 1...max(1, count) {
            try post(mouse: down, at: point, button: cgButton, clickState: clickState)
            try post(mouse: up, at: point, button: cgButton, clickState: clickState)
        }
    }

    func drag(from: (x: Double, y: Double), to: (x: Double, y: Double)) throws {
        let start = CGPoint(x: from.x, y: from.y)
        let end = CGPoint(x: to.x, y: to.y)
        try post(mouse: .mouseMoved, at: start, button: .left)
        try post(mouse: .leftMouseDown, at: start, button: .left)
        let pause = Self.dragDuration / Double(Self.dragSteps + 1)
        for step in 1...Self.dragSteps {
            Thread.sleep(forTimeInterval: pause)
            let t = Double(step) / Double(Self.dragSteps + 1)
            let point = CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
            try post(mouse: .leftMouseDragged, at: point, button: .left)
        }
        Thread.sleep(forTimeInterval: pause)
        try post(mouse: .leftMouseDragged, at: end, button: .left)
        try post(mouse: .leftMouseUp, at: end, button: .left)
    }

    func scroll(dx: Double, dy: Double, at p: (x: Double, y: Double)?) throws {
        if let p {
            try post(mouse: .mouseMoved, at: CGPoint(x: p.x, y: p.y), button: .left)
        }
        // Scroll-wheel signs: wheel1 is vertical and wheel2 horizontal. A positive wheel1 scrolls
        // up (shows content above) and a positive wheel2 scrolls left, as a mouse wheel turned
        // up or tilted left does. The host's contract is "negative dy scrolls down, negative dx
        // scrolls left", so wheel1 = dy and wheel2 = -dx. The deltas of a posted event are
        // already in content direction, so the user's "natural scrolling" setting does not flip them.
        let vertical = Self.wheel(dy)
        let horizontal = Self.wheel(-dx)
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                  wheel1: vertical, wheel2: horizontal, wheel3: 0) else {
            throw InputError.eventCreationFailed("scroll")
        }
        if let p { event.location = CGPoint(x: p.x, y: p.y) }
        event.post(tap: .cghidEventTap)
    }

    /// The gap after a piece of text, and the most all the gaps of one `type` may add up to.
    static let textPause: TimeInterval = 0.005
    static let typingPauseBudget: TimeInterval = 2.5

    /// Types `pieces`. A short gap after each one keeps fast pieces in order in apps that read
    /// input on a busy main thread: `textPause` after text, at most 1 ms after Return or Tab, and
    /// all of them shrunk so that they never add up to more than `typingPauseBudget` (the longest
    /// text, 4096 bytes, can be 4096 pieces), so a `type` stays well within the host's timeout.
    func type(_ pieces: [TextPiece]) throws {
        let source = CGEventSource(stateID: .hidSystemState)
        let pause = min(Self.textPause, Self.typingPauseBudget / Double(max(1, pieces.count)))
        for piece in pieces {
            switch piece {
            case .text(let text):
                // One key down/up pair per piece, carrying the piece's characters (at most 20
                // UTF-16 units, the limit of keyboardSetUnicodeString).
                let units = Array(text.utf16)
                for keyDown in [true, false] {
                    guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: keyDown) else {
                        throw InputError.eventCreationFailed("text")
                    }
                    event.flags = []
                    units.withUnsafeBufferPointer {
                        event.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress)
                    }
                    event.post(tap: .cghidEventTap)
                }
                Thread.sleep(forTimeInterval: pause)
            case .returnKey:
                try post(key: 36, flags: [], source: source)
                Thread.sleep(forTimeInterval: min(pause, 0.001))
            case .tab:
                try post(key: 48, flags: [], source: source)
                Thread.sleep(forTimeInterval: min(pause, 0.001))
            }
        }
    }

    func keyLayout() -> KeyLayout? {
        layouts.current()
    }

    func key(_ stroke: KeyStroke) throws {
        // Modifier keys go down (flags building up), the key goes down and up, the modifiers
        // go up in reverse (flags clearing): see KeyEvents. Every event is created before any
        // is posted, so a failure never leaves a modifier held down.
        let source = CGEventSource(stateID: .hidSystemState)
        let events = try KeyEvents.sequence(for: stroke).map { key in
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(key.keyCode),
                                      keyDown: key.keyDown) else {
                throw InputError.eventCreationFailed("key")
            }
            event.flags = Self.flags(key.modifiers)
            return event
        }
        for event in events { event.post(tap: .cghidEventTap) }
    }

    // MARK: - Helpers

    static func flags(_ modifiers: KeyModifiers) -> CGEventFlags {
        var flags: CGEventFlags = []
        if modifiers.contains(.shift) { flags.insert(.maskShift) }
        if modifiers.contains(.control) { flags.insert(.maskControl) }
        if modifiers.contains(.option) { flags.insert(.maskAlternate) }
        if modifiers.contains(.command) { flags.insert(.maskCommand) }
        if modifiers.contains(.function) { flags.insert(.maskSecondaryFn) }
        return flags
    }

    private static func wheel(_ value: Double) -> Int32 {
        Int32(max(Double(Int32.min), min(Double(Int32.max), value.rounded())))
    }

    private func post(mouse type: CGEventType, at point: CGPoint, button: CGMouseButton, clickState: Int = 1) throws {
        guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point,
                                  mouseButton: button) else {
            throw InputError.eventCreationFailed("mouse")
        }
        event.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
        event.post(tap: .cghidEventTap)
    }

    private func post(key code: CGKeyCode, flags: CGEventFlags, source: CGEventSource?) throws {
        for keyDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: keyDown) else {
                throw InputError.eventCreationFailed("key")
            }
            event.flags = flags
            event.post(tap: .cghidEventTap)
        }
    }
}
