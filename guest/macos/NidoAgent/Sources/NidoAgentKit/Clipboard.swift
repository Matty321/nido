// SPDX-License-Identifier: Apache-2.0
import Foundation

/// The guest's general pasteboard, as far as `setClipboard` needs it (`SystemPasteboard` in the
/// app, a fake in the tests).
@MainActor
public protocol GuestPasteboard: AnyObject {
    /// Moves at every change of the pasteboard, by this app or any other.
    var changeCount: Int { get }
    /// Replaces the contents with `text` as a string, marked concealed so clipboard managers skip
    /// it; returns the change count after the write.
    func writeConcealed(_ text: String) -> Int
    func clearContents()
    /// The plain text on the pasteboard; `.concealed` when an item is marked concealed or
    /// transient, whatever else it holds; `.none` when there is no text or it is empty.
    func readPlain() -> PasteboardText
    /// Replaces the contents with `text` as a plain string, not concealed; returns the change count,
    /// or nil when the pasteboard refused the string.
    func writePlain(_ text: String) -> Int?
}

/// What the pasteboard holds, as far as an agent may read it.
public enum PasteboardText: Equatable, Sendable {
    case text(String)
    /// A concealed item (a password): its text is never given out.
    case concealed
    case none
    /// The system's paste privacy forbids this app to read the pasteboard.
    case denied
}

/// Puts text on the pasteboard and clears it after a delay, but only if nothing was copied since:
/// what the user copied afterwards is never thrown away. Never logs the text.
@MainActor
public final class ClipboardSetter: ClipboardSink {
    /// Runs `action` on the main actor after `seconds`.
    public typealias Schedule = @MainActor (_ seconds: Int, _ action: @escaping @MainActor () -> Void) -> Void

    private let pasteboard: any GuestPasteboard
    private let schedule: Schedule

    public init(pasteboard: any GuestPasteboard, schedule: @escaping Schedule = ClipboardSetter.afterDelay) {
        self.pasteboard = pasteboard
        self.schedule = schedule
    }

    public func set(_ text: String, clearAfter seconds: Int) async {
        let written = pasteboard.writeConcealed(text)
        schedule(seconds) { [pasteboard] in
            // Read and cleared in one main-actor turn: nothing of this app writes in between.
            if pasteboard.changeCount == written { pasteboard.clearContents() }
        }
    }

    public func readPlain() async -> PasteboardText { pasteboard.readPlain() }

    public func writePlain(_ text: String) async -> Bool { pasteboard.writePlain(text) != nil }

    /// The real clock: a task that sleeps `seconds`, then runs `action`.
    public static func afterDelay(_ seconds: Int, _ action: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            action()
        }
    }
}
