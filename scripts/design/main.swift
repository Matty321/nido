// SPDX-License-Identifier: Apache-2.0
//
// Writes the FigCraft scripts of Nido into a directory, or checks a run log against a script.
//
// Usage (through scripts/gen-design-scripts.sh, which compiles this folder):
//   gen-design-scripts <output directory>
//   gen-design-scripts --verify <script.json> <log of figcraft-cli run>
//   gen-design-scripts --count-clicks <03-screens.json>  (clicks of F01 on page Prototype)
//   gen-design-scripts --list-screens        (the names of the screen frames, one per line)

import Foundation

let arguments = CommandLine.arguments
if arguments.count == 3 && arguments[1] == "--count-clicks" {
    countClicks(scriptPath: arguments[2])
}
if arguments.count == 2 && arguments[1] == "--list-screens" {
    // One line per screen frame on page Screens (for the previews of design-build.sh).
    let script = Script(firstID: 1)
    for (label, _) in screenList(script) {
        for mode in ["Chiaro", "Scuro"] { print("\(label) · \(mode)") }
    }
    exit(0)
}
if arguments.count == 4 && arguments[1] == "--verify" {
    verify(scriptPath: arguments[2], logPath: arguments[3])
}
guard arguments.count == 2 else {
    let usage = "Uso: scripts/gen-design-scripts.sh <cartella di uscita>\n"
        + "     scripts/gen-design-scripts.sh --verify <script.json> <log di figcraft-cli run>\n"
        + "     scripts/gen-design-scripts.sh --count-clicks <03-screens.json>\n"
        + "     scripts/gen-design-scripts.sh --list-screens\n"
    FileHandle.standardError.write(Data(usage.utf8))
    exit(2)
}
let directory = URL(fileURLWithPath: arguments[1], isDirectory: true)
do {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let tokens = tokensScript()
    try write(tokens, to: directory.appendingPathComponent("01-tokens.json"))
    let components = buildComponents(firstID: tokens.maxID + 1)
    try write(components, to: directory.appendingPathComponent("02-components.json"))
    let screens = screensScript(continuing: components)
    try write(screens, to: directory.appendingPathComponent("03-screens.json"))
    let icon = iconScript(continuing: screens)
    try write(icon, to: directory.appendingPathComponent("04-icon.json"))
    let counts = [("01-tokens.json", tokens), ("02-components.json", components), ("03-screens.json", screens),
                  ("04-icon.json", icon)].map { "\($0.0) (\($0.1.steps.count) passi)" }
    print("Scritti \(counts.joined(separator: ", ")) in \(directory.path).")
} catch {
    FileHandle.standardError.write(Data("Errore: \(error.localizedDescription)\n".utf8))
    exit(1)
}
