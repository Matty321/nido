// SPDX-License-Identifier: Apache-2.0
import AppKit
import Carbon.HIToolbox
import Foundation

/// One key typed into the guest: a physical key (`keyCode`) with Shift and/or Option held, and
/// the character it gives on the layout it was mapped with.
struct Keystroke: Equatable, Sendable {
    let keyCode: UInt16
    let shift: Bool
    let option: Bool
    let character: String
}

/// A keyboard layout: what a physical key gives with Shift and Option, nil for nothing or a dead
/// key. `SystemKeyboardLayout` reads one of the Mac's; the tests use fixed tables.
protocol KeyboardLayout {
    func character(keyCode: UInt16, shift: Bool, option: Bool) -> String?
}

/// A keyboard layout installed on this Mac, offered as the guest's: its input source ID
/// (`com.apple.keylayout.Italian-Pro`), its name in the UI language, and whether it is one of
/// the Mac's enabled input sources (those come first in the menu).
struct KeyboardLayoutChoice: Equatable, Sendable, Identifiable {
    let id: String
    let name: String
    var enabled = false
}

/// The layouts "Type in VM" can map with: this Mac's current one, or a layout chosen for the
/// guest by its ID. `SystemKeyboardLayouts` reads the Mac's; the tests use fixed tables.
@MainActor
protocol KeyboardLayouts {
    /// The layouts installed on this Mac: the enabled ones first, each group by name.
    func available() -> [KeyboardLayoutChoice]
    /// This Mac's current layout; nil when it cannot be read.
    func current() -> (any KeyboardLayout)?
    /// The layout with this input source ID; nil when this Mac has none (or it has no data).
    func layout(id: String) -> (any KeyboardLayout)?
}

/// Where the keys go: the guest's screen (`MacDisplayController`), a recorder in the tests.
@MainActor
protocol KeystrokeSink: AnyObject {
    func type(_ strokes: [Keystroke]) async throws
}

enum KeystrokeError: LocalizedError, Equatable {
    /// The key in authorized_key.pub is not one line of `[A-Za-z0-9+/=@._ -]` (an OpenSSH key).
    case invalidKey
    /// No key on the layout chosen for the VM (else this Mac's current one) gives this character
    /// (without dead keys).
    case unmappable(Character)
    /// The guest's screen is not shown (window closed).
    case noDisplay
    /// The VM stopped or paused while the command was being typed.
    case vmNotRunning

    var errorDescription: String? {
        switch self {
        case .invalidKey:
            String(localized: "The VM’s public key isn’t a one-line OpenSSH key: Nido doesn’t type it.")
        case .unmappable(let character):
            String(localized: "The character \(String(character)) can’t be typed with the keyboard chosen for this VM: type the command yourself in the VM.")
        case .noDisplay:
            String(localized: "The VM’s screen isn’t shown: start the VM and try again. If typing had begun, the command may be only partly typed: clear the line in the VM’s Terminal before you try again.")
        case .vmNotRunning:
            String(localized: "The VM is no longer running: the command may be only partly typed. Clear the line in the VM’s Terminal before you try again.")
        }
    }
}

/// "Digita nella VM" (M3b): the constant authorize command around the VM's public key,
/// turned into physical keys with a layout of this Mac. A key sends a physical key, not a
/// character: the result is right only when the guest uses that layout. The layout is the one
/// chosen for the guest in the panel (`VMConfig.guestKeyboardLayoutID`), else the Mac's current
/// one (seen live: a German Mac typing into an Italian guest turned `'` into `§` and swapped y/z).
enum GuestKeystrokes {
    /// The only characters a key may contain to be typed.
    private static let keyCharacters = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=@._ -")
    /// Key types Nido accepts at the start of the line.
    private static let keyTypes = ["ssh-", "ecdsa-", "sk-"]

    /// Longest key typed (an RSA 16384-bit key is about 2.8 KB).
    static let maxKeyLength = 8192

    /// One line of `[A-Za-z0-9+/=@._ -]`, at most `maxKeyLength` bytes: a key type, the base64
    /// body, an optional comment.
    static func isTypablePublicKey(_ key: String) -> Bool {
        guard !key.isEmpty, key.utf8.count <= maxKeyLength, key.allSatisfy(keyCharacters.contains) else { return false }
        let fields = key.split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count >= 2, let type = fields.first else { return false }
        return keyTypes.contains { type.hasPrefix($0) } && !fields[1].isEmpty
    }

    /// The command of step 3 with `publicKey` (checked first: never anything else).
    static func authorizeCommand(publicKey: String) throws(KeystrokeError) -> String {
        guard isTypablePublicKey(publicKey) else { throw .invalidKey }
        return command(around: publicKey)
    }

    /// The command as shown, also with a placeholder in place of the key. `"$HOME"` rather than
    /// `~`: on some layouts (Italian) `~` is only a dead key, which is never typed.
    static func command(around key: String) -> String {
        #"mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh" && echo '"# + key
            + #"' >> "$HOME/.ssh/authorized_keys" && chmod 600 "$HOME/.ssh/authorized_keys""#
    }

    /// Keypad, Return, Tab, Delete, Escape and the function keys: never used to type text.
    private static let skippedKeyCodes: Set<UInt16> = [
        36, 48, 51, 53, 65, 67, 69, 71, 75, 76, 78, 81, 82, 83, 84, 85, 86, 87, 88, 89, 91, 92,
    ]

    /// The keys for `text` on `layout`, the fewest modifiers first (none, Shift, Option, both).
    /// Throws `.unmappable` for the first character no key gives.
    static func keystrokes(for text: String, layout: some KeyboardLayout) throws(KeystrokeError) -> [Keystroke] {
        let combos: [(shift: Bool, option: Bool)] = [(false, false), (true, false), (false, true), (true, true)]
        var table: [String: Keystroke] = [:]
        for combo in combos {
            for code in UInt16(0)..<128 where !skippedKeyCodes.contains(code) {
                guard let produced = layout.character(keyCode: code, shift: combo.shift, option: combo.option),
                      produced.count == 1, table[produced] == nil else { continue }
                table[produced] = Keystroke(keyCode: code, shift: combo.shift, option: combo.option, character: produced)
            }
        }
        var strokes: [Keystroke] = []
        for character in text {
            guard let stroke = table[String(character)] else { throw .unmappable(character) }
            strokes.append(stroke)
        }
        return strokes
    }
}

/// A keyboard layout of this Mac, read once when created, translated with `UCKeyTranslate`:
/// the current one (`TISCopyCurrentKeyboardLayoutInputSource`) or one installed, by its input
/// source ID. Nil when the layout is missing or has no Unicode data.
struct SystemKeyboardLayout: KeyboardLayout {
    private let data: Data
    private let keyboardType: UInt32

    @MainActor
    init?() {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() else { return nil }
        self.init(source: source)
    }

    @MainActor
    init?(id: String) {
        let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource],
              let source = list.first else { return nil }
        self.init(source: source)
    }

    @MainActor
    private init?(source: TISInputSource) {
        guard let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        keyboardType = UInt32(LMGetKbdType())
    }

    func character(keyCode: UInt16, shift: Bool, option: Bool) -> String? {
        let modifiers = UInt32(((shift ? shiftKey : 0) | (option ? optionKey : 0)) >> 8) & 0xff
        return data.withUnsafeBytes { buffer -> String? in
            guard let base = buffer.baseAddress else { return nil }
            let layout = base.assumingMemoryBound(to: UCKeyboardLayout.self)
            var deadKeyState: UInt32 = 0
            var length = 0
            var chars = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(
                layout, keyCode, UInt16(kUCKeyActionDown), modifiers, keyboardType, 0,
                &deadKeyState, chars.count, &length, &chars)
            // A dead key waits for the next key: never used.
            guard status == noErr, deadKeyState == 0, length > 0 else { return nil }
            return String(utf16CodeUnits: chars, count: length)
        }
    }
}

/// This Mac's keyboard layouts (Text Input Sources): every installed keyboard layout with Unicode
/// data, the ones enabled in the Mac's Input Sources first, each group by its localized name.
struct SystemKeyboardLayouts: KeyboardLayouts {
    func available() -> [KeyboardLayoutChoice] {
        let filter = [kTISPropertyInputSourceType as String: kTISTypeKeyboardLayout as String] as CFDictionary
        func sources(includeAllInstalled: Bool) -> [TISInputSource] {
            TISCreateInputSourceList(filter, includeAllInstalled)?.takeRetainedValue() as? [TISInputSource] ?? []
        }
        func string(_ source: TISInputSource, _ key: CFString) -> String? {
            guard let raw = TISGetInputSourceProperty(source, key) else { return nil }
            return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
        }
        let enabled = Set(sources(includeAllInstalled: false).compactMap { string($0, kTISPropertyInputSourceID) })
        var seen = Set<String>()
        let choices = sources(includeAllInstalled: true).compactMap { source -> KeyboardLayoutChoice? in
            guard TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) != nil,
                  let id = string(source, kTISPropertyInputSourceID), seen.insert(id).inserted else { return nil }
            return KeyboardLayoutChoice(
                id: id, name: string(source, kTISPropertyLocalizedName) ?? id, enabled: enabled.contains(id))
        }
        return choices.sorted {
            $0.enabled != $1.enabled ? $0.enabled : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    func current() -> (any KeyboardLayout)? { SystemKeyboardLayout() }

    func layout(id: String) -> (any KeyboardLayout)? { SystemKeyboardLayout(id: id) }
}
