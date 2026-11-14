// SPDX-License-Identifier: Apache-2.0
//
// Design tokens (values used verbatim) and the script 01-tokens.json (page Tokens).

import Foundation

// MARK: - Tokens (values used verbatim by 01-tokens.json)

/// Color tokens: name, light (Chiaro), dark (Scuro). Order fixes the variable ids.
let colorTokens: [(String, String, String)] = [
    ("accent", "#1D6F64", "#4DB6A4"),
    ("accentText", "#FFFFFF", "#0B1F1B"),
    ("background", "#F3F1EC", "#151817"),
    ("surface", "#FBFAF7", "#1D2120"),
    ("surfaceRaised", "#FFFFFF", "#262B29"),
    ("border", "#D9D4C8", "#3A403D"),
    ("textPrimary", "#1E2320", "#ECEAE4"),
    ("textSecondary", "#5B605A", "#A6AAA3"),
    ("statusRunning", "#2F7D4E", "#5CC98A"),
    ("statusPaused", "#9A6512", "#E2AA4C"),
    ("statusStopped", "#6B6F69", "#9A9E97"),
    ("statusError", "#B42B22", "#F07A6E"),
    // VM tints (the system mark of a VM, chosen per VM): the mark and its tile's fill. OKLCH
    // L 0.48 / 0.80 for the mark, 0.935 / 0.33 for the fill, low chroma: they tell VMs apart without
    // competing with the accent (actions) or the status colours. Mark on fill ≥ 5.3:1 in both modes.
    ("vmSlate", "#376285", "#97C3E9"), ("vmSlateFill", "#DDECF9", "#273746"),
    ("vmIndigo", "#55588A", "#B4B9EF"), ("vmIndigoFill", "#E6E8FB", "#323348"),
    ("vmPlum", "#734F75", "#D6AED7"), ("vmPlumFill", "#F2E4F3", "#3E2F3F"),
    ("vmRose", "#814A60", "#E6AAC0"), ("vmRoseFill", "#F9E3EA", "#442E36"),
    ("vmClay", "#814F39", "#E6B098"), ("vmClayFill", "#F8E5DD", "#443027"),
    ("vmOlive", "#606134", "#C0C294"), ("vmOliveFill", "#EAEBDB", "#363725"),
    ("vmSea", "#316673", "#94C8D5"), ("vmSeaFill", "#DCEDF2", "#25393E"),
    ("vmGraphite", "#5F5D59", "#BFBEB8"), ("vmGraphiteFill", "#EAE9E7", "#363533"),
]
/// The VM tints in the order the app offers them (VMTint, Settings › General › Color).
let vmTints = ["Slate", "Indigo", "Plum", "Rose", "Clay", "Olive", "Sea", "Graphite"]
let spaceTokens: [(String, Double)] = [("xs", 4), ("s", 8), ("m", 12), ("l", 16), ("xl", 24), ("xxl", 32)]
let radiusTokens: [(String, Double)] = [("s", 6), ("m", 10), ("l", 14)]
let typeTokens: [(String, Double)] = [("caption", 11), ("body", 13), ("headline", 15), ("title", 22)]

let fontFamily = "Inter"
// MARK: - 01-tokens.json

/// A titled group on the token board: heading close to its content, groups further apart.
func tokenSection(_ s: Script, _ title: String, _ board: Int) -> Int {
    let box = stack(s, title, parent: board, "vertical", gap: "m", props: ["sizingH": "fill"])
    s.text(title, parent: box, size: "headline", style: "SemiBold", color: "textPrimary")
    return box
}

func tokensScript() -> Script {
    let s = Script(firstID: 2)
    s.step("page.rename", ["id": 1, "name": "Tokens"])
    // Collections and variables take sequential ids too; every bind below hard-codes
    // `VariableID:n`, so each creation step carries the id it must return (checked by --verify).
    var collectionCount = 0
    func createCollection(_ name: String, modes: [String]) {
        s.step("variable.createCollection", ["name": name, "modes": modes])
        collectionCount += 1
        s.expectVariableID("VariableCollectionId:\(collectionCount)")
    }
    func createVariable(_ collection: String, _ name: String, token: String, _ params: JSON) {
        var p: JSON = ["collection": collection, "name": name]
        p.merge(params) { _, new in new }
        s.step("variable.create", p)
        s.expectVariableID(variableID(token))
    }
    createCollection("Color", modes: ["Chiaro", "Scuro"])
    for (name, light, dark) in colorTokens {
        createVariable("Color", name, token: name, ["type": "color", "values": ["Chiaro": light, "Scuro": dark]])
    }
    for (collection, tokens) in [("Space", spaceTokens), ("Radius", radiusTokens), ("Type", typeTokens)] {
        createCollection(collection, modes: ["Valore"])
        for (name, value) in tokens {
            createVariable(collection, name, token: "\(collection)/\(name)",
                           ["type": "number", "values": ["Valore": value]])
        }
    }

    // Specimen boards, one per mode.
    for (index, mode) in ["Chiaro", "Scuro"].enumerated() {
        let board = s.frame("Token · \(mode)", parent: nil, x: Double(index) * 760, y: 0, width: 720, height: 100,
                            props: ["layout": "vertical", "sizingV": "hug"])
        s.bind(board, "fill", "background")
        s.bind(board, "gap", "Space/xxl")
        for field in ["paddingTop", "paddingRight", "paddingBottom", "paddingLeft"] {
            s.bind(board, field, "Space/xxl")
        }
        s.step("variable.setMode", ["ids": [board], "collection": "Color", "mode": mode])
        s.text("Token di Nido · \(mode)", parent: board, size: "title", style: "SemiBold", color: "textPrimary")

        let colors = tokenSection(s, "Colori", board)
        let grid = stack(s, "Campioni", parent: colors, "horizontal", gap: "m",
                         props: ["wrap": true, "crossGap": 16, "sizingH": "fill"])
        for (name, _, _) in colorTokens {
            let cell = stack(s, name, parent: grid, "vertical", gap: "xs")
            let chip = s.frame("Campione", parent: cell, width: 144, height: 48)
            s.bind(chip, "fill", name)
            s.bind(chip, "cornerRadius", "Radius/s")
            s.stroke(chip, "border")
            s.text(name, parent: cell, size: "caption", style: "SemiBold", color: "textPrimary")
        }

        let spaces = stack(s, "Scala", parent: tokenSection(s, "Spaziature", board), "vertical", gap: "s")
        for (name, value) in spaceTokens {
            let row = stack(s, name, parent: spaces, "horizontal", gap: "m", props: ["crossAlign": "center"])
            let label = stack(s, "Etichetta", parent: row, "horizontal", width: 72,
                              props: ["sizingH": "fixed"])
            s.text("\(name) · \(Int(value))", parent: label, size: "caption", color: "textSecondary")
            let bar = s.frame("Barra", parent: row, width: value, height: 12)
            s.bind(bar, "fill", "accent")
            s.bind(bar, "width", "Space/\(name)")
        }

        let radii = stack(s, "Scala", parent: tokenSection(s, "Raggi", board), "horizontal", gap: "l")
        for (name, value) in radiusTokens {
            let cell = stack(s, name, parent: radii, "vertical", gap: "xs")
            let box = s.frame("Angolo", parent: cell, width: 64, height: 48)
            s.bind(box, "fill", "surfaceRaised")
            s.bind(box, "cornerRadius", "Radius/\(name)")
            s.stroke(box, "border")
            s.text("\(name) · \(Int(value))", parent: cell, size: "caption", color: "textSecondary")
        }

        let type = stack(s, "Scala", parent: tokenSection(s, "Testo", board), "vertical", gap: "s")
        let samples = [("title", "SemiBold", "Le tue macchine virtuali"),
                       ("headline", "SemiBold", "debian-13"),
                       ("body", "Regular", "Debian 13 su arm64, 4 CPU e 8 GB di memoria."),
                       ("caption", "Regular", "Ultimo avvio oggi alle 9:41")]
        for (name, style, sample) in samples {
            let row = stack(s, name, parent: type, "horizontal", gap: "m", props: ["crossAlign": "baseline"])
            let label = stack(s, "Etichetta", parent: row, "horizontal", width: 96, props: ["sizingH": "fixed"])
            s.text("\(name) · \(Int(typeSize(name)))", parent: label, size: "caption", color: "textSecondary")
            s.text(sample, parent: row, size: name, style: style, color: "textPrimary")
        }
    }
    return s
}
