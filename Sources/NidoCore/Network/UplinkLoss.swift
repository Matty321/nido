// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Why the egress relay lost gvproxy, as `.uplinkLost(reason:)` carries it and `egress.log` stores
/// it: a language-neutral code (log files are not localized), turned into text in the UI language
/// only when shown (`text(_:)`). Lines written by older versions hold Italian free text instead:
/// `text(_:)` returns anything that is not a code as it is.
public enum UplinkLoss {
    /// gvproxy was killed by `signal`.
    public static func signal(_ signal: Int32) -> String { "gvproxy-signal:\(signal)" }
    /// gvproxy exited with `status`.
    public static func exit(_ status: Int32) -> String { "gvproxy-exit:\(status)" }
    /// gvproxy's socket stopped taking frames.
    public static let socketUnresponsive = "gvproxy-socket-unresponsive"
    /// gvproxy's socket hung up.
    public static let socketClosed = "gvproxy-socket-closed"

    /// The text of a stored reason in the UI language; anything that is not a code (older lines'
    /// Italian text, a reason from elsewhere) comes back unchanged.
    public static func text(_ stored: String) -> String {
        text(stored, language: L10n.language)
    }

    /// `text(_:)` in `language` (tests).
    static func text(_ stored: String, language: String) -> String {
        if stored == socketUnresponsive {
            return L10n.string("gvproxy’s socket stopped responding", language: language)
        }
        if stored == socketClosed {
            return L10n.string("gvproxy’s socket closed", language: language)
        }
        if let number = number(after: "gvproxy-signal:", in: stored) {
            return L10n.string("gvproxy was stopped by signal \(number)", language: language)
        }
        if let number = number(after: "gvproxy-exit:", in: stored) {
            return L10n.string("gvproxy exited (code \(number))", language: language)
        }
        return stored
    }

    /// The decimal digits after `prefix`, as text (never grouped), or nil.
    private static func number(after prefix: String, in stored: String) -> String? {
        guard stored.hasPrefix(prefix) else { return nil }
        let digits = stored.dropFirst(prefix.count)
        guard !digits.isEmpty, digits.count <= 10, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return String(digits)
    }
}
