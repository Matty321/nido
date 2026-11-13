// SPDX-License-Identifier: Apache-2.0
import Foundation

/// What `nido-provision` (Guest Tools) says when a step fails, or warns: since Guest Tools 1.5.0
/// `<code>: <English message>`, the code stable and listed in provision.py's `MESSAGES`; earlier
/// Guest Tools write Italian free text. `text(_:)` shows Nido's own text for a code it knows, in
/// the UI language, with the values read back from the English message (sizes in the language's
/// number format); a known code with a message of another shape shows that message without the
/// code; anything else (older Guest Tools' Italian, a code of newer Guest Tools) comes back as
/// it arrived. The value stored and carried around
/// (`AIRuntimeError.stepFailed`, `PullProgress.warning`) is always the guest's text.
public enum GuestMessage {
    /// Code → the guest's English message, `%@` where a value goes: provision.py's `MESSAGES`
    /// (`%s` there), word for word (`GuestMessageTests.everyGuestCodeIsKnown`).
    static let templates: [String: String] = [
        "release_invalid": "the Guest Tools’ release.json isn’t valid (%@)",
        "architecture_unsupported": "unsupported architecture (%@): aarch64 required",
        "ollama_foreign": "Ollama wasn’t installed by Nido: manage it yourself",
        "ollama_link_foreign": "/usr/local/bin/ollama already holds an Ollama that Nido didn’t install: remove it or use that one",
        "ollama_not_installed": "Ollama isn’t installed",
        "ollama_not_running": "Ollama isn’t running: start it or install it",
        "ollama_files_damaged": "the files of Ollama %@ are incomplete or damaged: install it again with Try Again",
        "ollama_not_responding": "Ollama isn’t responding on 127.0.0.1:11434",
        "service_inactive": "the ollama service isn’t active",
        "service_stop_failed": "the ollama service didn’t stop",
        "disk_space_low": "not enough disk space: %@ needed, %@ free",
        "usr_local_space_low": "not enough disk space in /usr/local: %@ needed, %@ free",
        "archive_from_mac_required": "the Ollama archive comes from the Mac: install Ollama from the Nido app or update Nido",
        "archive_receive_interrupted": "the Ollama transfer was interrupted (%@): click Try Again",
        "archive_incomplete": "the Ollama archive is incomplete: click Try Again",
        "archive_checksum_mismatch": "the Ollama archive’s checksum doesn’t match: file discarded, click Try Again",
        "archive_extract_failed": "couldn’t extract the Ollama archive: %@",
        "archive_wrong_version": "the Ollama archive doesn’t contain version %@",
        "user_create_failed": "couldn’t create the user %@: %@",
        "pull_disk_space_low": "not enough disk space: only %@ free",
        "model_disk_space_low": "not enough disk space for the model: %@ needed, %@ free",
        "model_pull_failed": "Ollama reported an error: %@",
        "model_pull_interrupted": "the model download was interrupted: click Try Again",
        "model_missing_after_pull": "the model %@ is missing after the download",
        "model_remove_failed": "the model %@ wasn’t removed",
        "model_memory_low": "the VM has %@ of RAM and the model takes %@: it may be slow or fail to start",
        "interrupted": "interrupted: click Try Again",
        "unexpected_error": "unexpected error (%@: %@)",
        "busy": "another step is running, try again shortly",
    ]

    /// The code of a guest message this Nido knows, nil for anything else (older Guest Tools'
    /// Italian text, a code of newer Guest Tools).
    static func code(of message: String) -> String? {
        guard let colon = message.range(of: ": ") else { return nil }
        let code = String(message[..<colon.lowerBound])
        return templates[code] == nil ? nil : code
    }

    /// The text to show for a guest message, in the UI language.
    public static func text(_ message: String) -> String {
        text(message, language: L10n.language)
    }

    /// `text(_:)` in `language` (tests). A known code whose message has another shape (cut,
    /// reworded) shows the guest's English message, without the code.
    static func text(_ message: String, language: String) -> String {
        guard let code = code(of: message), let template = templates[code] else { return message }
        let english = String(message.dropFirst(code.count + 2))
        guard let values = values(in: english, template: template),
            let text = localized(code, values, language: language)
        else { return english }
        return text
    }

    /// The values of `message` where `template` has `%@`, or nil when it has another shape.
    private static func values(in message: String, template: String) -> [String]? {
        let parts = template.components(separatedBy: "%@")
        let pattern = "^" + parts.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "(.*?)") + "$"
        guard let regex = try? NSRegularExpression(pattern: pattern),
            let match = regex.firstMatch(in: message, range: NSRange(message.startIndex..., in: message))
        else { return nil }
        return (1..<match.numberOfRanges).map { index in
            Range(match.range(at: index), in: message).map { String(message[$0]) } ?? ""
        }
    }

    /// A size as the guest writes it (`5.2 GiB`, `812 MiB`) with the language's decimal separator;
    /// anything else as it is.
    private static func size(_ value: String, language: String) -> String {
        guard value.wholeMatch(of: /[0-9]+\.[0-9] [GM]iB/) != nil else { return value }
        let separator = L10n.locale(for: language).decimalSeparator ?? "."
        return value.replacingOccurrences(of: ".", with: separator)
    }

    private static func localized(_ code: String, _ v: [String], language: String) -> String? {
        let size = { (value: String) in Self.size(value, language: language) }
        return switch (code, v.count) {
        case ("release_invalid", 1):
            L10n.string("the Guest Tools’ release.json isn’t valid (\(v[0]))", language: language)
        case ("architecture_unsupported", 1):
            L10n.string("unsupported architecture (\(v[0])): aarch64 required", language: language)
        case ("ollama_foreign", 0):
            L10n.string("Ollama wasn’t installed by Nido: manage it yourself", language: language)
        case ("ollama_link_foreign", 0):
            L10n.string("/usr/local/bin/ollama already holds an Ollama that Nido didn’t install: remove it or use that one", language: language)
        case ("ollama_not_installed", 0):
            L10n.string("Ollama isn’t installed", language: language)
        case ("ollama_not_running", 0):
            L10n.string("Ollama isn’t running: start it or install it", language: language)
        case ("ollama_files_damaged", 1):
            L10n.string("the files of Ollama \(v[0]) are incomplete or damaged: install it again with Try Again", language: language)
        case ("ollama_not_responding", 0):
            L10n.string("Ollama isn’t responding on 127.0.0.1:11434", language: language)
        case ("service_inactive", 0):
            L10n.string("the ollama service isn’t active", language: language)
        case ("service_stop_failed", 0):
            L10n.string("the ollama service didn’t stop", language: language)
        case ("disk_space_low", 2):
            L10n.string("not enough disk space: \(size(v[0])) needed, \(size(v[1])) free", language: language)
        case ("usr_local_space_low", 2):
            L10n.string("not enough disk space in /usr/local: \(size(v[0])) needed, \(size(v[1])) free", language: language)
        case ("archive_from_mac_required", 0):
            L10n.string("the Ollama archive comes from the Mac: install Ollama from the Nido app or update Nido", language: language)
        case ("archive_receive_interrupted", 1):
            L10n.string("the Ollama transfer was interrupted (\(v[0])): click Try Again", language: language)
        case ("archive_incomplete", 0):
            L10n.string("the Ollama archive is incomplete: click Try Again", language: language)
        case ("archive_checksum_mismatch", 0):
            L10n.string("the Ollama archive’s checksum doesn’t match: file discarded, click Try Again", language: language)
        case ("archive_extract_failed", 1):
            L10n.string("couldn’t extract the Ollama archive: \(v[0])", language: language)
        case ("archive_wrong_version", 1):
            L10n.string("the Ollama archive doesn’t contain version \(v[0])", language: language)
        case ("user_create_failed", 2):
            L10n.string("couldn’t create the user \(v[0]): \(v[1])", language: language)
        case ("pull_disk_space_low", 1):
            L10n.string("not enough disk space: only \(size(v[0])) free", language: language)
        case ("model_disk_space_low", 2):
            L10n.string("not enough disk space for the model: \(size(v[0])) needed, \(size(v[1])) free", language: language)
        case ("model_pull_failed", 1):
            L10n.string("Ollama reported an error: \(v[0])", language: language)
        case ("model_pull_interrupted", 0):
            L10n.string("the model download was interrupted: click Try Again", language: language)
        case ("model_missing_after_pull", 1):
            L10n.string("the model \(v[0]) is missing after the download", language: language)
        case ("model_remove_failed", 1):
            L10n.string("the model \(v[0]) wasn’t removed", language: language)
        case ("model_memory_low", 2):
            L10n.string("the VM has \(size(v[0])) of RAM and the model takes \(size(v[1])): it may be slow or fail to start", language: language)
        case ("interrupted", 0):
            L10n.string("interrupted: click Try Again", language: language)
        case ("unexpected_error", 2):
            L10n.string("unexpected error (\(v[0]): \(v[1]))", language: language)
        case ("busy", 0):
            L10n.string("another step is running, try again shortly", language: language)
        default:
            nil
        }
    }
}
