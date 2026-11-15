// SPDX-License-Identifier: Apache-2.0
import Carbon.HIToolbox
import Foundation
import NidoAgentKit
import os

/// The guest's current keyboard layout as a `KeyLayout`, for the key codes of combos: the
/// layout's own table (`kTISPropertyUnicodeKeyLayoutData`) read through `UCKeyTranslate` for
/// key codes 0…127 with no modifier. Built once per layout and rebuilt when the user switches to
/// another (the input source id changes). Nil when the layout has no such table: combos then
/// use US key codes.
final class KeyboardLayouts: Sendable {
    private struct Cached: Sendable {
        var id: String
        var layout: KeyLayout?
    }
    private let cache = OSAllocatedUnfairLock<Cached?>(initialState: nil)

    func current() -> KeyLayout? {
        // The Text Input Sources API belongs to the main thread (macOS asserts it on some
        // versions); requests arrive on the listener's threads.
        if Thread.isMainThread { return currentOnMain() }
        return DispatchQueue.main.sync { currentOnMain() }
    }

    private func currentOnMain() -> KeyLayout? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
            let idPointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID)
        else { return nil }
        let id = Unmanaged<CFString>.fromOpaque(idPointer).takeUnretainedValue() as String
        if let cached = cache.withLock({ $0 }), cached.id == id { return cached.layout }

        let layout = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData).flatMap {
            Self.layout(from: Unmanaged<CFData>.fromOpaque($0).takeUnretainedValue())
        }
        cache.withLock { $0 = Cached(id: id, layout: layout) }
        return layout
    }

    /// The `KeyLayout` of a `UCKeyboardLayout` table: what each key types alone (dead keys give
    /// their own character, `kUCKeyTranslateNoDeadKeysMask`).
    private static func layout(from data: CFData) -> KeyLayout? {
        guard let bytes = CFDataGetBytePtr(data) else { return nil }
        let keyboardType = UInt32(LMGetKbdType())
        return bytes.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { table in
            KeyLayout(translate: { code in
                var deadKeyState: UInt32 = 0
                var characters = [UniChar](repeating: 0, count: 4)
                var length = 0
                let status = UCKeyTranslate(
                    table, code, UInt16(kUCKeyActionDown), 0, keyboardType,
                    OptionBits(kUCKeyTranslateNoDeadKeysMask), &deadKeyState, characters.count, &length, &characters)
                guard status == noErr, length > 0 else { return nil }
                return String(utf16CodeUnits: characters, count: length)
            })
        }
    }
}
