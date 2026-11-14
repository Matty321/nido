// SPDX-License-Identifier: Apache-2.0
//
// The script 03-screens.json: the components only the screens need (page Components), the
// screens S01–S11 (with the M3c and M3b additions of ScreensAI.swift and ScreensMac.swift) in both modes (page Screens) and the click-through prototype of
// F01, F03 and F04 (page Prototype, see Prototype.swift). Every screen is a 1100×720 window built
// from component instances; colours come from the variables, the mode from `variable.setMode`.

import Foundation

let windowWidth = 1100.0
let windowHeight = 720.0

/// Shadows: a window on the desk, a sheet or a floating panel over a window.
let windowShadow: [JSON] = [["type": "dropShadow", "color": "#00000038", "offset": [0, 12], "radius": 32,
                             "spread": 0]]
let sheetShadow: [JSON] = [["type": "dropShadow", "color": "#00000040", "offset": [0, 10], "radius": 28,
                            "spread": 0]]

/// The scrim behind a sheet: a colour variable of its own, created by this script after the
/// tokens of 01 (so their ids do not move), black at 20 % in light mode and 55 % in dark mode,
/// where 20 % is not visible on the dark background.
let scrimValues = ["Chiaro": "#00000033", "Scuro": "#0000008C"]
let scrimVariableID = "VariableID:\(variableIDs.count + 1)"

/// The guest's console as Virtualization.framework shows it: the VM's own framebuffer, not app
/// UI, so it keeps the same colours in both modes.
let consoleFill = "#101312"
let consoleText = "#CDD2CB"
let consoleFont = "Liberation Mono"

/// Ids a prototype needs from a screen: the window and the controls that lead somewhere.
typealias ScreenRefs = [String: Int]

// MARK: - Building blocks

/// A NidoButton instance of the given kind with its own label.
@discardableResult
func button(_ s: Script, _ kind: String, _ label: String, parent: Int) -> Int {
    let instance = s.instance(of: s.variant("NidoButton", "Tipo=\(kind)"), parent: parent)
    s.setText(s.children(of: instance)[0], label)
    return instance
}

/// Changes the kind of a NidoButton instance (its label must be set again).
func switchButton(_ s: Script, _ instance: Int, to kind: String, label: String) {
    s.switchVariant(instance, property: "Tipo", value: kind, component: s.variant("NidoButton", "Tipo=\(kind)"))
    s.setText(s.children(of: instance)[0], label)
}

/// A window: fixed 1100×720, clipped, with its own colour mode.
func window(_ s: Script, _ name: String, parent: Int?, x: Double, y: Double, mode: String,
            fullScreen: Bool = false) -> Int {
    let w = s.frame(name, parent: parent, x: x, y: y, width: windowWidth, height: windowHeight,
                    props: ["layout": "vertical", "clip": true, "sizingH": "fixed", "sizingV": "fixed",
                            "effects": fullScreen ? [JSON]() : windowShadow])
    s.bind(w, "fill", "background")
    if !fullScreen {
        s.bind(w, "cornerRadius", "Radius/l")
        s.stroke(w, "border")
    }
    s.step("variable.setMode", ["ids": [w], "collection": "Color", "mode": mode])
    return w
}

/// Close, minimise and zoom, coloured with the status tokens.
func trafficLights(_ s: Script, parent: Int) {
    let row = stack(s, "Pulsanti della finestra", parent: parent, "horizontal", gap: "s",
                    props: ["crossAlign": "center"])
    for token in ["statusError", "statusPaused", "statusRunning"] {
        let dot = s.ellipse(parent: row, size: 12)
        s.bind(dot, "fill", token)
    }
}

/// The unified title bar and toolbar of a window (52 pt): traffic lights, title, then the controls.
func toolbar(_ s: Script, window: Int, title: String, subtitle: String?) -> Int {
    let bar = stack(s, "Barra degli strumenti", parent: window, "horizontal", gap: "l", padding: ["0", "l"],
                    props: ["sizingH": "fill", "sizingV": "fixed", "crossAlign": "center"])
    s.set(bar, ["height": 52])
    s.bind(bar, "fill", "surface")
    s.stroke(bar, "border", props: ["strokeSides": [0, 0, 1, 0]])
    trafficLights(s, parent: bar)
    let titles = stack(s, "Titolo", parent: bar, "vertical")
    s.text(title, parent: titles, size: "headline", style: "SemiBold", color: "textPrimary")
    if let subtitle { s.text(subtitle, parent: titles, size: "caption", color: "textSecondary") }
    spacer(s, parent: bar)
    return bar
}

/// The library's search field.
func searchField(_ s: Script, parent: Int) {
    let field = stack(s, "Cerca", parent: parent, "horizontal", padding: ["0", "s"],
                      props: ["crossAlign": "center", "sizingH": "fixed", "sizingV": "fixed"])
    s.set(field, ["width": 200, "height": 28])
    s.bind(field, "fill", "surfaceRaised")
    s.bind(field, "cornerRadius", "Radius/s")
    s.stroke(field, "border")
    s.text("Search VMs", parent: field, size: "body", color: "textSecondary")
}

/// A frame that fills the rest of a window.
func fillArea(_ s: Script, _ name: String, parent: Int, _ direction: String = "vertical", gap: String? = nil,
              padding: [String]? = nil, props: JSON = [:]) -> Int {
    var p: JSON = ["sizingH": "fill", "sizingV": "fill"]
    p.merge(props) { _, new in new }
    return stack(s, name, parent: parent, direction, gap: gap, padding: padding, props: p)
}

// MARK: - Components only the screens use (page Components)

/// Builds InfoRow, PickerRow and the system choice of the wizard on their own board, and turns
/// the content of WizardStep into a slot so each wizard page can hold its own controls.
func screenComponents(_ s: Script) {
    s.selectPage(s.firstLayer(named: "Components"))
    let board = s.frame("Componenti delle schermate · Chiaro", parent: nil, x: 2480, y: 0, width: 1180, height: 100,
                        props: ["layout": "vertical", "sizingV": "hug"])
    boardStyle(s, board, mode: "Chiaro")
    s.text("Componenti delle schermate · Chiaro", parent: board, size: "title", style: "SemiBold",
           color: "textPrimary")
    func section(_ title: String, _ note: String) -> Int {
        let box = stack(s, title, parent: board, "vertical", gap: "s", props: ["sizingH": "fill"])
        let head = stack(s, "Titolo", parent: box, "horizontal", gap: "s", props: ["crossAlign": "baseline"])
        s.text(title, parent: head, size: "headline", style: "SemiBold", color: "textPrimary")
        s.text(note, parent: head, size: "caption", color: "textSecondary")
        return box
    }
    /// The row look shared with ResourceStepper and ToggleRow.
    func row(_ name: String, parent: Int) -> Int {
        let r = stack(s, name, parent: parent, "horizontal", gap: "m", padding: ["m", "l"], width: 512,
                      props: ["sizingH": "fixed", "crossAlign": "center"])
        s.bind(r, "fill", "surface")
        s.bind(r, "cornerRadius", "Radius/m")
        s.stroke(r, "border")
        return r
    }

    // InfoRow: a read-only value, with or without a note.
    do {
        let box = section("InfoRow", "read-only value: plain · with a note")
        var variants: [Int] = []
        for kind in ["semplice", "con nota"] {
            let r = row("Tipo=\(kind)", parent: box)
            let labels = stack(s, "Testo", parent: r, "vertical", gap: "xs", props: ["sizingH": "fill"])
            s.text("Etichetta", parent: labels, size: "body", style: "SemiBold", color: "textPrimary")
            if kind == "con nota" {
                s.text("Nota", parent: labels, size: "caption", color: "textSecondary",
                       props: ["sizingH": "fill", "textAutoResize": "height"])
            }
            s.text("Valore", parent: r, size: "body", color: "textSecondary")
            s.makeComponent(r)
            variants.append(r)
        }
        s.combine(variants, name: "InfoRow", parent: box)
    }

    // ColorRow: a VM's tint, chosen among the eight (Settings › General, the wizard's summary).
    do {
        let box = section("ColorRow", "a VM’s color: eight tints, the chosen one ringed")
        let r = row("ColorRow", parent: box)
        let labels = stack(s, "Testo", parent: r, "vertical", gap: "xs", props: ["sizingH": "fill"])
        s.text("Color", parent: labels, size: "body", style: "SemiBold", color: "textPrimary")
        s.text("Tells this VM apart in the library.", parent: labels, size: "caption", color: "textSecondary",
               props: ["sizingH": "fill", "textAutoResize": "height"])
        let swatches = stack(s, "Colori", parent: r, "horizontal", gap: "xs", props: ["crossAlign": "center"])
        for tint in vmTints {
            let ring = stack(s, "Colore=\(tint)", parent: swatches, "horizontal",
                             props: ["mainAlign": "center", "crossAlign": "center", "sizingH": "fixed", "sizingV": "fixed"])
            s.set(ring, ["width": 24, "height": 24, "cornerRadius": 12])
            s.stroke(ring, tint == "Sea" ? "accent" : "surface", weight: 2)
            let dot = s.ellipse(parent: ring, size: 16)
            s.bind(dot, "fill", "vm\(tint)")
        }
        s.makeComponent(r)
    }

    // PickerRow: a file or folder with its action.
    do {
        let box = section("PickerRow", "chosen file or folder, with its action")
        let r = row("PickerRow", parent: box)
        let labels = stack(s, "Testo", parent: r, "vertical", gap: "xs", props: ["sizingH": "fill"])
        s.text("Etichetta", parent: labels, size: "body", style: "SemiBold", color: "textPrimary")
        s.text("Percorso", parent: labels, size: "caption", color: "textSecondary",
               props: ["sizingH": "fill", "textAutoResize": "height"])
        button(s, "secondary", "Choose…", parent: r)
        s.makeComponent(r)
    }

    // SystemChoice: the OS tiles of S02 with the source of the image; M3b adds macOS (from an IPSW).
    do {
        let box = section("SystemChoice", "system choice in the wizard: Debian · macOS")
        let captions = [
            "debian": "Official Debian cloud image from cloud.debian.org, verified with SHA-512 before use. "
                + "Windows is coming in a future version.",
            "macos": "macOS installs from an IPSW file you download from Apple’s developer site, betas included: "
                + "Nido only reads it. Installing takes 10–20 minutes; you complete macOS "
                + "Setup Assistant in the VM’s window.",
        ]
        var variants: [Int] = []
        for selection in ["debian", "macos"] {
            let choice = stack(s, "Selezione=\(selection)", parent: box, "vertical", gap: "m", width: 512,
                               props: ["sizingH": "fixed"])
            let tiles = stack(s, "Sistemi", parent: choice, "horizontal", gap: "l", props: ["sizingH": "fill"])
            let mac = selection == "macos"
            let debian = s.instance(of: s.variant("OSTile", mac ? "Stato=normale" : "Stato=selezionato"), parent: tiles)
            if mac {
                markLetter(s, in: debian, nil)
                s.setText(s.find("Ubuntu 24.04", in: debian), "Debian 13")
                s.setText(s.find("arm64 · 2.6 GiB", in: debian), "arm64 · 1.2 GiB")
            }
            let macTile = s.instance(of: s.variant("OSTile", mac ? "Stato=selezionato" : "Stato=normale"), parent: tiles)
            markLetter(s, in: macTile, "M")
            s.setText(s.find(mac ? "Debian 13" : "Ubuntu 24.04", in: macTile), "macOS")
            s.setText(s.find(mac ? "arm64 · 1.2 GiB" : "arm64 · 2.6 GiB", in: macTile), "from an IPSW file")
            _ = s.instance(of: s.variant("OSTile", "Stato=disattivato"), parent: tiles)
            for tile in s.children(of: tiles) { s.set(tile, ["width": 160]) }
            s.text(captions[selection]!, parent: choice, size: "caption", color: "textSecondary",
                   props: ["sizingH": "fill", "textAutoResize": "height"])
            s.makeComponent(choice)
            variants.append(choice)
        }
        s.combine(variants, name: "SystemChoice", parent: box)
    }

    // WizardStep: the content area of the default variant becomes a slot (a slot property belongs
    // to the whole set, so one variant carries it; the screens switch the Avanti button instead).
    s.makeSlot(s.find("Contenuto", in: s.variant("WizardStep", "Stato=normale")), name: "Contenuto")

    // M3c (ScreensAI.swift): notices, provisioning steps, profiles, templates.
    aiScreenComponents(s, board: board)
    // M3b (ScreensMac.swift): the text field row of the macOS user name.
    macScreenComponents(s, board: board)
}

// MARK: - Library (S01)

/// The library window: empty, or with one VM in every state.
func libraryWindow(_ s: Script, _ name: String, parent: Int?, x: Double = 0, y: Double = 0, mode: String,
                   withVMs: Bool, behindSheet: Bool = false) -> ScreenRefs {
    let w = window(s, name, parent: parent, x: x, y: y, mode: mode)
    let bar = toolbar(s, window: w, title: "Library",
                      subtitle: withVMs ? "8 virtual machines · 2 running" : "No virtual machines")
    searchField(s, parent: bar)
    let new = button(s, "secondary", "New VM", parent: bar)
    var refs: ScreenRefs = ["window": w, "nuova": new]

    if !withVMs {
        let content = fillArea(s, "Contenuto", parent: w, padding: ["xl"],
                               props: ["mainAlign": "center", "crossAlign": "center"])
        let empty = s.instance(of: s.firstLayerComponent("EmptyState"), parent: content)
        refs["crea"] = s.parent(of: s.find("Create VM", in: empty))
        // Behind a sheet the empty state would peek out under it: the window shows only its frame.
        if behindSheet { s.set(empty, ["visible": false]) }
        return refs
    }

    let content = fillArea(s, "Contenuto", parent: w, padding: ["xl"])
    let grid = stack(s, "Griglia", parent: content, "horizontal", gap: "l",
                     props: ["wrap": true, "crossGap": 16, "sizingH": "fill"])
    func card(_ state: String, _ vm: String, _ caption: String) -> Int {
        let c = s.instance(of: s.variant("VMCard", "Stato=\(state)"), parent: grid)
        // Three columns fill the content width: (1100 − 2 × 24 − 2 × 16) / 3 = 340.
        s.set(c, ["width": 340])
        s.setText(s.find("debian-13", in: c), vm)
        s.setText(s.find("4 CPUs · 8 GiB of memory · 64 GiB disk", in: c), caption)
        tintMark(s, in: c, tint: designTint(for: vm))
        return c
    }
    // In the app's order: bundles sorted by name (VMBundle.list), as ScreenshotTests creates them.
    // Suspended with its state saved: VMCard "suspended" (Riprendi, Impostazioni).
    _ = card("suspended", "archivio", "2 CPUs · 4 GiB of memory · 32 GiB disk")
    // Started with `nido start`: VMCard "running-terminale" (Avvia disabled, Arresta active).
    _ = card("running-terminale", "ci-runner", "2 CPUs · 4 GiB of memory · 32 GiB disk")
    let stopped = card("stopped", "debian-13", "4 CPUs · 8 GiB of memory · 64 GiB disk")
    refs["avvia"] = s.children(of: s.find("Azioni", in: stopped))[0]
    _ = card("starting", "dev-box", "4 CPUs · 8 GiB of memory · 128 GiB disk")
    _ = card("paused", "sandbox", "2 CPUs · 2 GiB of memory · 32 GiB disk")
    _ = card("error", "test-arm", "4 CPUs · 8 GiB of memory · 64 GiB disk")
    let unreadable = card("unreadable", "vecchia-vm", "CPU, memory and disk unknown")
    s.setText(s.find("Debian 13 · arm64", in: unreadable), "Unknown system")
    markLetter(s, in: unreadable, "?")
    let running = card("running", "web-staging", "2 CPUs · 4 GiB of memory · 32 GiB disk")
    refs["apri"] = s.children(of: s.find("Azioni", in: running))[0]
    return refs
}

// MARK: - Sheets

/// The dimmed scrim over a whole window, below a sheet added after it.
func addScrim(_ s: Script, window w: Int) {
    let scrim = s.freeFrame("Velo", parent: w, x: 0, y: 0, width: windowWidth, height: windowHeight,
                            props: ["fills": ["#000000"]])
    s.step("variable.bind", ["ids": [scrim], "field": "fill", "variable": scrimVariableID])
    s.set(scrim, ["absolute": true, "x": 0, "y": 0])
}

/// Where a 440-wide sheet sits on a window, with its shadow.
func placeSheet(_ s: Script, _ sheet: Int) {
    s.set(sheet, ["absolute": true, "x": (windowWidth - 440) / 2, "y": 64, "effects": sheetShadow])
}

/// A ConfirmSheet instance (Tipo=download for a primary action, eliminazione for a destructive
/// one) over a window, with its own texts. Returns the Annulla and action buttons.
func confirmSheet(_ s: Script, window w: Int, kind: String, title: String, message: String,
                  action: String) -> (cancel: Int, action: Int) {
    addScrim(s, window: w)
    let sheet = s.instance(of: s.variant("ConfirmSheet", "Tipo=\(kind)"), parent: w)
    placeSheet(s, sheet)
    let texts = s.children(of: sheet)
    s.setText(texts[0], title)
    s.setText(texts[1], message)
    let buttons = s.children(of: texts[2])
    s.setText(s.children(of: buttons[1])[0], action)
    return (buttons[0], buttons[1])
}

/// A sheet with a form (title, message, then rows the caller adds), styled as ConfirmSheet.
func formSheet(_ s: Script, window w: Int, title: String, message: String) -> Int {
    addScrim(s, window: w)
    let sheet = stack(s, "Foglio", parent: w, "vertical", gap: "m", padding: ["xl"], width: 440,
                      props: ["sizingH": "fixed"])
    placeSheet(s, sheet)
    s.bind(sheet, "fill", "surfaceRaised")
    s.bind(sheet, "cornerRadius", "Radius/l")
    s.stroke(sheet, "border")
    s.text(title, parent: sheet, size: "headline", style: "SemiBold", color: "textPrimary")
    s.text(message, parent: sheet, size: "body", color: "textSecondary",
           props: ["sizingH": "fill", "textAutoResize": "height"])
    return sheet
}

/// The Annulla / action row at the bottom of a sheet.
@discardableResult
func sheetActions(_ s: Script, parent: Int, action: String, kind: String = "primary",
                  disabled: Bool = false) -> (cancel: Int, action: Int) {
    let row = stack(s, "Azioni", parent: parent, "horizontal", gap: "s",
                    props: ["sizingH": "fill", "mainAlign": "max"])
    let cancel = button(s, disabled ? "disabled" : "secondary", "Cancel", parent: row)
    let confirm = button(s, disabled ? "disabled" : kind, action, parent: row)
    return (cancel, confirm)
}

/// An indeterminate progress bar (a segment on a track), as NidoIndeterminateBar draws it.
func indeterminateBar(_ s: Script, parent: Int, width: Double) {
    let track = s.freeFrame("Barra", parent: parent, x: 0, y: 0, width: width, height: 6)
    s.bind(track, "fill", "border")
    s.set(track, ["cornerRadius": 3, "clip": true])
    let bar = s.freeFrame("Avanzamento", parent: track, x: (width * 0.3).rounded(), y: 0,
                          width: (width * 0.3).rounded(), height: 6)
    s.bind(bar, "fill", "accent")
    s.set(bar, ["cornerRadius": 3])
}

// MARK: - Wizard (S02–S06)

/// The library behind a dimmed scrim with the WizardStep sheet on top. `step` is 1…5; with
/// `nextEnabled` false the Avanti button is disabled (as in the WizardStep "avanti disattivato").
func wizardWindow(_ s: Script, _ name: String, parent: Int?, x: Double = 0, y: Double = 0, mode: String,
                  nextEnabled: Bool = true, step: Int, total: Int = 5, title: String, description: String,
                  next: String = "Next") -> (refs: ScreenRefs, slot: Int) {
    var refs = libraryWindow(s, name, parent: parent, x: x, y: y, mode: mode, withVMs: false, behindSheet: true)
    let w = refs["window"]!
    addScrim(s, window: w)
    let sheet = s.instance(of: s.variant("WizardStep", "Stato=normale"), parent: w)
    s.set(sheet, ["absolute": true, "x": (windowWidth - 560) / 2, "y": 64, "effects": sheetShadow])

    let steps = s.children(of: s.find("Passi", in: sheet))
    for (index, segment) in steps.prefix(5).enumerated() {
        s.bind(segment, "fill", index < step ? "accent" : "border")
        // A shorter path (from a template) shows only its own steps.
        if index >= total { s.set(segment, ["visible": false]) }
    }
    s.setText(steps[5], "Step \(step) of \(total)")
    s.setText(s.find("Resources", in: sheet), title)
    s.setText(s.find("Choose how much of the Mac’s CPU, memory and disk to give debian-13.", in: sheet), description)

    let nav = s.children(of: s.find("Navigazione", in: sheet))  // Indietro, spacer, Annulla, Avanti
    if step == 1 { s.set(nav[0], ["visible": false]) }
    if nextEnabled {
        s.setText(s.children(of: nav[3])[0], next)
    } else {
        switchButton(s, nav[3], to: "disabled", label: next)
    }
    refs["indietro"] = nav[0]
    refs["annulla"] = nav[2]
    refs["avanti"] = nav[3]
    return (refs, s.find("Contenuto", in: sheet))
}

/// A read-only row in a slot or a form.
@discardableResult
func infoRow(_ s: Script, parent: Int, _ label: String, _ value: String, note: String? = nil,
             inSlot: Bool = true, replace: Bool = false) -> Int {
    let component = s.variant("InfoRow", note == nil ? "Tipo=semplice" : "Tipo=con nota")
    let r = inSlot ? s.slotInsert(parent, component: component, replace: replace)
        : s.instance(of: component, parent: parent)
    s.setText(s.find("Etichetta", in: r), label)
    s.setText(s.find("Valore", in: r), value)
    if let note { s.setText(s.find("Nota", in: r), note) }
    s.set(r, ["sizingH": "fill"])
    return r
}

/// A ProgressPanel in the wizard: full width, its own buttons hidden (the wizard has them).
@discardableResult
func progressPanel(_ s: Script, slot: Int, phase: String, title: String, detail: String, fraction: Double?,
                   inSlot: Bool = true, keepActions: Bool = false, width: Double = 480, replace: Bool = true) -> Int {
    let component = s.variant("ProgressPanel", "Fase=\(phase)")
    let p = inSlot ? s.slotInsert(slot, component: component, replace: replace)
        : s.instance(of: component, parent: slot)
    s.set(p, ["sizingH": "fill"])
    if !keepActions { s.set(s.find("Azioni", in: p), ["visible": false]) }
    let defaults: [String: (String, String)] = [
        "download": ("Downloading Debian 13", "cloud.debian.org · 0.4 GiB of 1.2 GiB · about 2 min"),
        "verifica": ("Verifying the image", "Verifying the SHA-512 checksum · 1.2 GiB"),
        "creazione": ("Creating debian-13", "Copying the disk (64 GiB) and preparing cloud-init"),
        "errore": ("Download failed", "The SHA-512 checksum doesn’t match: the downloaded file was deleted."),
    ]
    let (oldTitle, oldDetail) = defaults[phase]!
    s.setText(s.find(oldTitle, in: p), title)
    s.setText(s.find(oldDetail, in: p), detail)
    if let fraction {
        // The track is the panel width (512 in the wizard) minus its padding (2 × 16).
        s.set(s.find("Avanzamento", in: p), ["width": (width * fraction).rounded()])
    }
    return p
}

/// A ResourceStepper in the wizard or a form.
@discardableResult
func stepperRow(_ s: Script, parent: Int, state: String = "normale", label: String, detail: String, value: String,
                inSlot: Bool = true, replace: Bool = false) -> Int {
    let component = s.variant("ResourceStepper", "Stato=\(state)")
    let r = inSlot ? s.slotInsert(parent, component: component, replace: replace)
        : s.instance(of: component, parent: parent)
    s.set(r, ["sizingH": "fill"])
    s.setText(s.find("Memory", in: r), label)
    let oldDetail = state == "normale" ? "Recommended: 4 GiB · at most 12 GiB" : "Over the limit: at most 12 GiB on this Mac."
    s.setText(s.find(oldDetail, in: r), detail)
    s.setText(s.find(state == "normale" ? "8 GiB" : "16 GiB", in: r), value)
    return r
}

let resourcesDescription = "Choose how much of the Mac’s CPU, memory and disk to give debian-13."

/// S02: the system and, since M3c, the profile (Debian Base, Debian AI Starter) or a template.
/// `profile`: base, ai, modello.
func s02System(_ s: Script, _ name: String, parent: Int?, x: Double = 0, y: Double = 0, mode: String,
               profile: String = "base") -> ScreenRefs {
    let fromTemplate = profile == "modello"
    let (wizardRefs, slot) = wizardWindow(s, name, parent: parent, x: x, y: y, mode: mode, step: 1,
                                          total: fromTemplate ? 2 : 5, title: "System",
                                          description: fromTemplate
                                              ? "Choose the template for the new virtual machine."
                                              : "Choose the system and profile of the new virtual machine.")
    var refs = wizardRefs
    // The system first (what runs), then the profile (what is prepared); a template replaces both.
    if !fromTemplate {
        let system = s.slotInsert(slot, component: s.variant("SystemChoice", "Selezione=debian"), replace: true)
        s.set(system, ["sizingH": "fill"])
        // Clicking macOS chooses it and opens the IPSW panel at once (F01 macOS, Prototype.swift).
        refs["macos"] = s.children(of: s.find("Sistemi", in: system))[1]
    }
    let choice = s.slotInsert(slot, component: s.variant("ProfileChoice", "Selezione=\(profile)"), replace: fromTemplate)
    s.set(choice, ["sizingH": "fill"])
    if fromTemplate {
        let list = s.slotInsert(slot, component: s.firstLayerComponent("TemplateChoice"))
        s.set(list, ["sizingH": "fill"])
    }
    return refs
}

func s03Confirm(_ s: Script, _ name: String, parent: Int?, x: Double = 0, y: Double = 0, mode: String) -> ScreenRefs {
    let (refs, slot) = wizardWindow(s, name, parent: parent, x: x, y: y, mode: mode, step: 2, title: "Download",
                                    description: "Nido downloads the official image and checks its integrity before using it.",
                                    next: "Download")
    infoRow(s, parent: slot, "Source", "cloud.debian.org", replace: true)
    infoRow(s, parent: slot, "File", "debian-13-genericcloud-arm64.raw")
    infoRow(s, parent: slot, "Size", "1.2 GiB to download")
    infoRow(s, parent: slot, "Verification", "SHA-512 checksum")
    return refs
}

func s03Progress(_ s: Script, _ name: String, parent: Int?, x: Double = 0, y: Double = 0, mode: String,
                 phase: String) -> ScreenRefs {
    let failed = phase == "errore"
    let (refs, slot) = wizardWindow(s, name, parent: parent, x: x, y: y, mode: mode,
                                    nextEnabled: failed, step: 2, title: "Download",
                                    description: "Nido downloads the official image and checks its integrity before using it.",
                                    next: failed ? "Try Again" : "Next")
    switch phase {
    case "download":
        progressPanel(s, slot: slot, phase: phase, title: "Downloading Debian 13",
                      detail: "cloud.debian.org · 0.4 GiB of 1.2 GiB · about 2 min", fraction: 0.34)
    case "verifica":
        progressPanel(s, slot: slot, phase: phase, title: "Verifying the image",
                      detail: "Verifying the SHA-512 checksum · 1.2 GiB", fraction: 0.8)
    default:
        progressPanel(s, slot: slot, phase: "errore", title: "Download failed",
                      detail: "The SHA-512 checksum doesn’t match: the downloaded file was deleted. "
                        + "Try again: Nido downloads the image again.", fraction: nil)
    }
    return refs
}

func s04Resources(_ s: Script, _ name: String, parent: Int?, x: Double = 0, y: Double = 0, mode: String,
                  overLimit: Bool, headroom: Bool = false) -> ScreenRefs {
    let (refs, slot) = wizardWindow(s, name, parent: parent, x: x, y: y, mode: mode,
                                    nextEnabled: !overLimit, step: 3, title: "Resources",
                                    description: resourcesDescription)
    stepperRow(s, parent: slot, label: "CPU", detail: "Recommended: 2 · at most 8 (this Mac’s cores)", value: "4",
               replace: true)
    if overLimit {
        stepperRow(s, parent: slot, state: "fuori limite", label: "Memory",
                   detail: "Over the limit: at most 12 GiB on this Mac.", value: "16 GiB")
    } else {
        stepperRow(s, parent: slot, label: "Memory", detail: "Recommended: 4 GiB · at most 12 GiB", value: "8 GiB")
    }
    stepperRow(s, parent: slot, label: "Disk", detail: "Free space on the Mac: 412 GiB", value: "64 GiB")
    if headroom {
        // MemoryHeadroom: only a warning, Avanti stays enabled (starting is the user's choice).
        notice(s, parent: slot, inSlot: true, kind: "attenzione",
               title: "The memory of the running VMs exceeds 75% of the Mac’s RAM: the guest may crash; "
                + "reduce the memory or close other VMs/Docker.",
               detail: "Nido VMs running 8 GiB, other VMs (e.g. Docker) 2 GiB, this VM 8 GiB: 18 GiB of 16 GiB. "
                + "Nido starts the VM anyway if you choose to.")
    }
    return refs
}

/// S05: the SSH key and, since M3c, what the first boot prepares (phase 1) and the optional
/// Ollama of phase 2. `ollama`: the switch is on and the optional model is shown.
func s05Access(_ s: Script, _ name: String, parent: Int?, x: Double = 0, y: Double = 0, mode: String,
               vm: String = "debian-13", ollama: Bool = false) -> ScreenRefs {
    let (refs, slot) = wizardWindow(s, name, parent: parent, x: x, y: y, mode: mode, step: 4,
                                    title: "Access and Software",
                                    description: "Sign in to \(vm) over SSH with your key, no password, and choose "
                                        + "what to set up at first boot.")
    let key = s.slotInsert(slot, component: s.firstLayerComponent("PickerRow"), replace: true)
    s.set(key, ["sizingH": "fill"])
    s.setText(s.find("Etichetta", in: key), "SSH public key")
    s.setText(s.find("Percorso", in: key), "~/.ssh/id_ed25519.pub · ssh-ed25519")
    slotToggle(s, slot: slot, on: true, "Essential packages",
               "curl, git, python3, openssh-server, jq and other basic tools. No full system upgrade.")
    slotToggle(s, slot: slot, on: true, "Nido Guest Tools",
               "CPU, memory and disk monitoring over vsock, without the network. Ollama and the AI bridge need them.")
    slotToggle(s, slot: slot, on: ollama, "Install Ollama after first boot",
               "Nido installs it from the official sources once the VM is ready: you can already use the VM while it downloads.")
    if ollama {
        infoRow(s, parent: slot, "Model (optional)", "llama3.2:1b",
                note: "Only one, downloaded after Ollama. With 4 GiB a small model is best: this is a suggestion, not a guarantee.")
    }
    return refs
}

func s06Summary(_ s: Script, _ name: String, parent: Int?, x: Double = 0, y: Double = 0, mode: String,
                phase: String) -> ScreenRefs {
    let description = "Check your choices: Nido creates debian-13 and starts it as soon as it’s ready."
    switch phase {
    case "riepilogo":
        let (refs, slot) = wizardWindow(s, name, parent: parent, x: x, y: y, mode: mode, step: 5, title: "Summary",
                                        description: description, next: "Create and Start")
        infoRow(s, parent: slot, "Name", "debian-13", replace: true)
        colorRow(s, parent: slot, tint: "Clay", note: "Tells this VM apart in the library. You can change it later in its settings.")
        infoRow(s, parent: slot, "System", "Debian 13 · arm64 · Debian Base")
        infoRow(s, parent: slot, "Resources", "4 CPUs · 8 GiB · 64 GiB disk")
        infoRow(s, parent: slot, "First boot", "Essential packages · Guest Tools")
        infoRow(s, parent: slot, "Access", "SSH · id_ed25519.pub")
        infoRow(s, parent: slot, "Network", "NAT")
        return refs
    case "ai":
        let (refs, slot) = wizardWindow(s, name, parent: parent, x: x, y: y, mode: mode, step: 5, title: "Summary",
                                        description: "Check your choices: Nido creates debian-ai and starts it as soon as it’s ready.",
                                        next: "Create and Start")
        infoRow(s, parent: slot, "Name", "debian-ai", replace: true)
        infoRow(s, parent: slot, "System", "Debian 13 · arm64 · Debian AI Starter")
        infoRow(s, parent: slot, "Resources", "4 CPUs · 4 GiB · 64 GiB disk")
        infoRow(s, parent: slot, "First boot", "Essential packages · Guest Tools")
        infoRow(s, parent: slot, "After first boot", "Ollama and the llama3.2:1b model",
                note: "The VM is usable before then: the progress stays visible in its window.")
        infoRow(s, parent: slot, "Access", "SSH · id_ed25519.pub · NAT network")
        return refs
    case "modello":
        let (refs, slot) = wizardWindow(s, name, parent: parent, x: x, y: y, mode: mode, step: 2, total: 2,
                                        title: "Summary",
                                        description: "Check your choices: Nido copies debian-ai-base to ricerca-02 and starts it.",
                                        next: "Create and Start")
        infoRow(s, parent: slot, "Name", "ricerca-02", replace: true)
        infoRow(s, parent: slot, "Template", "debian-ai-base · Debian AI Starter")
        infoRow(s, parent: slot, "Resources", "4 CPUs · 8 GiB · 64 GiB disk, like the template")
        infoRow(s, parent: slot, "Space on the Mac", "No extra space until the disks change",
                note: "Instant copy of the disk (clonefile).")
        infoRow(s, parent: slot, "Identity", "New: MAC address, host name, SSH host keys")
        infoRow(s, parent: slot, "Shared folders and AI bridge", "None · off",
                note: "They don’t carry over from the template to the new VM: you choose them later.")
        return refs
    case "creazione":
        let (refs, slot) = wizardWindow(s, name, parent: parent, x: x, y: y, mode: mode, nextEnabled: false,
                                        step: 5, title: "Summary", description: description, next: "Create and Start")
        progressPanel(s, slot: slot, phase: "creazione", title: "Creating debian-13",
                      detail: "Copying the disk (64 GiB) and preparing cloud-init", fraction: 0.6)
        return refs
    default:
        let (refs, slot) = wizardWindow(s, name, parent: parent, x: x, y: y, mode: mode, step: 5, title: "Summary",
                                        description: description, next: "Try Again")
        progressPanel(s, slot: slot, phase: "errore", title: "Creation failed",
                      detail: "Not enough disk space: 64 GiB needed, 41 GiB left on the Mac. "
                        + "Free up space or make the disk smaller in the Resources step.", fraction: nil)
        return refs
    }
}

// MARK: - VM window (S07, S11)

let bootLines = """
    Loading Linux 6.12.48+deb13-arm64 ...
    Loading initial ramdisk ...
    [    0.000000] Booting Linux on physical CPU 0x0000000000 [0x610f0000]
    [    0.000000] Linux version 6.12.48+deb13-arm64 (debian-kernel@lists.debian.org)
    [    0.000000] Machine model: Apple Virtualization Generic Platform
    [    1.204817] virtio_blk virtio1: [vda] 134217728 512-byte logical blocks (68.7 GB/64.0 GiB)
    """

let consoleLines = """
    [  OK  ] Finished cloud-init-network.service - Cloud-init: Network Stage.
    [  OK  ] Reached target cloud-config.target - Cloud-config availability.
    [  OK  ] Started ssh.service - OpenBSD Secure Shell server.
    [  OK  ] Finished cloud-final.service - Cloud-init: Final Stage.
    [  OK  ] Reached target multi-user.target - Multi-User System.

    Debian GNU/Linux 13 debian-13 hvc0

    debian-13 login: _
    """

/// The VM's framebuffer: fills the rest of the window.
func console(_ s: Script, parent: Int, lines: String) -> Int {
    let screen = fillArea(s, "Schermo della VM", parent: parent, padding: ["xl"], props: ["fills": [consoleFill]])
    s.plainText(lines, parent: screen, props: ["fontFamily": consoleFont, "fontStyle": "Regular", "fontSize": 13,
                                                "lineHeight": 20, "fills": [consoleText]])
    return screen
}

/// The VM window in one state: title bar, VMToolbar, then the framebuffer or a message.
func vmWindow(_ s: Script, _ name: String, parent: Int?, x: Double = 0, y: Double = 0, mode: String,
              state: String) -> ScreenRefs {
    let w = window(s, name, parent: parent, x: x, y: y, mode: mode)
    let titleBar = stack(s, "Barra del titolo", parent: w, "horizontal", padding: ["0", "l"],
                         props: ["sizingH": "fill", "sizingV": "fixed", "crossAlign": "center"])
    s.set(titleBar, ["height": 28])
    s.bind(titleBar, "fill", "surface")
    trafficLights(s, parent: titleBar)
    let bar = s.instance(of: s.variant("VMToolbar", "Stato=\(state)"), parent: w)
    s.set(bar, ["sizingH": "fill"])
    var refs: ScreenRefs = ["window": w]
    let buttons = Array(s.children(of: bar).dropFirst(3))  // after name, badge and spacer
    let names: [String: [String]] = [
        "starting": ["pausa", "arresta"], "running": ["pausa", "sospendi", "arresta", "snapshot", "schermoIntero"],
        "paused": ["riprendi", "arresta"], "stopped": ["avvia", "snapshot", "impostazioni"],
        "suspended": ["riprendi", "snapshot", "impostazioni"], "error": ["riprova", "dettagli"],
    ]
    for (key, id) in zip(names[state]!, buttons) { refs[key] = id }
    // M3c: the window's views (Schermo, Monitor, AI), see ScreensAI.swift.
    vmTabs(s, window: w, selected: "Screen", bridge: false)

    switch state {
    case "starting":
        _ = console(s, parent: w, lines: bootLines)
    case "running":
        _ = console(s, parent: w, lines: consoleLines)
    case "paused":
        let screen = console(s, parent: w, lines: consoleLines)
        s.set(s.children(of: screen)[0], ["opacity": 0.35])
        let note = stack(s, "Avviso di pausa", parent: w, "vertical", gap: "s", padding: ["l"], width: 360,
                         props: ["sizingH": "fixed", "crossAlign": "center"])
        s.set(note, ["absolute": true, "x": (windowWidth - 360) / 2, "y": 330, "effects": sheetShadow])
        s.bind(note, "fill", "surfaceRaised")
        s.bind(note, "cornerRadius", "Radius/m")
        s.stroke(note, "border")
        s.instance(of: s.variant("StatusBadge", "Stato=paused"), parent: note)
        s.text("debian-13 stays in memory where you left it. Resume to continue.", parent: note,
               size: "body", color: "textPrimary",
               props: ["sizingH": "fill", "textAutoResize": "height", "textAlign": "center"])
    default:
        let area = fillArea(s, "Contenuto", parent: w, padding: ["xl"],
                            props: ["mainAlign": "center", "crossAlign": "center"])
        let empty = s.instance(of: s.firstLayerComponent("EmptyState"), parent: area)
        s.set(s.parent(of: s.find("Create VM", in: empty)), ["visible": false])  // the toolbar has the action
        if state == "stopped" {
            s.setText(s.find("The nest is empty", in: empty), "debian-13 is stopped")
            s.setText(s.find(emptyStateBody, in: empty),
                      "Last stopped today at 10:42. Start the VM from the toolbar: the disk and the settings stay as you left them.")
        } else if state == "suspended" {
            // VMWindowModel.stoppedTitle / stoppedMessage for a VM suspended from this window.
            s.setText(s.find("The nest is empty", in: empty), "debian-13 is suspended")
            s.setText(s.find(emptyStateBody, in: empty),
                      "The VM’s state is saved on the Mac: Resume to continue where you left off.")
        } else {
            s.setText(s.find("The nest is empty", in: empty), "Start failed")
            s.bind(s.children(of: s.find("Nido", in: empty))[0], "fill", "statusError")
            s.setText(s.find(emptyStateBody, in: empty),
                      "The VM’s disk (disk.img) can’t be read. Check the free space on the Mac and start it again.")
        }
    }
    return refs
}

let emptyStateBody = "Create your first virtual machine: Nido downloads Debian 13, verifies the image and sets up the VM in a few minutes."

/// S11: the VM fills the screen; the toolbar slides in from the top edge (shown here).
func fullScreenWindow(_ s: Script, _ name: String, parent: Int?, x: Double = 0, y: Double = 0, mode: String) -> ScreenRefs {
    let w = window(s, name, parent: parent, x: x, y: y, mode: mode, fullScreen: true)
    _ = console(s, parent: w, lines: consoleLines)
    let bar = s.instance(of: s.variant("VMToolbar", "Stato=running"), parent: w)
    s.set(bar, ["absolute": true, "x": 0, "y": 0, "effects": sheetShadow])
    let exit = s.children(of: bar).last!
    s.setText(s.children(of: exit)[0], "Exit Full Screen")
    return ["window": w, "esci": exit]
}

// MARK: - Settings windows (S08, S10)

/// A settings window: toolbar, sidebar of sections, and a form column. Returns the column.
func settingsWindow(_ s: Script, _ name: String, parent: Int?, x: Double, y: Double, mode: String, title: String,
                    sections: [String], comingSoon: Set<String> = [], selected: String, heading: String,
                    intro: String) -> (Int, Int) {
    let w = window(s, name, parent: parent, x: x, y: y, mode: mode)
    _ = toolbar(s, window: w, title: title, subtitle: nil)
    let body = fillArea(s, "Corpo", parent: w, "horizontal")
    let side = stack(s, "Barra laterale", parent: body, "vertical", gap: "xs", padding: ["m", "s"], width: 220,
                     props: ["sizingH": "fixed", "sizingV": "fill"])
    s.bind(side, "fill", "surface")
    s.stroke(side, "border", props: ["strokeSides": [0, 1, 0, 0]])
    for section in sections {
        let isSelected = section == selected
        let item = stack(s, section, parent: side, "horizontal", padding: ["0", "s"],
                         props: ["sizingH": "fill", "sizingV": "fixed", "crossAlign": "center"])
        s.set(item, ["height": 28])
        s.bind(item, "cornerRadius", "Radius/s")
        if isSelected { s.bind(item, "fill", "accent") }
        let later = comingSoon.contains(section)
        s.text(section, parent: item, size: "body", style: isSelected ? "SemiBold" : "Regular",
               color: isSelected ? "accentText" : later ? "textSecondary" : "textPrimary")
        if later {
            spacer(s, parent: item)
            s.text("Coming soon", parent: item, size: "caption", color: "textSecondary")
        }
    }
    let content = fillArea(s, "Contenuto", parent: body, padding: ["xl"])
    let column = stack(s, "Modulo", parent: content, "vertical", gap: "s", width: 560, props: ["sizingH": "fixed"])
    let head = stack(s, "Testa", parent: column, "vertical", gap: "xs", props: ["sizingH": "fill"])
    s.text(heading, parent: head, size: "title", style: "SemiBold", color: "textPrimary")
    s.text(intro, parent: head, size: "body", color: "textSecondary",
           props: ["sizingH": "fill", "textAutoResize": "height"])
    // A little more room between the heading and the rows than between rows.
    s.set(head, ["paddingBottom": 8])
    return (w, column)
}

func s08Settings(_ s: Script, _ name: String, parent: Int?, x: Double = 0, y: Double = 0, mode: String,
                 running: Bool) -> ScreenRefs {
    let (w, column) = settingsWindow(s, name, parent: parent, x: x, y: y, mode: mode, title: "debian-13 Settings",
                                     sections: vmSettingsSections, comingSoon: vmSettingsComingSoon, selected: "Hardware",
                                     heading: "Hardware",
                                     intro: "CPU and memory apply from the next start of debian-13.")
    if running {
        let notice = stack(s, "Avviso", parent: column, "horizontal", gap: "m", padding: ["m", "l"],
                           props: ["sizingH": "fill", "crossAlign": "center"])
        s.bind(notice, "fill", "surfaceRaised")
        s.bind(notice, "cornerRadius", "Radius/m")
        s.stroke(notice, "statusPaused")
        s.instance(of: s.variant("StatusBadge", "Stato=running"), parent: notice)
        s.text("Stop debian-13 to change CPU and memory.", parent: notice, size: "body", color: "textPrimary",
               props: ["sizingH": "fill", "textAutoResize": "height"])
        button(s, "secondary", "Stop", parent: notice)
    }
    let lockedDetail = "Can’t be changed while debian-13 is running"
    let cpu = stepperRow(s, parent: column, label: "CPU",
                         detail: running ? lockedDetail : "Recommended: 2 · at most 8 (this Mac’s cores)",
                         value: "4", inSlot: false)
    let memory = stepperRow(s, parent: column, label: "Memory",
                            detail: running ? lockedDetail : "Recommended: 4 GiB · at most 12 GiB",
                            value: "8 GiB", inSlot: false)
    if running {
        for row in [cpu, memory] { s.set(row, ["opacity": 0.5]) }
    }
    infoRow(s, parent: column, "Disk", "64 GiB", note: "The disk size is chosen when the VM is created.",
            inSlot: false)
    let toggle = s.instance(of: s.variant("ToggleRow", running ? "Stato=bloccata" : "Stato=attiva"), parent: column)
    s.set(toggle, ["sizingH": "fill"])
    return ["window": w]
}

func s10Preferences(_ s: Script, _ name: String, parent: Int?, x: Double = 0, y: Double = 0, mode: String) -> ScreenRefs {
    let (w, column) = settingsWindow(s, name, parent: parent, x: x, y: y, mode: mode, title: "Nido Settings",
                                     sections: appSettingsSections, selected: "General", heading: "General",
                                     intro: "Nido keeps the VMs in a folder it shares with the nido command.")
    let folder = s.instance(of: s.firstLayerComponent("PickerRow"), parent: column)
    s.set(folder, ["sizingH": "fill"])
    s.setText(s.find("Etichetta", in: folder), "VM folder")
    s.setText(s.find("Percorso", in: folder), "~/Library/Application Support/Nido/VMs · read only")
    s.setText(s.children(of: s.children(of: folder).last!)[0], "Show in Finder")
    infoRow(s, parent: column, "Version", "Nido 0.2.0", inSlot: false)
    infoRow(s, parent: column, "License", "Apache License 2.0", note: "Nido is free software: its code is public.",
            inSlot: false)
    return ["window": w]
}

// MARK: - S08 sections Generale and Condivisione (VMSettingsView)

let vmSettingsSections = ["General", "Hardware", "Sharing", "Guest Tools", "Access", "Network"]
let vmSettingsComingSoon: Set<String> = ["Access", "Network"]

/// A PickerRow with its own label, note and button (Rimuovi, Copia, Installa Rosetta…).
@discardableResult
func pickerRow(_ s: Script, parent: Int, _ label: String, _ note: String, action: String) -> Int {
    let r = s.instance(of: s.firstLayerComponent("PickerRow"), parent: parent)
    s.set(r, ["sizingH": "fill"])
    s.setText(s.find("Etichetta", in: r), label)
    s.setText(s.find("Percorso", in: r), note)
    s.setText(s.children(of: s.children(of: r).last!)[0], action)
    return r
}

/// A ToggleRow with its own title and explanation; `locked` dims the switch (NidoToggleRow isLocked).
@discardableResult
func toggleRow(_ s: Script, parent: Int, on: Bool, locked: Bool = false, _ title: String,
               _ explanation: String) -> Int {
    let state = on ? (locked ? "bloccata" : "attiva") : "disattivata"
    let r = s.instance(of: s.variant("ToggleRow", "Stato=\(state)"), parent: parent)
    s.set(r, ["sizingH": "fill"])
    s.setText(s.find("Sync the clock with the Mac", in: r), title)
    let old = state == "bloccata" ? "Can be changed only with the VM stopped."
        : "The Mac sets the VM’s clock at every start and after a pause."
    s.setText(s.find(old, in: r), explanation)
    if locked && !on { s.set(s.find("Interruttore", in: r), ["opacity": 0.5]) }
    return r
}

/// "Generale": name and MAC address (read-only), and the way to the snapshots (S09).
func s08General(_ s: Script, _ name: String, parent: Int?, x: Double = 0, y: Double = 0, mode: String) -> ScreenRefs {
    let (w, column) = settingsWindow(s, name, parent: parent, x: x, y: y, mode: mode, title: "debian-13 Settings",
                                     sections: vmSettingsSections, comingSoon: vmSettingsComingSoon,
                                     selected: "General", heading: "General",
                                     intro: "The virtual machine’s details, its color and its snapshots.")
    infoRow(s, parent: column, "Name", "debian-13", note: "The name is chosen when the VM is created.", inSlot: false)
    colorRow(s, parent: column, tint: designTint(for: "debian-13"), inSlot: false)
    infoRow(s, parent: column, "MAC address", "52:54:00:3a:9c:12", note: "Assigned when the VM was created.",
            inSlot: false)
    let snapshots = pickerRow(s, parent: column, "Snapshots",
                              "3 snapshots · the latest, after-docker, from Oct 24, 2026, 4:05 PM", action: "Manage Snapshots…")
    return ["window": w, "snapshot": s.children(of: snapshots).last!]
}

/// One shared folder: its row (Rimuovi) and the Sola lettura switch under it.
func sharedFolder(_ s: Script, parent: Int, name: String, hostPath: String, readOnly: Bool) {
    // The folder and its switch stay together (xs); groups sit further apart (s + 4).
    let group = stack(s, name, parent: parent, "vertical", gap: "xs", props: ["sizingH": "fill", "paddingBottom": 4])
    pickerRow(s, parent: group, name, "\(hostPath) → /mnt/nido/\(name)", action: "Remove")
    toggleRow(s, parent: group, on: readOnly, "Read only",
              readOnly ? "The VM reads the files but can’t change or delete them."
                  : "The VM can change and delete the files in this folder on the Mac: turn this on only if you need it.")
}

/// "Condivisione": shared folders and Rosetta. `rosettaMissing`: no folders yet, a VM created by
/// an older Nido (one-time guest command), Rosetta not installed on this Mac.
func s08Sharing(_ s: Script, _ name: String, parent: Int?, x: Double = 0, y: Double = 0, mode: String,
                rosettaMissing: Bool, running: Bool = false) -> ScreenRefs {
    let (w, column) = settingsWindow(s, name, parent: parent, x: x, y: y, mode: mode, title: "debian-13 Settings",
                                     sections: vmSettingsSections, comingSoon: vmSettingsComingSoon,
                                     selected: "Sharing", heading: "Sharing",
                                     intro: "Folders on the Mac that the VM sees in /mnt/nido. Adding or removing a "
                                        + "folder or changing read only takes effect right away, even while the VM is running.")
    if running {
        // A change while the VM runs: the share of the session is replaced at once (spec G).
        notice(s, parent: column, inSlot: false, kind: "informazione",
               title: "Takes effect right away: dataset is now read only for the running debian-13 too.",
               detail: "Programs in the VM that were writing to /mnt/nido/dataset now get a read-only error.")
    }
    if rosettaMissing {
        infoRow(s, parent: column, "No shared folders", "",
                note: "The VM can’t see any files on the Mac. Add a folder to make it visible in /mnt/nido.",
                inSlot: false)
        pickerRow(s, parent: column, "Shared folders: VM created with an earlier version of Nido",
                  "To see the folders in /mnt/nido, run this once in the VM:\n"
                    + "sudo sh -c 'mkdir -p /etc/systemd/system && printf \"%s\\n\" \"[Unit]\" …'",
                  action: "Copy")
    } else {
        sharedFolder(s, parent: column, name: "progetti", hostPath: "/Users/anna/Progetti", readOnly: true)
        sharedFolder(s, parent: column, name: "dataset", hostPath: "/Volumes/Dati/dataset", readOnly: running)
    }
    let bar = stack(s, "Aggiungi", parent: column, "horizontal", gap: "m", props: ["sizingH": "fill"])
    spacer(s, parent: bar)
    button(s, "primary", "Add Folder…", parent: bar)
    if rosettaMissing {
        toggleRow(s, parent: column, on: false, locked: true, "Rosetta (x86_64 binaries)",
                  "Rosetta isn’t installed on this Mac. Install it to turn it on.")
        pickerRow(s, parent: column, "Rosetta isn’t installed on this Mac",
                  "It’s a macOS system component; installing it needs your confirmation.",
                  action: "Install Rosetta…")
    } else {
        toggleRow(s, parent: column, on: true, "Rosetta (x86_64 binaries)",
                  "The VM runs Linux programs for Intel (x86_64) with Rosetta. Applies from the next start.")
    }
    return ["window": w]
}

// MARK: - Snapshots (S09)

/// A snapshot in the list: name, date, whether it holds the memory too.
typealias SnapshotFixture = (name: String, date: String, savedState: Bool)

let snapshotFixtures: [SnapshotFixture] = [
    ("after-docker", "Oct 24, 2026, 4:05 PM", true),
    ("before-update", "Oct 24, 2026, 10:42 AM", true),
    ("installazione-pulita", "Oct 22, 2026, 9:15 AM", false),
]

/// S09: the snapshots of one VM, newest first, under the current state (or the progress of a new
/// snapshot, or its error). `phase`: vuoto, elenco, creazione, errore.
func snapshotsWindow(_ s: Script, _ name: String, parent: Int?, x: Double = 0, y: Double = 0, mode: String,
                     phase: String, running: Bool = false, extra: SnapshotFixture? = nil) -> ScreenRefs {
    let w = window(s, name, parent: parent, x: x, y: y, mode: mode)
    let list = (extra.map { [$0] } ?? []) + (phase == "vuoto" ? [] : snapshotFixtures)
    let vmState = running ? "debian-13 running" : "debian-13 stopped"
    _ = toolbar(s, window: w, title: "Snapshots of debian-13",
                subtitle: list.isEmpty ? "No snapshots · \(vmState)" : "\(list.count) snapshots · \(vmState)")
    var refs: ScreenRefs = ["window": w]

    if phase == "vuoto" {
        let content = fillArea(s, "Contenuto", parent: w, padding: ["xl"],
                               props: ["mainAlign": "center", "crossAlign": "center"])
        let empty = s.instance(of: s.firstLayerComponent("EmptyState"), parent: content)
        s.setText(s.find("The nest is empty", in: empty), "No snapshots")
        s.setText(s.find(emptyStateBody, in: empty),
                  "A snapshot keeps the disk of debian-13 as it is now, and its memory too if the VM is running. "
                    + "You can go back to it anytime.")
        let label = s.find("Create VM", in: empty)
        s.setText(label, "Create Snapshot…")
        refs["crea"] = s.parent(of: label)
        return refs
    }

    let content = fillArea(s, "Contenuto", parent: w, padding: ["xl"], props: ["crossAlign": "center"])
    let column = stack(s, "Elenco", parent: content, "vertical", gap: "s", width: 720, props: ["sizingH": "fixed"])
    s.text("A snapshot keeps the VM’s disk and settings; taken while the VM is running, its memory too (with "
           + "saved state). Restoring it takes debian-13 back to that moment.",
           parent: column, size: "body", color: "textSecondary",
           props: ["sizingH": "fill", "textAutoResize": "height"])
    let top = stack(s, "Current state", parent: column, "vertical", props: ["sizingH": "fill", "paddingTop": 8,
                                                                            "paddingBottom": 8])
    switch phase {
    case "creazione":
        progressPanel(s, slot: top, phase: "creazione", title: "Creating \(extra?.name ?? "snapshot-1")",
                      detail: "debian-13 stays paused for a few seconds while Nido saves its memory and disk.",
                      fraction: 0.6, inSlot: false, width: 688)
    case "errore":
        let panel = progressPanel(s, slot: top, phase: "errore", title: "Snapshot failed",
                                  detail: "Not enough space: 10 GiB needed, 4 GiB available. "
                                    + "Free up space on the Mac and try again.",
                                  fraction: nil, inSlot: false, keepActions: true)
        s.setText(s.children(of: s.children(of: s.find("Azioni", in: panel))[0])[0], "Close")
    default:
        let current = s.instance(of: s.variant("SnapshotRow", "Stato=corrente"), parent: top)
        s.set(current, ["sizingH": "fill"])
        if running {
            // The StatusBadge of the running state (a nested variant switch would renumber the row).
            let badge = s.children(of: s.children(of: s.find("Details", in: current))[0])
            s.bind(badge[0], "fill", "statusRunning")
            s.setText(badge[1], "Running")
        }
        refs["crea"] = s.children(of: s.find("Azioni", in: current))[0]
    }

    s.text(phase == "creazione" ? "Snapshots (\(list.count))" : "Snapshots (\(list.count)), newest first",
           parent: column, size: "caption", style: "SemiBold", color: "textSecondary")
    for (index, snapshot) in list.enumerated() {
        let creating = phase == "creazione" && index == 0 && extra != nil
        let row = s.instance(of: s.variant("SnapshotRow", creating ? "Stato=in creazione" : "Stato=normale"),
                             parent: column)
        s.set(row, ["sizingH": "fill"])
        s.setText(s.find("before-update", in: row), snapshot.name)
        if creating { continue }
        s.setText(s.find("Oct 24, 2026, 10:42 AM", in: row), snapshot.date)
        if !snapshot.savedState { s.set(s.find("Stato salvato", in: row), ["visible": false]) }
        let actions = s.children(of: s.find("Azioni", in: row))
        // A secondary NidoButton looks disabled with the disabled variant's text colour and opacity
        // (switching two nested variants in one row would renumber the layers).
        func disable(_ button: Int) {
            s.bind(s.children(of: button)[0], "fill", "textSecondary")
            s.set(button, ["opacity": 0.5])
        }
        // A running VM is never restored (Review Focus 1): Ripristina waits for it to stop.
        if running { disable(actions[0]) }
        // The snapshot being created holds the VM's lock: nothing else until it is done.
        if phase == "creazione" { disable(actions[1]) }
        refs["ripristina-\(snapshot.name)"] = actions[0]
        refs["elimina-\(snapshot.name)"] = actions[1]
    }
    if running {
        s.text("To restore a snapshot, stop debian-13 first.", parent: column, size: "caption",
               color: "textSecondary")
    }
    return refs
}

/// "Crea snapshot…": the name (default snapshot-1), over the list.
func snapshotNameSheet(_ s: Script, _ name: String, parent: Int?, x: Double = 0, y: Double = 0, mode: String,
                       running: Bool = false) -> ScreenRefs {
    var refs = snapshotsWindow(s, name, parent: parent, x: x, y: y, mode: mode, phase: "elenco", running: running)
    let message = running
        ? "debian-13 is running: Nido pauses it for a few seconds and saves its memory too."
        : "Nido saves the disk and settings of debian-13 as they are now."
    let sheet = formSheet(s, window: refs["window"]!, title: "Create a Snapshot of debian-13", message: message)
    // The name field and its rule read as one group (xs), apart from the buttons (m).
    let field = stack(s, "Campo", parent: sheet, "vertical", gap: "xs", props: ["sizingH": "fill"])
    infoRow(s, parent: field, "Name", "snapshot-1", inSlot: false)
    s.text("Letters, numbers, periods, hyphens and underscores; different from the other snapshots of debian-13.",
           parent: field, size: "caption", color: "textSecondary", props: ["sizingH": "fill", "textAutoResize": "height"])
    let (cancel, create) = sheetActions(s, parent: sheet, action: "Create")
    refs["annulla"] = cancel
    refs["conferma"] = create
    return refs
}

/// Ripristina or Elimina asks first (ConfirmSheet, destructive).
func snapshotConfirmSheet(_ s: Script, _ name: String, parent: Int?, x: Double = 0, y: Double = 0, mode: String,
                          restore: Bool) -> ScreenRefs {
    var refs = snapshotsWindow(s, name, parent: parent, x: x, y: y, mode: mode, phase: "elenco")
    let (cancel, action) = restore
        ? confirmSheet(s, window: refs["window"]!, kind: "eliminazione", title: "Restore before-update?",
                       message: "The VM will go back to its state as of Oct 24, 2026, 10:42 AM; later changes will be lost.",
                       action: "Restore")
        : confirmSheet(s, window: refs["window"]!, kind: "eliminazione", title: "Delete after-docker?",
                       message: "The snapshot and the memory saved with it will be deleted from this Mac; "
                        + "debian-13 stays as it is. This can’t be undone.",
                       action: "Delete")
    refs["annulla"] = cancel
    refs["conferma"] = action
    return refs
}

// MARK: - Clona… (CloneSheet)

func cloneSheet(_ s: Script, _ name: String, parent: Int?, x: Double = 0, y: Double = 0, mode: String,
                copying: Bool) -> ScreenRefs {
    var refs = libraryWindow(s, name, parent: parent, x: x, y: y, mode: mode, withVMs: true)
    let sheet = formSheet(s, window: refs["window"]!, title: "Clone debian-13?",
                          message: "The copy gets a new network address and a new identity; at first boot it takes "
                            + "the new name as its host name. Rosetta is copied; shared folders, AI bridge, "
                            + "snapshots and the suspended state aren’t.")
    let field = infoRow(s, parent: sheet, "Name", "debian-13-copia", inSlot: false)
    if copying {
        s.set(field, ["opacity": 0.5])
        let progress = stack(s, "Avanzamento", parent: sheet, "vertical", gap: "xs", props: ["sizingH": "fill"])
        s.text("Copying…", parent: progress, size: "caption", color: "textSecondary")
        indeterminateBar(s, parent: progress, width: 392)
    }
    let (cancel, confirm) = sheetActions(s, parent: sheet, action: "Clone", disabled: copying)
    refs["annulla"] = cancel
    refs["clona"] = confirm
    return refs
}

// MARK: - Screens page

/// Every screen and state, in order: label and builder (name, parent, mode).
func screenList(_ s: Script) -> [(String, (String, Int?, String) -> ScreenRefs)] {
    [
        ("S01 Libreria · vuota", { libraryWindow(s, $0, parent: $1, mode: $2, withVMs: false) }),
        ("S01 Libreria · VM in ogni stato", { libraryWindow(s, $0, parent: $1, mode: $2, withVMs: true) }),
        ("S01 Libreria · Clona", { cloneSheet(s, $0, parent: $1, mode: $2, copying: false) }),
        ("S01 Libreria · Clona in corso", { cloneSheet(s, $0, parent: $1, mode: $2, copying: true) }),
        ("S02 Sistema", { s02System(s, $0, parent: $1, mode: $2) }),
        ("S02 Sistema · da modello", { s02System(s, $0, parent: $1, mode: $2, profile: "modello") }),
        ("S03 Download · conferma", { s03Confirm(s, $0, parent: $1, mode: $2) }),
        ("S03 Download · avanzamento", { s03Progress(s, $0, parent: $1, mode: $2, phase: "download") }),
        ("S03 Download · verifica", { s03Progress(s, $0, parent: $1, mode: $2, phase: "verifica") }),
        ("S03 Download · errore checksum", { s03Progress(s, $0, parent: $1, mode: $2, phase: "errore") }),
        ("S04 Risorse · valori", { s04Resources(s, $0, parent: $1, mode: $2, overLimit: false) }),
        ("S04 Risorse · fuori limite", { s04Resources(s, $0, parent: $1, mode: $2, overLimit: true) }),
        ("S04 Risorse · avviso memoria", {
            s04Resources(s, $0, parent: $1, mode: $2, overLimit: false, headroom: true) }),
        ("S05 Accesso e software", { s05Access(s, $0, parent: $1, mode: $2) }),
        ("S05 Accesso e software · Ollama", {
            s05Access(s, $0, parent: $1, mode: $2, vm: "debian-ai", ollama: true) }),
        ("S06 Riepilogo", { s06Summary(s, $0, parent: $1, mode: $2, phase: "riepilogo") }),
        ("S06 Riepilogo · Debian AI Starter", { s06Summary(s, $0, parent: $1, mode: $2, phase: "ai") }),
        ("S06 Riepilogo · da modello", { s06Summary(s, $0, parent: $1, mode: $2, phase: "modello") }),
        ("S06 Creazione · in corso", { s06Summary(s, $0, parent: $1, mode: $2, phase: "creazione") }),
        ("S06 Creazione · errore", { s06Summary(s, $0, parent: $1, mode: $2, phase: "errore") }),
        ("S07 Finestra VM · avvio", { vmWindow(s, $0, parent: $1, mode: $2, state: "starting") }),
        ("S07 Finestra VM · in esecuzione", { vmWindow(s, $0, parent: $1, mode: $2, state: "running") }),
        ("S07 Finestra VM · in pausa", { vmWindow(s, $0, parent: $1, mode: $2, state: "paused") }),
        ("S07 Finestra VM · arrestata", { vmWindow(s, $0, parent: $1, mode: $2, state: "stopped") }),
        ("S07 Finestra VM · sospesa", { vmWindow(s, $0, parent: $1, mode: $2, state: "suspended") }),
        ("S07 Finestra VM · errore", { vmWindow(s, $0, parent: $1, mode: $2, state: "error") }),
        ("S11 Schermo intero", { fullScreenWindow(s, $0, parent: $1, mode: $2) }),
        ("S08 Impostazioni VM · arrestata", { s08Settings(s, $0, parent: $1, mode: $2, running: false) }),
        ("S08 Impostazioni VM · in esecuzione", { s08Settings(s, $0, parent: $1, mode: $2, running: true) }),
        ("S08 Impostazioni VM · generale", { s08General(s, $0, parent: $1, mode: $2) }),
        ("S08 Impostazioni VM · condivisione", { s08Sharing(s, $0, parent: $1, mode: $2, rosettaMissing: false) }),
        ("S08 Impostazioni VM · Rosetta da installare", {
            s08Sharing(s, $0, parent: $1, mode: $2, rosettaMissing: true) }),
        ("S09 Snapshot · nessuno snapshot", { snapshotsWindow(s, $0, parent: $1, mode: $2, phase: "vuoto") }),
        ("S09 Snapshot · elenco", { snapshotsWindow(s, $0, parent: $1, mode: $2, phase: "elenco") }),
        ("S09 Snapshot · nuovo snapshot", { snapshotNameSheet(s, $0, parent: $1, mode: $2, running: true) }),
        ("S09 Snapshot · creazione in corso", {
            snapshotsWindow(s, $0, parent: $1, mode: $2, phase: "creazione", running: true,
                            extra: ("snapshot-1", "", true)) }),
        ("S09 Snapshot · errore", { snapshotsWindow(s, $0, parent: $1, mode: $2, phase: "errore") }),
        ("S09 Snapshot · conferma ripristino", { snapshotConfirmSheet(s, $0, parent: $1, mode: $2, restore: true) }),
        ("S09 Snapshot · conferma eliminazione", {
            snapshotConfirmSheet(s, $0, parent: $1, mode: $2, restore: false) }),
        ("S10 Preferenze", { s10Preferences(s, $0, parent: $1, mode: $2) }),
    ] + aiScreenList(s) + macScreenList(s)
}

let screenColumns = 5
let boardGap = 48.0
let boardPadding = 64.0
let boardWidth = Double(screenColumns) * windowWidth + Double(screenColumns - 1) * boardGap + 2 * boardPadding

func screensScript(continuing components: Script) -> Script {
    let s = Script(continuing: components)
    s.step("variable.create", ["collection": "Color", "name": "scrim", "type": "color", "values": scrimValues])
    s.expectVariableID(scrimVariableID)
    screenComponents(s)
    s.page("Screens")
    for (index, mode) in ["Chiaro", "Scuro"].enumerated() {
        let board = s.frame("Schermate · \(mode)", parent: nil, x: Double(index) * (boardWidth + 200), y: 0,
                            width: boardWidth, height: 100,
                            props: ["layout": "vertical", "sizingV": "hug", "gap": boardGap, "padding": boardPadding])
        s.bind(board, "fill", "border")
        s.step("variable.setMode", ["ids": [board], "collection": "Color", "mode": mode])
        s.text("Schermate di Nido · \(mode)", parent: board, size: "title", style: "SemiBold", color: "textPrimary")
        let grid = stack(s, "Schermate", parent: board, "horizontal",
                         props: ["wrap": true, "gap": boardGap, "crossGap": boardGap, "sizingH": "fill"])
        for (label, build) in screenList(s) {
            let item = stack(s, label, parent: grid, "vertical", gap: "m")
            s.text(label, parent: item, size: "headline", style: "SemiBold", color: "textPrimary")
            _ = build("\(label) · \(mode)", item, mode)
        }
    }
    prototypePage(s)
    return s
}
