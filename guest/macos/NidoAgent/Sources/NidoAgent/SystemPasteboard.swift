// SPDX-License-Identifier: Apache-2.0
import AppKit
import NidoAgentKit

/// `NSPasteboard.general` for `ClipboardSetter`. The text is a plain string plus the marker type
/// of nspasteboard.org that clipboard managers skip; the marker carries no copy of the text.
@MainActor
final class SystemPasteboard: GuestPasteboard {
    static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    private var pasteboard: NSPasteboard { .general }

    var changeCount: Int { pasteboard.changeCount }

    func writeConcealed(_ text: String) -> Int {
        pasteboard.declareTypes([.string, Self.concealedType], owner: nil)
        pasteboard.setString(text, forType: .string)
        pasteboard.setData(Data(), forType: Self.concealedType)
        return pasteboard.changeCount
    }

    func clearContents() {
        pasteboard.clearContents()
    }
}
