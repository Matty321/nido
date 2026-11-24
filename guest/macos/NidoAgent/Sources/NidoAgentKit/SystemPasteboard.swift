// SPDX-License-Identifier: Apache-2.0
import AppKit

/// `NSPasteboard.general` for `ClipboardSetter`. The text is a plain string plus the marker type
/// of nspasteboard.org that clipboard managers skip; the marker carries no copy of the text.
@MainActor
public final class SystemPasteboard: GuestPasteboard {
    public static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    private let pasteboard: NSPasteboard

    private let isReadDenied: @MainActor () -> Bool

    public init(pasteboard: NSPasteboard = .general, isReadDenied: @escaping @MainActor () -> Bool = SystemPasteboard.pasteAccessDenied) {
        self.pasteboard = pasteboard
        self.isReadDenied = isReadDenied
    }

    public var changeCount: Int { pasteboard.changeCount }

    public func writeConcealed(_ text: String) -> Int {
        pasteboard.declareTypes([.string, Self.concealedType], owner: nil)
        pasteboard.setString(text, forType: .string)
        pasteboard.setData(Data(), forType: Self.concealedType)
        return pasteboard.changeCount
    }

    /// Types that mark an item as not for reading (nspasteboard.org): a password, or a one-time
    /// value a clipboard manager must skip. Both are refused with the concealed message.
    private static let unreadableTypes: [NSPasteboard.PasteboardType] = [
        concealedType, NSPasteboard.PasteboardType("org.nspasteboard.TransientType"),
    ]

    private func isMarkedUnreadable() -> Bool {
        let types = pasteboard.types ?? []
        return Self.unreadableTypes.contains { types.contains($0) }
    }

    /// Test seam: runs right after the string was read, to simulate another app writing then.
    var afterReadingString: (@MainActor () -> Void)?

    /// The marker is checked before the read and again after it. `changeCount` moves on
    /// `clearContents` and `declareTypes` only, not on `setString` or `setData`, so an app that
    /// writes `clearContents`, `setString(password)` and only then adds the marker can't be seen
    /// by the count: the second check, after the string was read, refuses text that has become
    /// marked meanwhile. A write landing between the second check and the return stays possible
    /// (see docs/SECURITY.md, Residual risks). A change of the count between check and read gives
    /// one more attempt; a second change gives `.none`.
    public func readPlain() -> PasteboardText {
        if isReadDenied() { return .denied }
        for _ in 0..<2 {
            let before = pasteboard.changeCount
            if isMarkedUnreadable() { return .concealed }
            let text = pasteboard.string(forType: .string)
            afterReadingString?()
            if isMarkedUnreadable() { return .concealed }
            guard pasteboard.changeCount == before else { continue }
            guard let text, !text.isEmpty else { return .none }
            return .text(text)
        }
        return .none
    }

    /// The change count after the write, or nil when the pasteboard refused the string.
    public func writePlain(_ text: String) -> Int? {
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else { return nil }
        return pasteboard.changeCount
    }

    public func clearContents() {
        pasteboard.clearContents()
    }

    /// Paste privacy (macOS 15.4+): true when the user chose "Don't allow" for this app. `.ask`
    /// is not blocked: the system prompts by itself when it must.
    public static func pasteAccessDenied() -> Bool {
        if #available(macOS 15.4, *) { return NSPasteboard.general.accessBehavior == .alwaysDeny }
        return false
    }
}
