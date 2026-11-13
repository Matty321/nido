// SPDX-License-Identifier: Apache-2.0
//
// Generates App/Nido/Design/Theme.swift from the design tokens.
//
// Usage: swift scripts/gen-theme.swift <tokens.json> <Theme.swift>
// Input: the local variables JSON written by FigCraft `variable.export` (format json).
// The output is deterministic: collections and variables are sorted by name, colors are
// quantized to 8 bits per channel and numbers printed with a fixed format.

import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    fail("usage: swift scripts/gen-theme.swift <tokens.json> <Theme.swift>")
}
let inputPath = arguments[1]
let outputPath = arguments[2]

guard let data = FileManager.default.contents(atPath: inputPath) else {
    fail("can’t read \(inputPath)")
}
guard
    let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
    let meta = root["meta"] as? [String: Any],
    let collections = meta["variableCollections"] as? [String: [String: Any]],
    let variables = meta["variables"] as? [String: [String: Any]]
else {
    fail("\(inputPath) is not a valid FigCraft variables export (missing meta.variableCollections or meta.variables)")
}

// MARK: - Naming

/// Swift enum name for each token collection; `Type` is a reserved word in Swift.
let enumNames: [String: String] = ["Color": "Color", "Space": "Space", "Radius": "Radius", "Type": "TypeSize"]
let lightModeName = "Chiaro"
let darkModeName = "Scuro"

let swiftKeywords: Set<String> = [
    "as", "break", "case", "catch", "class", "continue", "default", "defer", "do", "else", "enum",
    "extension", "fallthrough", "false", "for", "func", "guard", "if", "import", "in", "init",
    "inout", "internal", "is", "let", "nil", "operator", "private", "protocol", "public", "repeat",
    "return", "self", "Self", "static", "struct", "subscript", "super", "switch", "throw", "throws",
    "true", "try", "Type", "typealias", "var", "where", "while",
]

/// Turns a token name ("text/primary", "accent-text", "2xl") into a Swift identifier.
func identifier(_ name: String, upperFirst: Bool = false) -> String {
    let parts = name.split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init)
    guard !parts.isEmpty else { fail("invalid token name: \"\(name)\"") }
    var result = parts[0] + parts.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
    if upperFirst {
        result = result.prefix(1).uppercased() + result.dropFirst()
    }
    if result.first!.isNumber { result = "_" + result }
    return swiftKeywords.contains(result) ? "`\(result)`" : result
}

// MARK: - Values

struct RGBA { let r: Int, g: Int, b: Int, a: Int }

func modeID(named modeName: String?, in collection: [String: Any]) -> String? {
    let modes = collection["modes"] as? [[String: Any]] ?? []
    if let modeName, let match = modes.first(where: { $0["name"] as? String == modeName }) {
        return match["modeId"] as? String
    }
    return collection["defaultModeId"] as? String
}

/// Resolves a variable's raw value in a mode (by name; nil = default mode), following aliases.
func resolve(_ variable: [String: Any], modeName: String?, depth: Int = 0) -> Any? {
    guard depth < 16,
          let collection = collections[variable["variableCollectionId"] as? String ?? ""],
          let values = variable["valuesByMode"] as? [String: Any],
          let id = modeID(named: modeName, in: collection),
          let value = values[id]
    else { return nil }
    if let alias = value as? [String: Any], alias["type"] as? String == "VARIABLE_ALIAS" {
        guard let target = variables[alias["id"] as? String ?? ""] else { return nil }
        return resolve(target, modeName: modeName, depth: depth + 1)
    }
    return value
}

func rgba(_ value: Any?, token: String) -> RGBA {
    guard let dict = value as? [String: Any],
          let r = dict["r"] as? Double, let g = dict["g"] as? Double, let b = dict["b"] as? Double
    else { fail("can’t read the color of token \(token)") }
    let a = dict["a"] as? Double ?? 1
    func byte(_ c: Double) -> Int { Int((min(max(c, 0), 1) * 255).rounded()) }
    return RGBA(r: byte(r), g: byte(g), b: byte(b), a: byte(a))
}

func hexLiteral(_ c: RGBA) -> String { String(format: "0x%02X%02X%02X", c.r, c.g, c.b) }
func alphaLiteral(_ c: RGBA) -> String { String(format: "0x%02X", c.a) }

/// Arguments of `SwiftUI.Color(light:dark:)`, or of the variant with one alpha per mode.
func colorArguments(light: RGBA, dark: RGBA) -> String {
    if light.a == 255 && dark.a == 255 {
        return "light: \(hexLiteral(light)), dark: \(hexLiteral(dark))"
    }
    return "light: \(hexLiteral(light)), alpha: \(alphaLiteral(light)), dark: \(hexLiteral(dark)), alpha: \(alphaLiteral(dark))"
}

func numberLiteral(_ value: Any?, token: String) -> String {
    guard let number = value as? Double ?? (value as? Int).map(Double.init) else {
        fail("can’t read the number of token \(token)")
    }
    if number == number.rounded() { return String(Int(number)) }
    var text = String(format: "%.4f", number)
    while text.hasSuffix("0") { text.removeLast() }
    return text
}

// MARK: - Generation

var body: [String] = []
let sortedCollections = collections.values.sorted {
    (enumNames[$0["name"] as? String ?? ""] ?? $0["name"] as? String ?? "")
        < (enumNames[$1["name"] as? String ?? ""] ?? $1["name"] as? String ?? "")
}
for collection in sortedCollections {
    guard let collectionName = collection["name"] as? String, let collectionID = collection["id"] as? String else {
        continue
    }
    let members = variables.values
        .filter { $0["variableCollectionId"] as? String == collectionID }
        .sorted { ($0["name"] as? String ?? "") < ($1["name"] as? String ?? "") }
    guard !members.isEmpty else { continue }
    let enumName = enumNames[collectionName] ?? identifier(collectionName, upperFirst: true)
    body.append("")
    body.append("    enum \(enumName) {")
    for variable in members {
        let name = variable["name"] as? String ?? ""
        let token = "\(collectionName)/\(name)"
        let id = identifier(name)
        switch variable["resolvedType"] as? String {
        case "COLOR":
            let light = rgba(resolve(variable, modeName: lightModeName), token: token)
            let dark = rgba(resolve(variable, modeName: darkModeName), token: token)
            body.append("        static let \(id) = SwiftUI.Color(\(colorArguments(light: light, dark: dark)))")
        case "FLOAT":
            body.append("        static let \(id): CGFloat = \(numberLiteral(resolve(variable, modeName: nil), token: token))")
        case "STRING":
            guard let text = resolve(variable, modeName: nil) as? String else { fail("can’t read the text of token \(token)") }
            let escaped = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            body.append("        static let \(id) = \"\(escaped)\"")
        case "BOOLEAN":
            guard let flag = resolve(variable, modeName: nil) as? Bool else { fail("can’t read the value of token \(token)") }
            body.append("        static let \(id) = \(flag)")
        default:
            fail("unsupported type for token \(token)")
        }
    }
    body.append("    }")
}

let output = """
    // Generato da scripts/gen-theme.swift: non modificare
    // SPDX-License-Identifier: Apache-2.0
    //
    // Source: design/tokens.json, the FigCraft variables exported by scripts/design-build.sh.

    import AppKit
    import SwiftUI

    /// Nido design tokens. Views use these values (and the `Nido*` components) only.
    enum Theme {
    \(body.dropFirst().joined(separator: "\n"))
    }

    extension SwiftUI.Color {
        /// A color that follows the effective appearance: `light` in Aqua, `dark` in Dark Aqua.
        /// Components are sRGB `0xRRGGBB`.
        init(light: UInt32, dark: UInt32) {
            self.init(light: light, alpha: 0xFF, dark: dark, alpha: 0xFF)
        }

        /// Same as `init(light:dark:)` with an alpha (`0x00`–`0xFF`) per appearance.
        init(light: UInt32, alpha lightAlpha: UInt32, dark: UInt32, alpha darkAlpha: UInt32) {
            let provider: @Sendable (NSAppearance) -> NSColor = { appearance in
                let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                return NSColor(themeHex: isDark ? dark : light, alpha: isDark ? darkAlpha : lightAlpha)
            }
            self.init(nsColor: NSColor(name: nil, dynamicProvider: provider))
        }
    }

    private extension NSColor {
        convenience init(themeHex hex: UInt32, alpha: UInt32) {
            self.init(
                srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: CGFloat(alpha & 0xFF) / 255
            )
        }
    }

    """

let outputURL = URL(fileURLWithPath: outputPath)
do {
    try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(output.utf8).write(to: outputURL, options: .atomic)
} catch {
    fail("can’t write \(outputPath): \(error.localizedDescription)")
}
print("Wrote \(outputPath) (\(variables.count) tokens).")
