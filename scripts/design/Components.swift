// SPDX-License-Identifier: Apache-2.0
//
// The script 02-components.json (page Components): every Nido component and its variants.

import Foundation

// MARK: - 02-components.json

/// "Ponte AI attivo": the privacy indicator of a VM whose remote AI bridge is on (spec H), in the
/// library card and in the VM window. An outlined pill like StatusBadge, with an accent dot.
@discardableResult
func bridgePill(_ s: Script, parent: Int) -> Int {
    let pill = stack(s, "AI bridge active", parent: parent, "horizontal", gap: "xs", padding: ["0", "s"],
                     props: ["crossAlign": "center", "sizingV": "fixed"])
    s.set(pill, ["height": 20])
    s.bind(pill, "fill", "background")
    s.bind(pill, "cornerRadius", "Radius/m")
    s.stroke(pill, "accent")
    let dot = s.ellipse(parent: pill, size: 8)
    s.bind(dot, "fill", "accent")
    s.text("AI bridge active", parent: pill, size: "caption", style: "SemiBold", color: "textPrimary")
    return pill
}

struct Built {
    /// Component (or variant) ids by variant value, in order.
    var variants: [(String, Int)] = []
    var set: Int = 0
}

func buildComponents(firstID: Int) -> Script {
    let s = Script(firstID: firstID)
    s.page("Components")
    let light = s.frame("Componenti · Chiaro", parent: nil, x: 0, y: 0, width: 1180, height: 100,
                        props: ["layout": "vertical", "sizingV": "hug"])
    boardStyle(s, light, mode: "Chiaro")
    s.text("Componenti di Nido · Chiaro", parent: light, size: "title", style: "SemiBold", color: "textPrimary")

    var sections: [(String, Built, String)] = []  // title, built, note

    var notes: [String: String] = [:]
    func section(_ title: String, _ note: String) -> Int {
        notes[title] = note
        let box = stack(s, title, parent: light, "vertical", gap: "s", props: ["sizingH": "fill"])
        let head = stack(s, "Titolo", parent: box, "horizontal", gap: "s", props: ["crossAlign": "baseline"])
        s.text(title, parent: head, size: "headline", style: "SemiBold", color: "textPrimary")
        s.text(note, parent: head, size: "caption", color: "textSecondary")
        return box
    }

    // NidoButton ------------------------------------------------------------------------
    var button = Built()
    var buttonLabel: [Int: Int] = [:]
    do {
        let box = section("NidoButton", "primary · secondary · destructive · disabled")
        let kinds: [(String, String, String, String?, String)] = [
            ("primary", "accent", "accentText", nil, "Create VM"),
            ("secondary", "surfaceRaised", "textPrimary", "border", "Cancel"),
            ("destructive", "statusError", "accentText", nil, "Delete"),
            ("disabled", "surfaceRaised", "textSecondary", "border", "Next"),
        ]
        for (kind, fill, text, border, label) in kinds {
            let b = stack(s, "Tipo=\(kind)", parent: box, "horizontal", padding: ["xs", "m"],
                          props: ["crossAlign": "center", "mainAlign": "center", "sizingV": "fixed"])
            s.set(b, ["height": 28])
            s.bind(b, "fill", fill)
            s.bind(b, "cornerRadius", "Radius/s")
            if let border { s.stroke(b, border) }
            let t = s.text(label, parent: b, size: "body", style: "SemiBold", color: text)
            if kind == "disabled" { s.set(b, ["opacity": 0.5]) }
            s.makeComponent(b)
            button.variants.append((kind, b))
            buttonLabel[b] = t
        }
        button.set = s.combine(button.variants.map(\.1), name: "NidoButton", parent: box)
        sections.append(("NidoButton", button, notes["NidoButton"]!))
    }

    func addButton(_ kind: String, _ label: String, parent: Int) {
        let component = button.variants.first { $0.0 == kind }!.1
        let instance = s.instance(of: component, parent: parent)
        s.setText(s.copy(of: buttonLabel[component]!, in: instance, of: component), label)
    }

    // StatusBadge -----------------------------------------------------------------------
    var badge = Built()
    let states: [(String, String, String, Bool)] = [  // state, label, color, hollow dot
        ("stopped", "Stopped", "statusStopped", false),
        ("starting", "Starting", "accent", false),
        ("running", "Running", "statusRunning", false),
        ("paused", "Paused", "statusPaused", false),
        // Stopped with its state saved (`state.vzvmsave`): hollow, nothing runs.
        ("suspended", "Suspended", "statusPaused", true),
        ("error", "Error", "statusError", false),
        ("unreadable", "Unreadable", "statusError", true),
        // M3b: this app holds the VM's lock for a snapshot of the stopped VM or a clone.
        ("busy", "Busy", "accent", false),
        // M3b: a macOS VM being installed from an IPSW (no bundle in the library yet).
        ("installing", "Installing", "accent", true),
    ]
    do {
        let box = section("StatusBadge", "one color and one label for each VM state")
        for (state, label, color, hollow) in states {
            let b = stack(s, "Stato=\(state)", parent: box, "horizontal", gap: "xs", padding: ["0", "s"],
                          props: ["crossAlign": "center", "sizingV": "fixed"])
            s.set(b, ["height": 20])
            s.bind(b, "fill", "surfaceRaised")
            s.bind(b, "cornerRadius", "Radius/m")
            s.stroke(b, "border")
            let dot = s.ellipse(parent: b, size: 8)
            if hollow {
                s.set(dot, ["fills": [Any]()])
                s.stroke(dot, color, weight: 1.5, props: ["strokeAlign": "inside"])
            } else {
                s.bind(dot, "fill", color)
            }
            s.text(label, parent: b, size: "caption", style: "SemiBold", color: "textPrimary")
            s.makeComponent(b)
            badge.variants.append((state, b))
        }
        badge.set = s.combine(badge.variants.map(\.1), name: "StatusBadge", parent: box)
        sections.append(("StatusBadge", badge, notes["StatusBadge"]!))
    }

    // VMCard ----------------------------------------------------------------------------
    var card = Built()
    do {
        let box = section("VMCard", "library: one card per VM, actions by state")
        let details: [String: (String?, [(String, String)])] = [
            "stopped": (nil, [("primary", "Start"), ("secondary", "Settings")]),
            "starting": (nil, [("disabled", "Start"), ("secondary", "Stop")]),
            "running": (nil, [("primary", "Open"), ("secondary", "Stop")]),
            // Started with `nido start`: it runs in the Terminal's process, so the app can stop it but
            // cannot open it.
            "running-terminale": (nil, [("disabled", "Start"), ("secondary", "Stop")]),
            "paused": (nil, [("primary", "Resume"), ("secondary", "Stop")]),
            // Suspended: Riprendi starts it again from its saved state.
            "suspended": (nil, [("primary", "Resume"), ("secondary", "Settings")]),
            "error": ("Start failed: the VM’s disk can’t be read.",
                      [("primary", "Try Again"), ("secondary", "Details")]),
            "unreadable": ("config.json is damaged: the VM can’t be opened.",
                           [("secondary", "Show in Finder"), ("destructive", "Delete")]),
            // As LibraryModel.buttons for LiveState.busy: everything waits except Dettagli.
            "busy": (nil, [("disabled", "Start"), ("secondary", "Details")]),
            "installing": (nil, [("secondary", "Show"), ("secondary", "Cancel…")]),
        ]
        var cardStates = states.map(\.0)
        cardStates.insert("running-terminale", at: cardStates.firstIndex(of: "running")! + 1)
        for state in cardStates {
            let c = stack(s, "Stato=\(state)", parent: box, "vertical", gap: "m", padding: ["l"],
                          width: 320, props: ["sizingH": "fixed"])
            s.bind(c, "fill", "surface")
            s.bind(c, "cornerRadius", "Radius/m")
            s.stroke(c, "border")
            let top = stack(s, "Intestazione", parent: c, "horizontal", gap: "m",
                            props: ["crossAlign": "center", "sizingH": "fill"])
            let glyph = stack(s, "System", parent: top, "horizontal",
                              props: ["mainAlign": "center", "crossAlign": "center", "sizingH": "fixed",
                                      "sizingV": "fixed", "width": 40, "height": 40])
            s.set(glyph, ["width": 40, "height": 40])
            s.bind(glyph, "fill", "background")
            s.bind(glyph, "cornerRadius", "Radius/s")
            s.stroke(glyph, "border")
            s.text("D", parent: glyph, size: "headline", style: "Bold", color: "accent")
            let names = stack(s, "Name", parent: top, "vertical", gap: "xs", props: ["sizingH": "fill"])
            s.text("debian-13", parent: names, size: "headline", style: "SemiBold", color: "textPrimary")
            s.text("Debian 13 · arm64", parent: names, size: "caption", color: "textSecondary")
            if state == "running" {
                // M3c: the remote AI bridge of this VM is on (spec H), hidden unless a screen shows it.
                s.set(bridgePill(s, parent: names), ["visible": false])
            }
            if state == "running-terminale" {
                // The longer label goes under the name, where it has the width of the card.
                let b = s.instance(of: badge.variants.first { $0.0 == "running" }!.1, parent: names)
                s.setText(s.children(of: b)[1], "Running (Terminal)")
            } else {
                _ = s.instance(of: badge.variants.first { $0.0 == state }!.1, parent: top)
            }

            s.text("4 CPUs · 8 GiB of memory · 64 GiB disk", parent: c, size: "caption", color: "textSecondary")
            if state == "busy" {
                // NidoVMCard: the reason under the resources, secondary and semibold.
                s.text("Cloning in progress", parent: c, size: "caption", style: "SemiBold", color: "textSecondary",
                       props: ["sizingH": "fill", "textAutoResize": "height"])
            }
            if state == "installing" {
                // The progress of the installation, as in the wizard (percentage and time left).
                let progress = stack(s, "Avanzamento installazione", parent: c, "vertical", gap: "xs",
                                     props: ["sizingH": "fill"])
                s.text("Installing macOS · 42% · about 9 min", parent: progress, size: "caption",
                       style: "SemiBold", color: "textSecondary", props: ["features": ["tnum": true]])
                meter(s, parent: progress, fraction: 0.42, width: 288)
            }
            let (message, actions) = details[state]!
            if let message {
                s.text(message, parent: c, size: "caption", style: "SemiBold", color: "statusError",
                       props: ["sizingH": "fill", "textAutoResize": "height"])
            }
            let row = stack(s, "Azioni", parent: c, "horizontal", gap: "s", props: ["sizingH": "fill"])
            for (kind, label) in actions { addButton(kind, label, parent: row) }
            s.makeComponent(c)
            card.variants.append((state, c))
        }
        card.set = s.combine(card.variants.map(\.1), name: "VMCard", parent: box)
        sections.append(("VMCard", card, notes["VMCard"]!))
    }

    // OSTile ----------------------------------------------------------------------------
    var tile = Built()
    do {
        let box = section("OSTile", "system choice: normal · selected · disabled")
        let tiles: [(String, String, String, String)] = [
            ("normale", "U", "Ubuntu 24.04", "arm64 · 2.6 GiB"),
            ("selezionato", "D", "Debian 13", "arm64 · 1.2 GiB"),
            ("disattivato", "W", "Windows 11", "Coming soon"),
        ]
        for (state, letter, name, detail) in tiles {
            let t = stack(s, "Stato=\(state)", parent: box, "vertical", gap: "s", padding: ["l"], width: 168,
                          props: ["sizingH": "fixed", "crossAlign": "center"])
            s.bind(t, "fill", state == "selezionato" ? "surfaceRaised" : "surface")
            s.bind(t, "cornerRadius", "Radius/m")
            s.stroke(t, state == "selezionato" ? "accent" : "border", weight: state == "selezionato" ? 2 : 1)
            let glyph = stack(s, "System", parent: t, "horizontal",
                              props: ["mainAlign": "center", "crossAlign": "center", "sizingH": "fixed",
                                      "sizingV": "fixed"])
            s.set(glyph, ["width": 48, "height": 48])
            s.bind(glyph, "fill", state == "selezionato" ? "accent" : "background")
            s.bind(glyph, "cornerRadius", "Radius/m")
            s.text(letter, parent: glyph, size: "title", style: "Bold",
                   color: state == "selezionato" ? "accentText" : "textSecondary")
            s.text(name, parent: t, size: "body", style: "SemiBold", color: "textPrimary")
            s.text(detail, parent: t, size: "caption", color: "textSecondary")
            if state == "disattivato" { s.set(t, ["opacity": 0.5]) }
            s.makeComponent(t)
            tile.variants.append((state, t))
        }
        tile.set = s.combine(tile.variants.map(\.1), name: "OSTile", parent: box)
        sections.append(("OSTile", tile, notes["OSTile"]!))
    }

    // ResourceStepper -------------------------------------------------------------------
    var stepper = Built()
    do {
        let box = section("ResourceStepper", "VM resources: within the limits · out of range")
        let rows: [(String, String, String?)] = [
            ("normale", "8 GiB", nil),
            ("fuori limite", "16 GiB", "Over the limit: at most 12 GiB on this Mac."),
        ]
        for (state, value, warning) in rows {
            let r = stack(s, "Stato=\(state)", parent: box, "horizontal", gap: "m", padding: ["m", "l"],
                          width: 480, props: ["sizingH": "fixed", "crossAlign": "center"])
            s.bind(r, "fill", "surface")
            s.bind(r, "cornerRadius", "Radius/m")
            s.stroke(r, "border")
            let labels = stack(s, "Testo", parent: r, "vertical", gap: "xs", props: ["sizingH": "fill"])
            s.text("Memory", parent: labels, size: "body", style: "SemiBold", color: "textPrimary")
            s.text(warning ?? "Recommended: 4 GiB · at most 12 GiB", parent: labels, size: "caption",
                   style: warning == nil ? "Regular" : "SemiBold",
                   color: warning == nil ? "textSecondary" : "statusError",
                   props: ["sizingH": "fill", "textAutoResize": "height"])
            let field = stack(s, "Valore", parent: r, "horizontal", padding: ["0", "s"],
                              props: ["mainAlign": "max", "crossAlign": "center", "sizingH": "fixed",
                                      "sizingV": "fixed"])
            s.set(field, ["width": 72, "height": 24])
            s.bind(field, "fill", "surfaceRaised")
            s.bind(field, "cornerRadius", "Radius/s")
            s.stroke(field, warning == nil ? "border" : "statusError", weight: warning == nil ? 1 : 2)
            s.text(value, parent: field, size: "body", color: "textPrimary", props: ["features": ["tnum": true]])
            // One segmented control: shared outline and corner radius, a hairline between the halves.
            let arrows = stack(s, "Frecce", parent: r, "horizontal", props: ["crossAlign": "center", "clip": true])
            s.bind(arrows, "fill", "surfaceRaised")
            s.bind(arrows, "cornerRadius", "Radius/s")
            s.stroke(arrows, "border")
            for (index, (symbol, name)) in [("−", "Diminuisci"), ("+", "Aumenta")].enumerated() {
                let a = stack(s, name, parent: arrows, "horizontal",
                              props: ["mainAlign": "center", "crossAlign": "center", "sizingH": "fixed",
                                      "sizingV": "fixed"])
                s.set(a, ["width": 28, "height": 24])
                if index == 1 { s.stroke(a, "border", props: ["strokeSides": [0, 0, 0, 1]]) }
                s.text(symbol, parent: a, size: "body", style: "SemiBold", color: "textPrimary")
            }
            s.makeComponent(r)
            stepper.variants.append((state, r))
        }
        stepper.set = s.combine(stepper.variants.map(\.1), name: "ResourceStepper", parent: box)
        sections.append(("ResourceStepper", stepper, notes["ResourceStepper"]!))
    }

    // ToggleRow -------------------------------------------------------------------------
    var toggle = Built()
    do {
        let box = section("ToggleRow", "option with an explanation: on · off · locked while the VM is running")
        let rows: [(String, Bool, String)] = [
            ("attiva", true, "The Mac sets the VM’s clock at every start and after a pause."),
            ("disattivata", false, "The Mac sets the VM’s clock at every start and after a pause."),
            ("bloccata", true, "Can be changed only with the VM stopped."),
        ]
        for (state, on, explanation) in rows {
            let r = stack(s, "Stato=\(state)", parent: box, "horizontal", gap: "m", padding: ["m", "l"],
                          width: 480, props: ["sizingH": "fixed", "crossAlign": "center"])
            s.bind(r, "fill", "surface")
            s.bind(r, "cornerRadius", "Radius/m")
            s.stroke(r, "border")
            let labels = stack(s, "Testo", parent: r, "vertical", gap: "xs", props: ["sizingH": "fill"])
            s.text("Sync the clock with the Mac", parent: labels, size: "body", style: "SemiBold",
                   color: "textPrimary")
            s.text(explanation, parent: labels, size: "caption", color: "textSecondary",
                   props: ["sizingH": "fill", "textAutoResize": "height"])
            let track = stack(s, "Interruttore", parent: r, "horizontal", padding: ["0", "xs"],
                              props: ["mainAlign": on ? "max" : "min", "crossAlign": "center",
                                      "sizingH": "fixed", "sizingV": "fixed"])
            s.set(track, ["width": 40, "height": 24, "cornerRadius": 12])
            s.bind(track, "fill", on ? "accent" : "border")
            let knob = s.ellipse(parent: track, size: 16)
            s.bind(knob, "fill", on ? "accentText" : "textSecondary")
            if state == "bloccata" { s.set(track, ["opacity": 0.5]) }
            s.makeComponent(r)
            toggle.variants.append((state, r))
        }
        toggle.set = s.combine(toggle.variants.map(\.1), name: "ToggleRow", parent: box)
        sections.append(("ToggleRow", toggle, notes["ToggleRow"]!))
    }

    // ProgressPanel ---------------------------------------------------------------------
    var progress = Built()
    do {
        let box = section("ProgressPanel", "download · verification · creation · error")
        let phases: [(String, String, String, Double?)] = [
            ("download", "Downloading Debian 13", "cloud.debian.org · 0.4 GiB of 1.2 GiB · about 2 min", 0.34),
            ("verifica", "Verifying the image", "Verifying the SHA-512 checksum · 1.2 GiB", 0.8),
            ("creazione", "Creating debian-13", "Copying the disk (64 GiB) and preparing cloud-init", 0.6),
            ("errore", "Download failed", "The SHA-512 checksum doesn’t match: the downloaded file was deleted.", nil),
        ]
        for (phase, title, detail, fraction) in phases {
            let p = stack(s, "Fase=\(phase)", parent: box, "vertical", gap: "s", padding: ["l"], width: 480,
                          props: ["sizingH": "fixed"])
            s.bind(p, "fill", "surface")
            s.bind(p, "cornerRadius", "Radius/m")
            s.stroke(p, "border")
            s.text(title, parent: p, size: "headline", style: "SemiBold", color: "textPrimary")
            s.text(detail, parent: p, size: "caption", style: fraction == nil ? "SemiBold" : "Regular",
                   color: fraction == nil ? "statusError" : "textSecondary",
                   props: ["sizingH": "fill", "textAutoResize": "height"])
            if let fraction {
                let track = s.frame("Barra", parent: p, width: 448, height: 6, props: ["sizingH": "fill"])
                s.bind(track, "fill", "border")
                s.set(track, ["cornerRadius": 3])
                let bar = s.frame("Avanzamento", parent: track, width: (448 * fraction).rounded(), height: 6)
                s.bind(bar, "fill", "accent")
                s.set(bar, ["cornerRadius": 3])
            }
            let row = stack(s, "Azioni", parent: p, "horizontal", gap: "s",
                            props: ["sizingH": "fill", "mainAlign": "max"])
            if fraction == nil {
                addButton("secondary", "Cancel", parent: row)
                addButton("primary", "Try Again", parent: row)
            } else {
                addButton("secondary", "Cancel", parent: row)
            }
            s.makeComponent(p)
            progress.variants.append((phase, p))
        }
        progress.set = s.combine(progress.variants.map(\.1), name: "ProgressPanel", parent: box)
        sections.append(("ProgressPanel", progress, notes["ProgressPanel"]!))
    }

    // WizardStep ------------------------------------------------------------------------
    var wizard = Built()
    do {
        let box = section("WizardStep", "wizard container: normal · next disabled · error")
        let variants: [(String, String?, String)] = [
            ("normale", nil, "primary"),
            ("avanti disattivato", nil, "disabled"),
            ("errore", "Not enough disk space: 64 GiB needed, 41 GiB left on the Mac.", "disabled"),
        ]
        for (state, error, next) in variants {
            let w = stack(s, "Stato=\(state)", parent: box, "vertical", gap: "l", padding: ["xl"], width: 560,
                          props: ["sizingH": "fixed"])
            s.bind(w, "fill", "surface")
            s.bind(w, "cornerRadius", "Radius/l")
            s.stroke(w, "border")
            let steps = stack(s, "Passi", parent: w, "horizontal", gap: "s", props: ["crossAlign": "center"])
            for index in 0..<5 {
                let seg = s.frame("Passo \(index + 1)", parent: steps, width: 32, height: 4)
                s.set(seg, ["cornerRadius": 2])
                s.bind(seg, "fill", index <= 2 ? "accent" : "border")
            }
            s.text("Step 3 of 5", parent: steps, size: "caption", color: "textSecondary")
            let head = stack(s, "Testa", parent: w, "vertical", gap: "xs", props: ["sizingH": "fill"])
            s.text("Resources", parent: head, size: "title", style: "SemiBold", color: "textPrimary")
            s.text("Choose how much of the Mac’s CPU, memory and disk to give debian-13.", parent: head,
                   size: "body", color: "textSecondary", props: ["sizingH": "fill", "textAutoResize": "height"])
            let content = stack(s, "Contenuto", parent: w, "vertical", gap: "s", props: ["sizingH": "fill"])
            let memory = s.instance(of: stepper.variants[0].1, parent: content)
            s.set(memory, ["sizingH": "fill"])
            if let error {
                s.text(error, parent: w, size: "caption", style: "SemiBold", color: "statusError",
                       props: ["sizingH": "fill", "textAutoResize": "height"])
            }
            let foot = stack(s, "Navigazione", parent: w, "horizontal", gap: "s",
                             props: ["sizingH": "fill", "crossAlign": "center"])
            addButton("secondary", "Back", parent: foot)
            spacer(s, parent: foot)
            addButton("secondary", "Cancel", parent: foot)
            addButton(next, "Next", parent: foot)
            s.makeComponent(w)
            wizard.variants.append((state, w))
        }
        wizard.set = s.combine(wizard.variants.map(\.1), name: "WizardStep", parent: box)
        sections.append(("WizardStep", wizard, notes["WizardStep"]!))
    }

    // VMToolbar -------------------------------------------------------------------------
    var toolbar = Built()
    do {
        let box = section("VMToolbar", "VM window toolbar, by state")
        let bars: [(String, String, [(String, String)])] = [
            ("starting", "starting", [("disabled", "Pause"), ("secondary", "Stop")]),
            // As VMWindowModel.toolbarButtons, plus Snapshot (S09) where a snapshot can be taken.
            ("running", "running", [("secondary", "Pause"), ("secondary", "Suspend"), ("secondary", "Stop"),
                                    ("secondary", "Snapshots"), ("secondary", "Enter Full Screen")]),
            ("paused", "paused", [("primary", "Resume"), ("secondary", "Stop")]),
            ("stopped", "stopped", [("primary", "Start"), ("secondary", "Snapshots"), ("secondary", "Settings")]),
            // Stopped with its state saved: Riprendi starts it again from there.
            ("suspended", "suspended", [("primary", "Resume"), ("secondary", "Snapshots"),
                                        ("secondary", "Settings")]),
            ("error", "error", [("primary", "Try Again"), ("secondary", "Details")]),
            // M3b: a running macOS VM, with the "Accesso da terminale" panel.
            ("running-macos", "running", [("secondary", "Pause"), ("secondary", "Suspend"),
                                          ("secondary", "Stop"), ("secondary", "Snapshots"),
                                          ("secondary", "Terminal Access"),
                                          ("secondary", "Enter Full Screen")]),
        ]
        for (state, badgeState, actions) in bars {
            let t = stack(s, "Stato=\(state)", parent: box, "horizontal", gap: "s", padding: ["s", "l"],
                          width: 1100, props: ["sizingH": "fixed", "crossAlign": "center"])
            s.bind(t, "fill", "surface")
            s.stroke(t, "border", props: ["strokeSides": [0, 0, 1, 0]])
            s.text("debian-13", parent: t, size: "headline", style: "SemiBold", color: "textPrimary")
            _ = s.instance(of: badge.variants.first { $0.0 == badgeState }!.1, parent: t)
            spacer(s, parent: t)
            for (kind, label) in actions { addButton(kind, label, parent: t) }
            s.makeComponent(t)
            toolbar.variants.append((state, t))
        }
        toolbar.set = s.combine(toolbar.variants.map(\.1), name: "VMToolbar", parent: box)
        s.set(toolbar.set, ["layout": "vertical"])
        sections.append(("VMToolbar", toolbar, notes["VMToolbar"]!))
    }

    // EmptyState ------------------------------------------------------------------------
    var empty = Built()
    do {
        let box = section("EmptyState", "empty library · no snapshots (S09) · stopped or suspended VM (S07)")
        let e = stack(s, "EmptyState", parent: box, "vertical", gap: "m", padding: ["xxl"], width: 480,
                      props: ["sizingH": "fixed", "crossAlign": "center"])
        s.bind(e, "fill", "surface")
        s.bind(e, "cornerRadius", "Radius/l")
        let nest = stack(s, "Nido", parent: e, "horizontal",
                         props: ["mainAlign": "center", "crossAlign": "center", "sizingH": "fixed", "sizingV": "fixed"])
        s.set(nest, ["width": 64, "height": 64, "cornerRadius": 32])
        s.bind(nest, "fill", "background")
        s.stroke(nest, "border", weight: 2)
        let egg = s.ellipse(parent: nest, size: 24)
        s.bind(egg, "fill", "accent")
        s.text("The nest is empty", parent: e, size: "title", style: "SemiBold", color: "textPrimary")
        s.text("Create your first virtual machine: Nido downloads Debian 13, verifies the image and sets up the VM in a few minutes.",
               parent: e, size: "body", color: "textSecondary",
               props: ["sizingH": "fill", "textAutoResize": "height", "textAlign": "center"])
        addButton("primary", "Create VM", parent: e)
        s.makeComponent(e)
        empty.variants.append(("libreria", e))
        empty.set = e
        sections.append(("EmptyState", empty, notes["EmptyState"]!))
    }

    // ConfirmSheet ----------------------------------------------------------------------
    var sheet = Built()
    do {
        let box = section("ConfirmSheet", "confirmations: download · deletion")
        let sheets: [(String, String, String, String, String)] = [
            ("download", "Download Debian 13?",
             "Nido will download the image from cloud.debian.org (1.2 GiB) and verify its SHA-512 checksum before using it.",
             "primary", "Download"),
            ("eliminazione", "Delete debian-13?",
             "The VM and its disk (64 GiB) will be deleted from this Mac. This can’t be undone.",
             "destructive", "Delete"),
        ]
        for (kind, title, message, actionKind, action) in sheets {
            let c = stack(s, "Tipo=\(kind)", parent: box, "vertical", gap: "m", padding: ["xl"], width: 440,
                          props: ["sizingH": "fixed",
                                  "effects": [["type": "dropShadow", "color": "#0000002E", "offsetX": 0,
                                               "offsetY": 8, "radius": 24, "spread": 0]]])
            s.bind(c, "fill", "surfaceRaised")
            s.bind(c, "cornerRadius", "Radius/l")
            s.stroke(c, "border")
            s.text(title, parent: c, size: "headline", style: "SemiBold", color: "textPrimary")
            s.text(message, parent: c, size: "body", color: "textSecondary",
                   props: ["sizingH": "fill", "textAutoResize": "height"])
            let row = stack(s, "Azioni", parent: c, "horizontal", gap: "s",
                            props: ["sizingH": "fill", "mainAlign": "max"])
            addButton("secondary", "Cancel", parent: row)
            addButton(actionKind, action, parent: row)
            s.makeComponent(c)
            sheet.variants.append((kind, c))
        }
        sheet.set = s.combine(sheet.variants.map(\.1), name: "ConfirmSheet", parent: box)
        sections.append(("ConfirmSheet", sheet, notes["ConfirmSheet"]!))
    }

    // SnapshotRow -----------------------------------------------------------------------
    var snapshotRow = Built()
    do {
        let box = section("SnapshotRow", "VM snapshot: normal · current (the current state) · being created")
        for state in ["normale", "corrente", "in creazione"] {
            let r = stack(s, "Stato=\(state)", parent: box, "horizontal", gap: "m", padding: ["m", "l"],
                          width: 640, props: ["sizingH": "fixed", "crossAlign": "center"])
            s.bind(r, "fill", "surface")
            s.bind(r, "cornerRadius", "Radius/m")
            s.stroke(r, state == "corrente" ? "accent" : "border", weight: state == "corrente" ? 2 : 1)
            let labels = stack(s, "Testo", parent: r, "vertical", gap: "xs", props: ["sizingH": "fill"])
            s.text(state == "corrente" ? "Current state" : "before-update", parent: labels, size: "body",
                   style: "SemiBold", color: "textPrimary")
            // Fixed height: rows with and without the "con stato salvato" pill line up.
            let details = stack(s, "Details", parent: labels, "horizontal", gap: "s",
                                props: ["crossAlign": "center", "sizingV": "fixed"])
            s.set(details, ["height": 20])
            switch state {
            case "corrente":
                _ = s.instance(of: badge.variants.first { $0.0 == "stopped" }!.1, parent: details)
                s.text("Changes since the last snapshot exist only here.", parent: details, size: "caption",
                       color: "textSecondary")
            case "in creazione":
                s.text("Creating…", parent: details, size: "caption", color: "textSecondary")
            default:
                s.text("Oct 24, 2026, 10:42 AM", parent: details, size: "caption", color: "textSecondary",
                       props: ["features": ["tnum": true]])
                // The snapshot holds the memory too (taken while the VM ran): it restores as suspended.
                let pill = stack(s, "Stato salvato", parent: details, "horizontal", padding: ["0", "s"],
                                 props: ["crossAlign": "center", "sizingV": "fixed"])
                s.set(pill, ["height": 18])
                s.bind(pill, "fill", "background")
                s.bind(pill, "cornerRadius", "Radius/m")
                s.stroke(pill, "border")
                s.text("with saved state", parent: pill, size: "caption", style: "SemiBold", color: "accent")
            }
            let row = stack(s, "Azioni", parent: r, "horizontal", gap: "s", props: ["crossAlign": "center"])
            switch state {
            case "corrente":
                addButton("primary", "Create Snapshot…", parent: row)
            case "in creazione":
                addButton("disabled", "Restore", parent: row)
                addButton("disabled", "Delete", parent: row)
            default:
                addButton("secondary", "Restore", parent: row)
                addButton("secondary", "Delete", parent: row)
            }
            s.makeComponent(r)
            snapshotRow.variants.append((state, r))
        }
        snapshotRow.set = s.combine(snapshotRow.variants.map(\.1), name: "SnapshotRow", parent: box)
        s.set(snapshotRow.set, ["layout": "vertical"])
        sections.append(("SnapshotRow", snapshotRow, notes["SnapshotRow"]!))
    }

    // Dark board: one instance of every variant, same sections -------------------------
    let dark = s.frame("Componenti · Scuro", parent: nil, x: 1240, y: 0, width: 1180, height: 100,
                       props: ["layout": "vertical", "sizingV": "hug"])
    boardStyle(s, dark, mode: "Scuro")
    s.text("Componenti di Nido · Scuro", parent: dark, size: "title", style: "SemiBold", color: "textPrimary")
    for (title, built, note) in sections {
        let box = stack(s, title, parent: dark, "vertical", gap: "s", props: ["sizingH": "fill"])
        let head = stack(s, "Titolo", parent: box, "horizontal", gap: "s", props: ["crossAlign": "baseline"])
        s.text(title, parent: head, size: "headline", style: "SemiBold", color: "textPrimary")
        s.text(note, parent: head, size: "caption", color: "textSecondary")
        let vertical = title == "VMToolbar" || title == "SnapshotRow"
        let row = stack(s, "Varianti", parent: box, vertical ? "vertical" : "horizontal",
                        props: ["wrap": !vertical, "gap": 16, "crossGap": 16, "sizingH": "fill"])
        for (_, variant) in built.variants { _ = s.instance(of: variant, parent: row) }
    }
    return s
}
