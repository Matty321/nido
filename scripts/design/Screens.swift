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
    s.text("Cerca tra le VM", parent: field, size: "body", color: "textSecondary")
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
        let box = section("InfoRow", "valore in sola lettura: semplice · con nota")
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

    // PickerRow: a file or folder with its action.
    do {
        let box = section("PickerRow", "file o cartella scelti, con l'azione")
        let r = row("PickerRow", parent: box)
        let labels = stack(s, "Testo", parent: r, "vertical", gap: "xs", props: ["sizingH": "fill"])
        s.text("Etichetta", parent: labels, size: "body", style: "SemiBold", color: "textPrimary")
        s.text("Percorso", parent: labels, size: "caption", color: "textSecondary",
               props: ["sizingH": "fill", "textAutoResize": "height"])
        button(s, "secondary", "Scegli…", parent: r)
        s.makeComponent(r)
    }

    // SystemChoice: the OS tiles of S02 with the source of the image; M3b adds macOS (from an IPSW).
    do {
        let box = section("SystemChoice", "scelta del sistema nella procedura: Debian · macOS")
        let captions = [
            "debian": "Immagine cloud ufficiale di Debian da cloud.debian.org, verificata con SHA-512 prima dell'uso. "
                + "Windows arriverà nelle prossime versioni.",
            "macos": "macOS si installa da un file IPSW che scarichi tu dal sito sviluppatori di Apple, anche beta: "
                + "Nido lo legge soltanto. L'installazione dura 10–20 minuti; l'assistente iniziale di macOS lo "
                + "completi tu nella finestra della VM.",
        ]
        var variants: [Int] = []
        for selection in ["debian", "macos"] {
            let choice = stack(s, "Selezione=\(selection)", parent: box, "vertical", gap: "m", width: 512,
                               props: ["sizingH": "fixed"])
            let tiles = stack(s, "Sistemi", parent: choice, "horizontal", gap: "l", props: ["sizingH": "fill"])
            let mac = selection == "macos"
            let debian = s.instance(of: s.variant("OSTile", mac ? "Stato=normale" : "Stato=selezionato"), parent: tiles)
            if mac {
                s.setText(s.find("U", in: debian), "D")
                s.setText(s.find("Ubuntu 24.04", in: debian), "Debian 13")
                s.setText(s.find("arm64 · 2,6 GiB", in: debian), "arm64 · 1,2 GiB")
            }
            let macTile = s.instance(of: s.variant("OSTile", mac ? "Stato=selezionato" : "Stato=normale"), parent: tiles)
            s.setText(s.find(mac ? "D" : "U", in: macTile), "M")
            s.setText(s.find(mac ? "Debian 13" : "Ubuntu 24.04", in: macTile), "macOS")
            s.setText(s.find(mac ? "arm64 · 1,2 GiB" : "arm64 · 2,6 GiB", in: macTile), "da file IPSW")
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
    let bar = toolbar(s, window: w, title: "Libreria",
                      subtitle: withVMs ? "8 macchine virtuali · 2 in esecuzione" : "Nessuna macchina virtuale")
    searchField(s, parent: bar)
    let new = button(s, "secondary", "Nuova VM", parent: bar)
    var refs: ScreenRefs = ["window": w, "nuova": new]

    if !withVMs {
        let content = fillArea(s, "Contenuto", parent: w, padding: ["xl"],
                               props: ["mainAlign": "center", "crossAlign": "center"])
        let empty = s.instance(of: s.firstLayerComponent("EmptyState"), parent: content)
        refs["crea"] = s.parent(of: s.find("Crea VM", in: empty))
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
        s.setText(s.find("4 CPU · 8 GiB di memoria · disco 64 GiB", in: c), caption)
        return c
    }
    // In the app's order: bundles sorted by name (VMBundle.list), as ScreenshotTests creates them.
    // Suspended with its state saved: VMCard "suspended" (Riprendi, Impostazioni).
    _ = card("suspended", "archivio", "2 CPU · 4 GiB di memoria · disco 32 GiB")
    // Started with `nido start`: VMCard "running-terminale" (Avvia disabled, Arresta active).
    _ = card("running-terminale", "ci-runner", "2 CPU · 4 GiB di memoria · disco 32 GiB")
    let stopped = card("stopped", "debian-13", "4 CPU · 8 GiB di memoria · disco 64 GiB")
    refs["avvia"] = s.children(of: s.find("Azioni", in: stopped))[0]
    _ = card("starting", "dev-box", "4 CPU · 8 GiB di memoria · disco 128 GiB")
    _ = card("paused", "sandbox", "2 CPU · 2 GiB di memoria · disco 32 GiB")
    _ = card("error", "test-arm", "4 CPU · 8 GiB di memoria · disco 64 GiB")
    let unreadable = card("unreadable", "vecchia-vm", "CPU, memoria e disco sconosciuti")
    s.setText(s.find("Debian 13 · arm64", in: unreadable), "Sistema sconosciuto")
    s.setText(s.find("D", in: unreadable), "?")
    let running = card("running", "web-staging", "2 CPU · 4 GiB di memoria · disco 32 GiB")
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
    let cancel = button(s, disabled ? "disabled" : "secondary", "Annulla", parent: row)
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
                  next: String = "Avanti") -> (refs: ScreenRefs, slot: Int) {
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
    s.setText(steps[5], "Passo \(step) di \(total)")
    s.setText(s.find("Risorse", in: sheet), title)
    s.setText(s.find("Scegli quanta CPU, memoria e disco del Mac assegnare a debian-13.", in: sheet), description)

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
        "download": ("Download di Debian 13", "cloud.debian.org · 0,4 GiB di 1,2 GiB · circa 2 min"),
        "verifica": ("Verifica dell'immagine", "Verifica del checksum SHA-512 · 1,2 GiB"),
        "creazione": ("Creazione di debian-13", "Copia del disco (64 GiB) e preparazione di cloud-init"),
        "errore": ("Download non riuscito", "Il checksum SHA-512 non corrisponde: il file scaricato è stato eliminato."),
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
    s.setText(s.find("Memoria", in: r), label)
    let oldDetail = state == "normale" ? "Consigliati 4 GiB · al massimo 12 GiB" : "Oltre il limite: su questo Mac al massimo 12 GiB."
    s.setText(s.find(oldDetail, in: r), detail)
    s.setText(s.find(state == "normale" ? "8 GiB" : "16 GiB", in: r), value)
    return r
}

let resourcesDescription = "Scegli quanta CPU, memoria e disco del Mac assegnare a debian-13."

/// S02: the system and, since M3c, the profile (Debian Base, Debian AI Starter) or a template.
/// `profile`: base, ai, modello.
func s02System(_ s: Script, _ name: String, parent: Int?, x: Double = 0, y: Double = 0, mode: String,
               profile: String = "base") -> ScreenRefs {
    let fromTemplate = profile == "modello"
    let (wizardRefs, slot) = wizardWindow(s, name, parent: parent, x: x, y: y, mode: mode, step: 1,
                                          total: fromTemplate ? 2 : 5, title: "Sistema",
                                          description: fromTemplate
                                              ? "Scegli il modello da cui creare la nuova macchina virtuale."
                                              : "Scegli il sistema e il profilo della nuova macchina virtuale.")
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
                                    description: "Nido scarica l'immagine ufficiale e ne controlla l'integrità prima di usarla.",
                                    next: "Scarica")
    infoRow(s, parent: slot, "Origine", "cloud.debian.org", replace: true)
    infoRow(s, parent: slot, "File", "debian-13-genericcloud-arm64.raw")
    infoRow(s, parent: slot, "Dimensione", "1,2 GiB da scaricare")
    infoRow(s, parent: slot, "Verifica", "checksum SHA-512")
    return refs
}

func s03Progress(_ s: Script, _ name: String, parent: Int?, x: Double = 0, y: Double = 0, mode: String,
                 phase: String) -> ScreenRefs {
    let failed = phase == "errore"
    let (refs, slot) = wizardWindow(s, name, parent: parent, x: x, y: y, mode: mode,
                                    nextEnabled: failed, step: 2, title: "Download",
                                    description: "Nido scarica l'immagine ufficiale e ne controlla l'integrità prima di usarla.",
                                    next: failed ? "Riprova" : "Avanti")
    switch phase {
    case "download":
        progressPanel(s, slot: slot, phase: phase, title: "Download di Debian 13",
                      detail: "cloud.debian.org · 0,4 GiB di 1,2 GiB · circa 2 min", fraction: 0.34)
    case "verifica":
        progressPanel(s, slot: slot, phase: phase, title: "Verifica dell'immagine",
                      detail: "Verifica del checksum SHA-512 · 1,2 GiB", fraction: 0.8)
    default:
        progressPanel(s, slot: slot, phase: "errore", title: "Download non riuscito",
                      detail: "Il checksum SHA-512 non corrisponde: il file scaricato è stato eliminato. "
                        + "Riprova: Nido scarica di nuovo l'immagine.", fraction: nil)
    }
    return refs
}

func s04Resources(_ s: Script, _ name: String, parent: Int?, x: Double = 0, y: Double = 0, mode: String,
                  overLimit: Bool, headroom: Bool = false) -> ScreenRefs {
    let (refs, slot) = wizardWindow(s, name, parent: parent, x: x, y: y, mode: mode,
                                    nextEnabled: !overLimit, step: 3, title: "Risorse",
                                    description: resourcesDescription)
    stepperRow(s, parent: slot, label: "CPU", detail: "Consigliate 2 · al massimo 8 (core di questo Mac)", value: "4",
               replace: true)
    if overLimit {
        stepperRow(s, parent: slot, state: "fuori limite", label: "Memoria",
                   detail: "Oltre il limite: su questo Mac al massimo 12 GiB.", value: "16 GiB")
    } else {
        stepperRow(s, parent: slot, label: "Memoria", detail: "Consigliati 4 GiB · al massimo 12 GiB", value: "8 GiB")
    }
    stepperRow(s, parent: slot, label: "Disco", detail: "Spazio libero sul Mac: 412 GiB", value: "64 GiB")
    if headroom {
        // MemoryHeadroom: only a warning, Avanti stays enabled (starting is the user's choice).
        notice(s, parent: slot, inSlot: true, kind: "attenzione",
               title: "La memoria delle VM accese supera il 75 % della RAM del Mac: rischio di crash del guest; "
                + "riduci la memoria o chiudi altre VM/Docker.",
               detail: "VM di Nido accese 8 GiB, altre VM (es. Docker) 2 GiB, questa VM 8 GiB: 18 GiB su 16 GiB. "
                + "Nido avvia comunque la VM se lo scegli.")
    }
    return refs
}

/// S05: the SSH key and, since M3c, what the first boot prepares (phase 1) and the optional
/// Ollama of phase 2. `ollama`: the switch is on and the optional model is shown.
func s05Access(_ s: Script, _ name: String, parent: Int?, x: Double = 0, y: Double = 0, mode: String,
               vm: String = "debian-13", ollama: Bool = false) -> ScreenRefs {
    let (refs, slot) = wizardWindow(s, name, parent: parent, x: x, y: y, mode: mode, step: 4,
                                    title: "Accesso e software",
                                    description: "Accedi a \(vm) via SSH con la tua chiave, senza password, e scegli "
                                        + "cosa preparare al primo avvio.")
    let key = s.slotInsert(slot, component: s.firstLayerComponent("PickerRow"), replace: true)
    s.set(key, ["sizingH": "fill"])
    s.setText(s.find("Etichetta", in: key), "Chiave SSH pubblica")
    s.setText(s.find("Percorso", in: key), "~/.ssh/id_ed25519.pub · ssh-ed25519")
    slotToggle(s, slot: slot, on: true, "Pacchetti essenziali",
               "curl, git, python3, openssh-server, jq e altri strumenti di base. Nessun aggiornamento completo del sistema.")
    slotToggle(s, slot: slot, on: true, "Nido Guest Tools",
               "Monitor di CPU, memoria e disco via vsock, senza rete. Servono per Ollama e per il ponte AI.")
    slotToggle(s, slot: slot, on: ollama, "Installa Ollama dopo il primo avvio",
               "Nido lo installa dalle fonti ufficiali quando la VM è pronta: puoi già usarla mentre scarica.")
    if ollama {
        infoRow(s, parent: slot, "Modello (facoltativo)", "llama3.2:1b",
                note: "Uno solo, scaricato dopo Ollama. Con 4 GiB conviene un modello piccolo: è un consiglio, non una garanzia.")
    }
    return refs
}

func s06Summary(_ s: Script, _ name: String, parent: Int?, x: Double = 0, y: Double = 0, mode: String,
                phase: String) -> ScreenRefs {
    let description = "Controlla le scelte: Nido crea debian-13 e la avvia appena è pronta."
    switch phase {
    case "riepilogo":
        let (refs, slot) = wizardWindow(s, name, parent: parent, x: x, y: y, mode: mode, step: 5, title: "Riepilogo",
                                        description: description, next: "Crea e avvia")
        infoRow(s, parent: slot, "Nome", "debian-13", replace: true)
        infoRow(s, parent: slot, "Sistema", "Debian 13 · arm64 · Debian Base")
        infoRow(s, parent: slot, "Risorse", "4 CPU · 8 GiB · disco 64 GiB")
        infoRow(s, parent: slot, "Primo avvio", "Pacchetti essenziali · Guest Tools")
        infoRow(s, parent: slot, "Accesso", "SSH · id_ed25519.pub")
        infoRow(s, parent: slot, "Rete", "NAT")
        return refs
    case "ai":
        let (refs, slot) = wizardWindow(s, name, parent: parent, x: x, y: y, mode: mode, step: 5, title: "Riepilogo",
                                        description: "Controlla le scelte: Nido crea debian-ai e la avvia appena è pronta.",
                                        next: "Crea e avvia")
        infoRow(s, parent: slot, "Nome", "debian-ai", replace: true)
        infoRow(s, parent: slot, "Sistema", "Debian 13 · arm64 · Debian AI Starter")
        infoRow(s, parent: slot, "Risorse", "4 CPU · 4 GiB · disco 64 GiB")
        infoRow(s, parent: slot, "Primo avvio", "Pacchetti essenziali · Guest Tools")
        infoRow(s, parent: slot, "Dopo il primo avvio", "Ollama e il modello llama3.2:1b",
                note: "La VM è usabile prima: l'avanzamento resta visibile nella sua finestra.")
        infoRow(s, parent: slot, "Accesso", "SSH · id_ed25519.pub · rete NAT")
        return refs
    case "modello":
        let (refs, slot) = wizardWindow(s, name, parent: parent, x: x, y: y, mode: mode, step: 2, total: 2,
                                        title: "Riepilogo",
                                        description: "Controlla le scelte: Nido copia debian-ai-base in ricerca-02 e la avvia.",
                                        next: "Crea e avvia")
        infoRow(s, parent: slot, "Nome", "ricerca-02", replace: true)
        infoRow(s, parent: slot, "Modello", "debian-ai-base · Debian AI Starter")
        infoRow(s, parent: slot, "Risorse", "4 CPU · 8 GiB · disco 64 GiB, come il modello")
        infoRow(s, parent: slot, "Spazio sul Mac", "Nessuno in più finché i dischi non cambiano",
                note: "Copia istantanea del disco (clonefile).")
        infoRow(s, parent: slot, "Identità", "Nuova: indirizzo MAC, nome host, chiavi host SSH")
        infoRow(s, parent: slot, "Cartelle condivise e ponte AI", "Nessuna · spento",
                note: "Non passano dal modello alla nuova VM: li scegli tu, dopo.")
        return refs
    case "creazione":
        let (refs, slot) = wizardWindow(s, name, parent: parent, x: x, y: y, mode: mode, nextEnabled: false,
                                        step: 5, title: "Riepilogo", description: description, next: "Crea e avvia")
        progressPanel(s, slot: slot, phase: "creazione", title: "Creazione di debian-13",
                      detail: "Copia del disco (64 GiB) e preparazione di cloud-init", fraction: 0.6)
        return refs
    default:
        let (refs, slot) = wizardWindow(s, name, parent: parent, x: x, y: y, mode: mode, step: 5, title: "Riepilogo",
                                        description: description, next: "Riprova")
        progressPanel(s, slot: slot, phase: "errore", title: "Creazione non riuscita",
                      detail: "Spazio su disco insufficiente: servono 64 GiB, sul Mac ne restano 41 GiB. "
                        + "Libera spazio o riduci il disco al passo Risorse.", fraction: nil)
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
    vmTabs(s, window: w, selected: "Schermo", bridge: false)

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
        s.text("debian-13 resta in memoria dove l'hai lasciata. Riprendi per continuare.", parent: note,
               size: "body", color: "textPrimary",
               props: ["sizingH": "fill", "textAutoResize": "height", "textAlign": "center"])
    default:
        let area = fillArea(s, "Contenuto", parent: w, padding: ["xl"],
                            props: ["mainAlign": "center", "crossAlign": "center"])
        let empty = s.instance(of: s.firstLayerComponent("EmptyState"), parent: area)
        s.set(s.parent(of: s.find("Crea VM", in: empty)), ["visible": false])  // the toolbar has the action
        if state == "stopped" {
            s.setText(s.find("Il nido è vuoto", in: empty), "debian-13 è arrestata")
            s.setText(s.find(emptyStateBody, in: empty),
                      "Ultimo arresto oggi alle 10:42. Avvia la VM dalla barra: il disco e le impostazioni restano come li hai lasciati.")
        } else if state == "suspended" {
            // VMWindowModel.stoppedTitle / stoppedMessage for a VM suspended from this window.
            s.setText(s.find("Il nido è vuoto", in: empty), "debian-13 è sospesa")
            s.setText(s.find(emptyStateBody, in: empty),
                      "Lo stato della VM è salvato sul Mac: Riprendi per continuare da dove l'hai lasciata.")
        } else {
            s.setText(s.find("Il nido è vuoto", in: empty), "Avvio non riuscito")
            s.bind(s.children(of: s.find("Nido", in: empty))[0], "fill", "statusError")
            s.setText(s.find(emptyStateBody, in: empty),
                      "Il disco della VM (disk.img) non è leggibile. Controlla lo spazio libero sul Mac e premi Riprova.")
        }
    }
    return refs
}

let emptyStateBody = "Crea la prima macchina virtuale: Nido scarica Debian 13, ne verifica l'immagine e la prepara in pochi minuti."

/// S11: the VM fills the screen; the toolbar slides in from the top edge (shown here).
func fullScreenWindow(_ s: Script, _ name: String, parent: Int?, x: Double = 0, y: Double = 0, mode: String) -> ScreenRefs {
    let w = window(s, name, parent: parent, x: x, y: y, mode: mode, fullScreen: true)
    _ = console(s, parent: w, lines: consoleLines)
    let bar = s.instance(of: s.variant("VMToolbar", "Stato=running"), parent: w)
    s.set(bar, ["absolute": true, "x": 0, "y": 0, "effects": sheetShadow])
    let exit = s.children(of: bar).last!
    s.setText(s.children(of: exit)[0], "Esci da schermo intero")
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
            s.text("In arrivo", parent: item, size: "caption", color: "textSecondary")
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
    let (w, column) = settingsWindow(s, name, parent: parent, x: x, y: y, mode: mode, title: "Impostazioni di debian-13",
                                     sections: vmSettingsSections, comingSoon: vmSettingsComingSoon, selected: "Hardware",
                                     heading: "Hardware",
                                     intro: "CPU e memoria valgono dal prossimo avvio di debian-13.")
    if running {
        let notice = stack(s, "Avviso", parent: column, "horizontal", gap: "m", padding: ["m", "l"],
                           props: ["sizingH": "fill", "crossAlign": "center"])
        s.bind(notice, "fill", "surfaceRaised")
        s.bind(notice, "cornerRadius", "Radius/m")
        s.stroke(notice, "statusPaused")
        s.instance(of: s.variant("StatusBadge", "Stato=running"), parent: notice)
        s.text("Arresta debian-13 per cambiare CPU e memoria.", parent: notice, size: "body", color: "textPrimary",
               props: ["sizingH": "fill", "textAutoResize": "height"])
        button(s, "secondary", "Arresta", parent: notice)
    }
    let lockedDetail = "Non modificabile mentre debian-13 è in esecuzione"
    let cpu = stepperRow(s, parent: column, label: "CPU",
                         detail: running ? lockedDetail : "Consigliate 2 · al massimo 8 (core di questo Mac)",
                         value: "4", inSlot: false)
    let memory = stepperRow(s, parent: column, label: "Memoria",
                            detail: running ? lockedDetail : "Consigliati 4 GiB · al massimo 12 GiB",
                            value: "8 GiB", inSlot: false)
    if running {
        for row in [cpu, memory] { s.set(row, ["opacity": 0.5]) }
    }
    infoRow(s, parent: column, "Disco", "64 GiB", note: "La dimensione del disco si sceglie alla creazione.",
            inSlot: false)
    let toggle = s.instance(of: s.variant("ToggleRow", running ? "Stato=bloccata" : "Stato=attiva"), parent: column)
    s.set(toggle, ["sizingH": "fill"])
    return ["window": w]
}

func s10Preferences(_ s: Script, _ name: String, parent: Int?, x: Double = 0, y: Double = 0, mode: String) -> ScreenRefs {
    let (w, column) = settingsWindow(s, name, parent: parent, x: x, y: y, mode: mode, title: "Impostazioni di Nido",
                                     sections: appSettingsSections, selected: "Generale", heading: "Generale",
                                     intro: "Nido conserva le VM in una cartella condivisa con il comando nido.")
    let folder = s.instance(of: s.firstLayerComponent("PickerRow"), parent: column)
    s.set(folder, ["sizingH": "fill"])
    s.setText(s.find("Etichetta", in: folder), "Cartella delle VM")
    s.setText(s.find("Percorso", in: folder), "~/Library/Application Support/Nido/VMs · sola lettura")
    s.setText(s.children(of: s.children(of: folder).last!)[0], "Mostra nel Finder")
    infoRow(s, parent: column, "Versione", "Nido 0.2.0", inSlot: false)
    infoRow(s, parent: column, "Licenza", "Apache License 2.0", note: "Nido è software libero: il codice è pubblico.",
            inSlot: false)
    return ["window": w]
}

// MARK: - S08 sections Generale and Condivisione (VMSettingsView)

let vmSettingsSections = ["Generale", "Hardware", "Condivisione", "Guest Tools", "Accesso", "Rete"]
let vmSettingsComingSoon: Set<String> = ["Accesso", "Rete"]

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
    s.setText(s.find("Sincronizza l'ora con il Mac", in: r), title)
    let old = state == "bloccata" ? "Si può cambiare solo a VM arrestata."
        : "Il Mac imposta l'ora della VM a ogni avvio e dopo la pausa."
    s.setText(s.find(old, in: r), explanation)
    if locked && !on { s.set(s.find("Interruttore", in: r), ["opacity": 0.5]) }
    return r
}

/// "Generale": name and MAC address (read-only), and the way to the snapshots (S09).
func s08General(_ s: Script, _ name: String, parent: Int?, x: Double = 0, y: Double = 0, mode: String) -> ScreenRefs {
    let (w, column) = settingsWindow(s, name, parent: parent, x: x, y: y, mode: mode, title: "Impostazioni di debian-13",
                                     sections: vmSettingsSections, comingSoon: vmSettingsComingSoon,
                                     selected: "Generale", heading: "Generale",
                                     intro: "Dati della macchina virtuale, in sola lettura, e i suoi snapshot.")
    infoRow(s, parent: column, "Nome", "debian-13", note: "Il nome si sceglie alla creazione.", inSlot: false)
    infoRow(s, parent: column, "Indirizzo MAC", "52:54:00:3a:9c:12", note: "Assegnato alla creazione della VM.",
            inSlot: false)
    let snapshots = pickerRow(s, parent: column, "Snapshot",
                              "3 snapshot · l'ultimo, dopo-docker, del 24 ott 2026, 16:05", action: "Gestisci snapshot…")
    return ["window": w, "snapshot": s.children(of: snapshots).last!]
}

/// One shared folder: its row (Rimuovi) and the Sola lettura switch under it.
func sharedFolder(_ s: Script, parent: Int, name: String, hostPath: String, readOnly: Bool) {
    // The folder and its switch stay together (xs); groups sit further apart (s + 4).
    let group = stack(s, name, parent: parent, "vertical", gap: "xs", props: ["sizingH": "fill", "paddingBottom": 4])
    pickerRow(s, parent: group, name, "\(hostPath) → /mnt/nido/\(name)", action: "Rimuovi")
    toggleRow(s, parent: group, on: readOnly, "Sola lettura",
              readOnly ? "La VM legge i file ma non può modificarli né cancellarli."
                  : "La VM può modificare e cancellare i file di questa cartella sul Mac: attiva solo se ti serve.")
}

/// "Condivisione": shared folders and Rosetta. `rosettaMissing`: no folders yet, a VM created by
/// an older Nido (one-time guest command), Rosetta not installed on this Mac.
func s08Sharing(_ s: Script, _ name: String, parent: Int?, x: Double = 0, y: Double = 0, mode: String,
                rosettaMissing: Bool, running: Bool = false) -> ScreenRefs {
    let (w, column) = settingsWindow(s, name, parent: parent, x: x, y: y, mode: mode, title: "Impostazioni di debian-13",
                                     sections: vmSettingsSections, comingSoon: vmSettingsComingSoon,
                                     selected: "Condivisione", heading: "Condivisione",
                                     intro: "Cartelle del Mac visibili nella VM in /mnt/nido. Aggiungere o togliere una "
                                        + "cartella e cambiare la sola lettura hanno effetto subito, anche a VM accesa.")
    if running {
        // A change while the VM runs: the share of the session is replaced at once (spec G).
        notice(s, parent: column, inSlot: false, kind: "informazione",
               title: "Ha effetto subito: dataset ora è in sola lettura anche per debian-13 in esecuzione.",
               detail: "I programmi che nella VM scrivevano in /mnt/nido/dataset ricevono un errore di sola lettura.")
    }
    if rosettaMissing {
        infoRow(s, parent: column, "Nessuna cartella condivisa", "",
                note: "La VM non vede alcun file del Mac. Aggiungi una cartella per renderla visibile in /mnt/nido.",
                inSlot: false)
        pickerRow(s, parent: column, "Cartelle condivise: VM creata con una versione precedente di Nido",
                  "Per vedere le cartelle in /mnt/nido, esegui una volta nella VM:\n"
                    + "sudo sh -c 'mkdir -p /etc/systemd/system && printf \"%s\\n\" \"[Unit]\" …'",
                  action: "Copia")
    } else {
        sharedFolder(s, parent: column, name: "progetti", hostPath: "/Users/anna/Progetti", readOnly: true)
        sharedFolder(s, parent: column, name: "dataset", hostPath: "/Volumes/Dati/dataset", readOnly: running)
    }
    let bar = stack(s, "Aggiungi", parent: column, "horizontal", gap: "m", props: ["sizingH": "fill"])
    spacer(s, parent: bar)
    button(s, "primary", "Aggiungi cartella…", parent: bar)
    if rosettaMissing {
        toggleRow(s, parent: column, on: false, locked: true, "Rosetta (binari x86_64)",
                  "Rosetta non è installata su questo Mac. Installala per attivarla.")
        pickerRow(s, parent: column, "Rosetta non è installata su questo Mac",
                  "L'installazione è un componente di sistema di macOS e richiede la tua conferma.",
                  action: "Installa Rosetta…")
    } else {
        toggleRow(s, parent: column, on: true, "Rosetta (binari x86_64)",
                  "La VM esegue i programmi Linux per Intel (x86_64) con Rosetta. Vale dal prossimo avvio.")
    }
    return ["window": w]
}

// MARK: - Snapshots (S09)

/// A snapshot in the list: name, date, whether it holds the memory too.
typealias SnapshotFixture = (name: String, date: String, savedState: Bool)

let snapshotFixtures: [SnapshotFixture] = [
    ("dopo-docker", "24 ott 2026, 16:05", true),
    ("prima-dell-aggiornamento", "24 ott 2026, 10:42", true),
    ("installazione-pulita", "22 ott 2026, 09:15", false),
]

/// S09: the snapshots of one VM, newest first, under the current state (or the progress of a new
/// snapshot, or its error). `phase`: vuoto, elenco, creazione, errore.
func snapshotsWindow(_ s: Script, _ name: String, parent: Int?, x: Double = 0, y: Double = 0, mode: String,
                     phase: String, running: Bool = false, extra: SnapshotFixture? = nil) -> ScreenRefs {
    let w = window(s, name, parent: parent, x: x, y: y, mode: mode)
    let list = (extra.map { [$0] } ?? []) + (phase == "vuoto" ? [] : snapshotFixtures)
    let vmState = running ? "debian-13 in esecuzione" : "debian-13 arrestata"
    _ = toolbar(s, window: w, title: "Snapshot di debian-13",
                subtitle: list.isEmpty ? "Nessuno snapshot · \(vmState)" : "\(list.count) snapshot · \(vmState)")
    var refs: ScreenRefs = ["window": w]

    if phase == "vuoto" {
        let content = fillArea(s, "Contenuto", parent: w, padding: ["xl"],
                               props: ["mainAlign": "center", "crossAlign": "center"])
        let empty = s.instance(of: s.firstLayerComponent("EmptyState"), parent: content)
        s.setText(s.find("Il nido è vuoto", in: empty), "Nessuno snapshot")
        s.setText(s.find(emptyStateBody, in: empty),
                  "Uno snapshot conserva il disco di debian-13 così com'è adesso, e a VM accesa anche la memoria. "
                    + "Potrai tornarci quando vuoi.")
        let label = s.find("Crea VM", in: empty)
        s.setText(label, "Crea snapshot…")
        refs["crea"] = s.parent(of: label)
        return refs
    }

    let content = fillArea(s, "Contenuto", parent: w, padding: ["xl"], props: ["crossAlign": "center"])
    let column = stack(s, "Elenco", parent: content, "vertical", gap: "s", width: 720, props: ["sizingH": "fixed"])
    s.text("Uno snapshot conserva disco e impostazioni della VM; preso a VM accesa, anche la memoria (con stato "
           + "salvato). Ripristinarlo riporta debian-13 a quel momento.",
           parent: column, size: "body", color: "textSecondary",
           props: ["sizingH": "fill", "textAutoResize": "height"])
    let top = stack(s, "Stato attuale", parent: column, "vertical", props: ["sizingH": "fill", "paddingTop": 8,
                                                                            "paddingBottom": 8])
    switch phase {
    case "creazione":
        progressPanel(s, slot: top, phase: "creazione", title: "Creazione di \(extra?.name ?? "snapshot-1")",
                      detail: "debian-13 resta in pausa qualche secondo mentre Nido salva memoria e disco.",
                      fraction: 0.6, inSlot: false, width: 688)
    case "errore":
        let panel = progressPanel(s, slot: top, phase: "errore", title: "Snapshot non riuscito",
                                  detail: "Spazio insufficiente: servono 10 GiB, disponibili 4 GiB. "
                                    + "Libera spazio sul Mac e riprova.",
                                  fraction: nil, inSlot: false, keepActions: true)
        s.setText(s.children(of: s.children(of: s.find("Azioni", in: panel))[0])[0], "Chiudi")
    default:
        let current = s.instance(of: s.variant("SnapshotRow", "Stato=corrente"), parent: top)
        s.set(current, ["sizingH": "fill"])
        if running {
            // The StatusBadge of the running state (a nested variant switch would renumber the row).
            let badge = s.children(of: s.children(of: s.find("Dettagli", in: current))[0])
            s.bind(badge[0], "fill", "statusRunning")
            s.setText(badge[1], "In esecuzione")
        }
        refs["crea"] = s.children(of: s.find("Azioni", in: current))[0]
    }

    s.text(phase == "creazione" ? "Snapshot (\(list.count))" : "Snapshot (\(list.count)), dal più recente",
           parent: column, size: "caption", style: "SemiBold", color: "textSecondary")
    for (index, snapshot) in list.enumerated() {
        let creating = phase == "creazione" && index == 0 && extra != nil
        let row = s.instance(of: s.variant("SnapshotRow", creating ? "Stato=in creazione" : "Stato=normale"),
                             parent: column)
        s.set(row, ["sizingH": "fill"])
        s.setText(s.find("prima-dell-aggiornamento", in: row), snapshot.name)
        if creating { continue }
        s.setText(s.find("24 ott 2026, 10:42", in: row), snapshot.date)
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
        s.text("Per ripristinare uno snapshot arresta prima debian-13.", parent: column, size: "caption",
               color: "textSecondary")
    }
    return refs
}

/// "Crea snapshot…": the name (default snapshot-1), over the list.
func snapshotNameSheet(_ s: Script, _ name: String, parent: Int?, x: Double = 0, y: Double = 0, mode: String,
                       running: Bool = false) -> ScreenRefs {
    var refs = snapshotsWindow(s, name, parent: parent, x: x, y: y, mode: mode, phase: "elenco", running: running)
    let message = running
        ? "debian-13 è in esecuzione: Nido la mette in pausa per qualche secondo e salva anche la memoria."
        : "Nido salva disco e impostazioni di debian-13 così come sono adesso."
    let sheet = formSheet(s, window: refs["window"]!, title: "Crea uno snapshot di debian-13", message: message)
    // The name field and its rule read as one group (xs), apart from the buttons (m).
    let field = stack(s, "Campo", parent: sheet, "vertical", gap: "xs", props: ["sizingH": "fill"])
    infoRow(s, parent: field, "Nome", "snapshot-1", inSlot: false)
    s.text("Lettere, numeri, punto, trattino e trattino basso; diverso dagli altri snapshot di debian-13.",
           parent: field, size: "caption", color: "textSecondary", props: ["sizingH": "fill", "textAutoResize": "height"])
    let (cancel, create) = sheetActions(s, parent: sheet, action: "Crea")
    refs["annulla"] = cancel
    refs["conferma"] = create
    return refs
}

/// Ripristina or Elimina asks first (ConfirmSheet, destructive).
func snapshotConfirmSheet(_ s: Script, _ name: String, parent: Int?, x: Double = 0, y: Double = 0, mode: String,
                          restore: Bool) -> ScreenRefs {
    var refs = snapshotsWindow(s, name, parent: parent, x: x, y: y, mode: mode, phase: "elenco")
    let (cancel, action) = restore
        ? confirmSheet(s, window: refs["window"]!, kind: "eliminazione", title: "Ripristinare prima-dell-aggiornamento?",
                       message: "La VM tornerà allo stato del 24 ott 2026, 10:42; le modifiche successive andranno perse.",
                       action: "Ripristina")
        : confirmSheet(s, window: refs["window"]!, kind: "eliminazione", title: "Eliminare dopo-docker?",
                       message: "Lo snapshot e la memoria salvata con esso saranno eliminati da questo Mac; "
                        + "debian-13 resta com'è. L'operazione non si può annullare.",
                       action: "Elimina")
    refs["annulla"] = cancel
    refs["conferma"] = action
    return refs
}

// MARK: - Clona… (CloneSheet)

func cloneSheet(_ s: Script, _ name: String, parent: Int?, x: Double = 0, y: Double = 0, mode: String,
                copying: Bool) -> ScreenRefs {
    var refs = libraryWindow(s, name, parent: parent, x: x, y: y, mode: mode, withVMs: true)
    let sheet = formSheet(s, window: refs["window"]!, title: "Clonare debian-13?",
                          message: "La copia avrà un nuovo indirizzo di rete e una nuova identità; al primo avvio prende "
                            + "il nuovo nome come nome host. Rosetta viene copiata; cartelle condivise, ponte AI, "
                            + "snapshot e stato sospeso no.")
    let field = infoRow(s, parent: sheet, "Nome", "debian-13-copia", inSlot: false)
    if copying {
        s.set(field, ["opacity": 0.5])
        let progress = stack(s, "Avanzamento", parent: sheet, "vertical", gap: "xs", props: ["sizingH": "fill"])
        s.text("Copia in corso…", parent: progress, size: "caption", color: "textSecondary")
        indeterminateBar(s, parent: progress, width: 392)
    }
    let (cancel, confirm) = sheetActions(s, parent: sheet, action: "Clona", disabled: copying)
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
