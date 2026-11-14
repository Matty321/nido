// SPDX-License-Identifier: Apache-2.0
//
// Checks WCAG 2.x contrast of the Nido color tokens in every mode.
//
// Usage: swift scripts/check-contrast.swift <tokens.json>
// Input: the local variables JSON written by FigCraft `variable.export` (format json).
// Exit status: 0 when every pair meets its minimum, 1 when at least one pair is below
// it (the pairs are listed), 2 on usage or input errors.

import Foundation

// MARK: - Rules

/// A foreground/background pair and the minimum contrast ratio it must reach.
struct Rule {
    let foreground: String
    let background: String
    let minimum: Double
    /// Optional rules are skipped (with a note) when a token is missing.
    let optional: Bool
}

/// The foreground/background pairs the components and screens actually use (ruling R-M2-13).
/// Text needs 4.5:1 (WCAG AA, normal text); status colors are symbols (dots, icons)
/// and need 3:1 (WCAG 2.1 SC 1.4.11), except statusError, which also colors error text.
///
/// Intentionally excluded from the brief's list, because no component uses them (and no usable
/// accent could pass them): textPrimary on accent, textSecondary on accent, accentText on
/// background, accentText on surface.
///
/// Rule: a new foreground/background combination used in a component or a screen must be added
/// here. Screens add: textPrimary on border (labels of the screen boards) and accentText
/// on accent for the selected sidebar row (already the primary button's pair). The VM console uses
/// fixed guest colours (#CDD2CB on #101312, 12.2:1), not tokens. M3a adds: accent on
/// background (the "con stato salvato" pill of SnapshotRow, listed below), textSecondary on surface
/// (the "In arrivo" sidebar rows) and textSecondary on surfaceRaised (sheet hints), both already listed.
let rules: [Rule] = {
    var list: [Rule] = []
    for fg in ["textPrimary", "textSecondary"] {
        for bg in ["background", "surface"] {
            list.append(Rule(foreground: fg, background: bg, minimum: 4.5, optional: false))
        }
        list.append(Rule(foreground: fg, background: "surfaceRaised", minimum: 4.5, optional: true))
    }
    // Primary buttons and the selected sidebar row of the settings windows.
    list.append(Rule(foreground: "accentText", background: "accent", minimum: 4.5, optional: false))
    // Screen boards: titles and screen labels on the desk colour.
    list.append(Rule(foreground: "textPrimary", background: "border", minimum: 4.5, optional: true))
    // Destructive buttons put accentText on statusError.
    list.append(Rule(foreground: "accentText", background: "statusError", minimum: 4.5, optional: true))
    for bg in ["background", "surface"] {
        list.append(Rule(foreground: "accent", background: bg, minimum: 4.5, optional: true))
    }
    for status in ["statusRunning", "statusPaused", "statusStopped", "statusError"] {
        // statusError is also used for error messages, so it is held to the text minimum.
        let minimum = status == "statusError" ? 4.5 : 3.0
        // StatusBadge dots sit on surfaceRaised; cards and panels on background and surface.
        for bg in ["background", "surface", "surfaceRaised"] {
            list.append(Rule(foreground: status, background: bg, minimum: minimum, optional: true))
        }
    }
    // VM tints: the system mark (logo or letter) on its tile, and the colour swatch on the card.
    for tint in ["Slate", "Indigo", "Plum", "Rose", "Clay", "Olive", "Sea", "Graphite"] {
        list.append(Rule(foreground: "vm\(tint)", background: "vm\(tint)Fill", minimum: 4.5, optional: true))
        list.append(Rule(foreground: "vm\(tint)", background: "surface", minimum: 3.0, optional: true))
    }
    return list
}()

// MARK: - Color math

struct RGB {
    let r: Double, g: Double, b: Double

    /// Relative luminance per WCAG 2.x.
    var luminance: Double {
        func channel(_ c: Double) -> Double {
            c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)
    }

    /// The color quantized to 8 bits per channel, as the generated Theme.swift uses it.
    var quantized: RGB {
        RGB(r: (r * 255).rounded() / 255, g: (g * 255).rounded() / 255, b: (b * 255).rounded() / 255)
    }

    var hex: String {
        let q = quantized
        return String(format: "#%02X%02X%02X",
                      Int((q.r * 255).rounded()), Int((q.g * 255).rounded()), Int((q.b * 255).rounded()))
    }
}

func contrast(_ a: RGB, _ b: RGB) -> Double {
    let la = a.luminance, lb = b.luminance
    return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
}

// MARK: - Input

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

func formatRatio(_ value: Double) -> String {
    String(format: "%.2f", value)
}

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    fail("usage: swift scripts/check-contrast.swift <tokens.json>")
}
let path = arguments[1]
guard let data = FileManager.default.contents(atPath: path) else {
    fail("can’t read \(path)")
}
guard
    let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
    let meta = root["meta"] as? [String: Any],
    let collections = meta["variableCollections"] as? [String: [String: Any]],
    let variables = meta["variables"] as? [String: [String: Any]]
else {
    fail("\(path) is not a valid FigCraft variables export (missing meta.variableCollections or meta.variables)")
}
guard let colorCollection = collections.values.first(where: { $0["name"] as? String == "Color" }),
      let collectionID = colorCollection["id"] as? String,
      let modes = colorCollection["modes"] as? [[String: Any]]
else {
    fail("\(path): missing the \"Color\" variable collection")
}

/// Resolves a variable's value in a mode, following aliases by mode name.
func resolveColor(_ variable: [String: Any], modeName: String, depth: Int = 0) -> RGB? {
    guard depth < 16,
          let ownCollection = collections[variable["variableCollectionId"] as? String ?? ""],
          let ownModes = ownCollection["modes"] as? [[String: Any]],
          let values = variable["valuesByMode"] as? [String: Any]
    else { return nil }
    let modeID = ownModes.first(where: { $0["name"] as? String == modeName })?["modeId"] as? String
        ?? ownCollection["defaultModeId"] as? String ?? ""
    guard let value = values[modeID] as? [String: Any] else { return nil }
    if value["type"] as? String == "VARIABLE_ALIAS",
       let target = variables[value["id"] as? String ?? ""] {
        return resolveColor(target, modeName: modeName, depth: depth + 1)
    }
    guard let r = value["r"] as? Double, let g = value["g"] as? Double, let b = value["b"] as? Double
    else { return nil }
    return RGB(r: r, g: g, b: b)
}

let colorVariables: [String: [String: Any]] = Dictionary(
    variables.values
        .filter { $0["variableCollectionId"] as? String == collectionID && $0["resolvedType"] as? String == "COLOR" }
        .compactMap { v in (v["name"] as? String).map { ($0, v) } },
    uniquingKeysWith: { first, _ in first }
)

// MARK: - Check

var failures: [String] = []
var report: [String] = []
for mode in modes {
    guard let modeName = mode["name"] as? String else { continue }
    report.append("Mode \(modeName):")
    for rule in rules {
        guard let fgVar = colorVariables[rule.foreground], let bgVar = colorVariables[rule.background] else {
            let missing = colorVariables[rule.foreground] == nil ? rule.foreground : rule.background
            if rule.optional {
                report.append("  - \(rule.foreground) on \(rule.background): skipped (missing \(missing))")
            } else {
                failures.append("\(modeName): \(rule.foreground) on \(rule.background): missing token \(missing)")
            }
            continue
        }
        guard let fg = resolveColor(fgVar, modeName: modeName)?.quantized,
              let bg = resolveColor(bgVar, modeName: modeName)?.quantized
        else {
            failures.append("\(modeName): \(rule.foreground) on \(rule.background): can’t read the value")
            continue
        }
        let ratio = contrast(fg, bg)
        let passed = ratio >= rule.minimum
        let line = "\(rule.foreground) \(fg.hex) on \(rule.background) \(bg.hex): "
            + "\(formatRatio(ratio)):1 (minimum \(formatRatio(rule.minimum)):1)"
        report.append("  \(passed ? "ok " : "NO ") \(line)")
        if !passed { failures.append("\(modeName): \(line)") }
    }
}

print(report.joined(separator: "\n"))
if failures.isEmpty {
    print("AA contrast met in all modes (\(modes.count)).")
    exit(0)
} else {
    print("\nPairs below AA (\(failures.count)):")
    for failure in failures { print("  - \(failure)") }
    exit(1)
}
