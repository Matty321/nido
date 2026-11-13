// SPDX-License-Identifier: Apache-2.0
import AppKit
import NidoCore

/// "Apri il Terminale" for a key Nido cannot use from the background (a passphrase without the
/// agent, a changed host key): Terminal runs `nido ssh <vm>`, where ssh can ask the user.
///
/// No AppleScript and no shell with user input: a `.command` file of constant text (the VM name
/// is a validated `VMName`, single-quoted besides) is written 0700 in a private temporary
/// directory and opened with Terminal.
enum TerminalLauncher {
    /// The file's text: `nido ssh '<vm>'`, or a hint in the app's language when `nido` is not on
    /// the PATH. The hint is single-quoted too: a translation never reaches the shell as code.
    nonisolated static func script(for name: VMName) -> String {
        let hint = String(localized: "The nido command isn’t in your PATH: install it, or connect with ssh and the VM’s key.")
        return """
            #!/bin/sh
            # Nido: nido ssh \(name.rawValue)
            if command -v nido >/dev/null 2>&1; then
                exec nido ssh \(quoted(name.rawValue))
            fi
            echo \(quoted(hint))

            """
    }

    /// `text` as one single-quoted shell word.
    nonisolated static func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Writes the script and opens it in Terminal. False when the file or Terminal failed.
    @MainActor
    @discardableResult
    static func openSSH(to name: VMName) -> Bool {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("nido-terminal-\(UUID().uuidString)", isDirectory: true)
        let file = directory.appendingPathComponent("nido-ssh-\(name.rawValue).command", isDirectory: false)
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            // A fresh 0700 directory with a random name: no one else can put a link in its place.
            guard FileManager.default.createFile(
                atPath: file.path, contents: Data(script(for: name).utf8),
                attributes: [.posixPermissions: 0o700])
            else { return false }
        } catch {
            return false
        }
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
            return false
        }
        NSWorkspace.shared.open([file], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
        return true
    }
}
