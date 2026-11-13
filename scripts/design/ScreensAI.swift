// SPDX-License-Identifier: Apache-2.0
//
// M3c screens (part of 03-screens.json): the VM window's views (Schermo, Monitor, AI), the guest
// monitor (S13), the provisioning progress (S14), the AI section with its Locale and Remoto modes
// (S15), the library's templates, the Hugging Face token in Nido's settings, the Guest Tools of
// an existing VM and live sharing changes. Same tokens and components as Screens.swift; the few
// new components (Avviso, PassoPreparazione, ProfileChoice, TemplateChoice, TemplateCard) sit on
// the board "Componenti delle schermate".

import Foundation

// MARK: - Components (page Components)

func aiScreenComponents(_ s: Script, board: Int) {
    func section(_ title: String, _ note: String) -> Int {
        let box = stack(s, title, parent: board, "vertical", gap: "s", props: ["sizingH": "fill"])
        let head = stack(s, "Titolo", parent: box, "horizontal", gap: "s", props: ["crossAlign": "baseline"])
        s.text(title, parent: head, size: "headline", style: "SemiBold", color: "textPrimary")
        s.text(note, parent: head, size: "caption", color: "textSecondary")
        return box
    }

    // Avviso: a notice inside a view or a form, with an optional action (hidden by default).
    do {
        let box = section("Avviso", "attenzione · errore · informazione: testo, dettaglio e azione facoltativa")
        var variants: [Int] = []
        for (kind, token) in [("attenzione", "statusPaused"), ("errore", "statusError"), ("informazione", "accent")] {
            let r = stack(s, "Tipo=\(kind)", parent: box, "horizontal", gap: "m", padding: ["m", "l"], width: 512,
                          props: ["sizingH": "fixed", "crossAlign": "min"])
            s.bind(r, "fill", "surfaceRaised")
            s.bind(r, "cornerRadius", "Radius/m")
            s.stroke(r, kind == "informazione" ? "border" : token)
            // The dot sits on the first line of the title.
            let mark = stack(s, "Segno", parent: r, "horizontal",
                             props: ["sizingH": "fixed", "sizingV": "fixed", "crossAlign": "center"])
            s.set(mark, ["width": 10, "height": 18])
            let dot = s.ellipse(parent: mark, size: 10)
            s.bind(dot, "fill", token)
            let texts = stack(s, "Testo", parent: r, "vertical", gap: "xs", props: ["sizingH": "fill"])
            s.text("Titolo dell'avviso", parent: texts, size: "body", style: "SemiBold", color: "textPrimary",
                   props: ["sizingH": "fill", "textAutoResize": "height"])
            s.text("Dettaglio dell'avviso", parent: texts, size: "caption", color: "textSecondary",
                   props: ["sizingH": "fill", "textAutoResize": "height"])
            let action = button(s, "secondary", "Azione", parent: r)
            s.set(action, ["visible": false])
            s.makeComponent(r)
            variants.append(r)
        }
        s.combine(variants, name: "Avviso", parent: box)
    }

    // PassoPreparazione: one step of the provisioning (spec C), state in words and colour.
    do {
        let box = section("PassoPreparazione", "passo del provisioning: fatto · in corso · in attesa · non riuscito")
        var variants: [Int] = []
        let states: [(String, String, String)] = [
            ("fatto", "statusRunning", "Fatto"), ("in corso", "accent", "In corso"),
            ("in attesa", "statusStopped", "In attesa"), ("non riuscito", "statusError", "Non riuscito"),
        ]
        for (state, token, label) in states {
            let r = stack(s, "Stato=\(state)", parent: box, "horizontal", gap: "s", width: 360,
                          props: ["sizingH": "fixed", "sizingV": "fixed", "crossAlign": "center"])
            s.set(r, ["height": 24])
            // Shape as well as colour: filled (fatto, non riuscito), a thick ring with a centre (in corso),
            // a thin ring (in attesa). Green and teal alone are too close in dark mode.
            if state == "in corso" {
                let ring = stack(s, "Anello", parent: r, "horizontal",
                                 props: ["mainAlign": "center", "crossAlign": "center", "sizingH": "fixed",
                                         "sizingV": "fixed"])
                s.set(ring, ["width": 12, "height": 12, "cornerRadius": 6])
                s.stroke(ring, token, weight: 2)
                let centre = s.ellipse(parent: ring, size: 4)
                s.bind(centre, "fill", token)
            } else {
                let dot = s.ellipse(parent: r, size: 10)
                if state == "in attesa" {
                    s.set(dot, ["fills": [Any]()])
                    s.stroke(dot, token, weight: 1.5)
                } else {
                    s.bind(dot, "fill", token)
                }
            }
            s.text("Passo", parent: r, size: "body", style: state == "in corso" ? "SemiBold" : "Regular",
                   color: state == "in attesa" ? "textSecondary" : "textPrimary")
            spacer(s, parent: r)
            s.text(label, parent: r, size: "caption", style: state == "non riuscito" ? "SemiBold" : "Regular",
                   color: state == "non riuscito" ? "statusError" : "textSecondary")
            s.makeComponent(r)
            variants.append(r)
        }
        s.combine(variants, name: "PassoPreparazione", parent: box)
    }

    // ProfileChoice: the profile of a new VM, or a template (spec E), as OSTile-like tiles.
    do {
        let box = section("ProfileChoice", "profilo nella procedura: Debian Base · Debian AI Starter · Da modello")
        let profiles: [(String, String, String)] = [
            ("base", "Debian Base", "2 vCPU · 2 GiB · pacchetti essenziali e Guest Tools"),
            ("ai", "Debian AI Starter", "4 vCPU · 4 GiB · disco per Ollama e i modelli"),
            ("modello", "Da modello", "Copia di una VM salvata come modello"),
        ]
        var variants: [Int] = []
        for (selection, _, _) in profiles {
            let c = stack(s, "Selezione=\(selection)", parent: box, "vertical", gap: "s", width: 512,
                          props: ["sizingH": "fixed"])
            // A little more room above the label than below it (it follows SystemChoice in the slot).
            let label = stack(s, "Etichetta", parent: c, "horizontal", props: ["paddingTop": 8])
            s.text("Profilo", parent: label, size: "caption", style: "SemiBold", color: "textSecondary")
            let row = stack(s, "Profili", parent: c, "horizontal", gap: "m", props: ["sizingH": "fill"])
            for (key, title, detail) in profiles {
                let on = key == selection
                // Same height for every tile (a fill height inside a hugging row collapses them).
                let tile = stack(s, title, parent: row, "vertical", gap: "xs", padding: ["m"],
                                 props: ["sizingH": "fill", "sizingV": "fixed"])
                s.set(tile, ["height": 84])
                s.bind(tile, "fill", on ? "surfaceRaised" : "surface")
                s.bind(tile, "cornerRadius", "Radius/m")
                s.stroke(tile, on ? "accent" : "border", weight: on ? 2 : 1)
                s.text(title, parent: tile, size: "body", style: "SemiBold", color: "textPrimary")
                s.text(detail, parent: tile, size: "caption", color: "textSecondary",
                       props: ["sizingH": "fill", "textAutoResize": "height"])
            }
            s.makeComponent(c)
            variants.append(c)
        }
        s.combine(variants, name: "ProfileChoice", parent: box)
    }

    // TemplateChoice: the templates in the wizard's "Da modello" path.
    do {
        let box = section("TemplateChoice", "scelta del modello nella procedura")
        let c = stack(s, "TemplateChoice", parent: box, "vertical", gap: "s", width: 512, props: ["sizingH": "fixed"])
        let templates: [(String, String, Bool)] = [
            ("debian-ai-base", "Debian AI Starter · 4 CPU · 8 GiB · disco 64 GiB · occupa 9,8 GiB", true),
            ("debian-base", "Debian Base · 2 CPU · 2 GiB · disco 32 GiB · occupa 2,4 GiB", false),
        ]
        for (name, detail, on) in templates {
            let r = stack(s, name, parent: c, "horizontal", gap: "m", padding: ["m", "l"],
                          props: ["sizingH": "fill", "crossAlign": "center"])
            s.bind(r, "fill", on ? "surfaceRaised" : "surface")
            s.bind(r, "cornerRadius", "Radius/m")
            s.stroke(r, on ? "accent" : "border", weight: on ? 2 : 1)
            radio(s, parent: r, on: on)
            let texts = stack(s, "Testo", parent: r, "vertical", gap: "xs", props: ["sizingH": "fill"])
            s.text(name, parent: texts, size: "body", style: "SemiBold", color: "textPrimary")
            s.text(detail, parent: texts, size: "caption", color: "textSecondary")
        }
        s.text("La nuova VM è una copia istantanea del modello: nessuno spazio in più finché i dischi non cambiano. "
               + "Ha un'identità nuova e parte senza cartelle condivise e con il ponte AI spento.",
               parent: c, size: "caption", color: "textSecondary", props: ["sizingH": "fill", "textAutoResize": "height"])
        s.makeComponent(c)
    }

    // TemplateCard: a template in the library (spec E): no Avvia, a new VM or an edit instead.
    do {
        let box = section("TemplateCard", "libreria: un modello di VM, che non si avvia")
        let c = stack(s, "TemplateCard", parent: box, "vertical", gap: "m", padding: ["l"], width: 340,
                      props: ["sizingH": "fixed"])
        s.bind(c, "fill", "surface")
        s.bind(c, "cornerRadius", "Radius/m")
        s.stroke(c, "border")
        let top = stack(s, "Intestazione", parent: c, "horizontal", gap: "m",
                        props: ["crossAlign": "center", "sizingH": "fill"])
        let glyph = stack(s, "Sistema", parent: top, "horizontal",
                          props: ["mainAlign": "center", "crossAlign": "center", "sizingH": "fixed", "sizingV": "fixed"])
        s.set(glyph, ["width": 40, "height": 40])
        s.bind(glyph, "fill", "background")
        s.bind(glyph, "cornerRadius", "Radius/s")
        s.stroke(glyph, "border")
        s.text("D", parent: glyph, size: "headline", style: "Bold", color: "accent")
        let names = stack(s, "Nome", parent: top, "vertical", gap: "xs", props: ["sizingH": "fill"])
        s.text("debian-ai-base", parent: names, size: "headline", style: "SemiBold", color: "textPrimary")
        s.text("Debian 13 · Debian AI Starter", parent: names, size: "caption", color: "textSecondary")
        let pill = stack(s, "Modello", parent: top, "horizontal", padding: ["0", "s"],
                         props: ["crossAlign": "center", "sizingV": "fixed"])
        s.set(pill, ["height": 20])
        s.bind(pill, "fill", "background")
        s.bind(pill, "cornerRadius", "Radius/m")
        s.stroke(pill, "border")
        s.text("Modello", parent: pill, size: "caption", style: "SemiBold", color: "textSecondary")
        let details = stack(s, "Dettagli", parent: c, "vertical", gap: "xs", props: ["sizingH": "fill"])
        s.text("4 CPU · 8 GiB di memoria · disco 64 GiB", parent: details, size: "caption", color: "textSecondary")
        s.text("Occupa 9,8 GiB sul Mac", parent: details, size: "caption", color: "textSecondary")
        let row = stack(s, "Azioni", parent: c, "horizontal", gap: "s", props: ["sizingH": "fill"])
        button(s, "primary", "Nuova VM…", parent: row)
        button(s, "secondary", "Modifica modello", parent: row)
        s.makeComponent(c)
    }
}

// MARK: - Small controls

/// A radio button: filled with the accent and a centre when chosen, an outline otherwise.
func radio(_ s: Script, parent: Int, on: Bool) {
    let r = stack(s, "Scelta", parent: parent, "horizontal",
                  props: ["mainAlign": "center", "crossAlign": "center", "sizingH": "fixed", "sizingV": "fixed"])
    s.set(r, ["width": 16, "height": 16, "cornerRadius": 8])
    if on {
        s.bind(r, "fill", "accent")
        let centre = s.ellipse(parent: r, size: 6)
        s.bind(centre, "fill", "accentText")
    } else {
        s.stroke(r, "statusStopped", weight: 1.5)
    }
}

/// A checkbox: an accent square with a centre mark when checked, an outline otherwise.
func checkbox(_ s: Script, parent: Int, on: Bool) {
    let c = s.freeFrame("Casella", parent: parent, x: 0, y: 0, width: 16, height: 16)
    s.set(c, ["cornerRadius": 4])
    if on {
        s.bind(c, "fill", "accent")
        // A drawn check mark (a filled outline), not a glyph.
        let mark = s.vector("Segno", path: "M 3 8.4 L 4.6 6.8 L 6.8 9 L 11.4 4.4 L 13 6 L 6.8 12.2 Z", parent: c,
                            props: ["fills": ["#FFFFFF"]])
        s.bind(mark, "fill", "accentText")
    } else {
        s.stroke(c, "statusStopped", weight: 1.5)
    }
}

/// A switch as in ToggleRow, without its row.
func switchControl(_ s: Script, parent: Int, on: Bool) {
    let track = stack(s, "Interruttore", parent: parent, "horizontal", padding: ["0", "xs"],
                      props: ["mainAlign": on ? "max" : "min", "crossAlign": "center", "sizingH": "fixed",
                              "sizingV": "fixed"])
    s.set(track, ["width": 40, "height": 24, "cornerRadius": 12])
    s.bind(track, "fill", on ? "accent" : "border")
    let knob = s.ellipse(parent: track, size: 16)
    s.bind(knob, "fill", on ? "accentText" : "textSecondary")
}

/// A segmented control; the chosen segment takes the accent, like the selected sidebar row.
func segmented(_ s: Script, parent: Int, _ items: [String], selected: String) {
    let c = stack(s, "Selettore", parent: parent, "horizontal", props: ["crossAlign": "center", "clip": true])
    s.bind(c, "fill", "surfaceRaised")
    s.bind(c, "cornerRadius", "Radius/s")
    s.stroke(c, "border")
    for item in items {
        let on = item == selected
        let seg = stack(s, item, parent: c, "horizontal", padding: ["0", "m"],
                        props: ["mainAlign": "center", "crossAlign": "center", "sizingV": "fixed"])
        s.set(seg, ["height": 24])
        if on { s.bind(seg, "fill", "accent") }
        s.text(item, parent: seg, size: "body", style: on ? "SemiBold" : "Regular",
               color: on ? "accentText" : "textPrimary")
    }
}

/// A text field: a value, a placeholder (secondary text) or an invalid value (error outline).
@discardableResult
func textField(_ s: Script, parent: Int, _ text: String, placeholder: Bool = false, invalid: Bool = false,
               mono: Bool = false, width: Double? = nil) -> Int {
    let f = stack(s, "Campo", parent: parent, "horizontal", padding: ["0", "s"],
                  props: ["crossAlign": "center", "sizingV": "fixed", "sizingH": width == nil ? "fill" : "fixed"])
    s.set(f, ["height": 28])
    if let width { s.set(f, ["width": width]) }
    s.bind(f, "fill", "surfaceRaised")
    s.bind(f, "cornerRadius", "Radius/s")
    s.stroke(f, invalid ? "statusError" : "border", weight: invalid ? 2 : 1)
    s.text(text, parent: f, size: "body", color: placeholder ? "textSecondary" : "textPrimary",
           props: mono ? ["fontFamily": consoleFont] : [:])
    return f
}

/// A determinate bar that fills its parent's width; `width` is that width, for the filled part.
func meter(_ s: Script, parent: Int, fraction: Double, width: Double, token: String = "accent", height: Double = 6) {
    let track = stack(s, "Barra", parent: parent, "horizontal",
                      props: ["sizingH": "fill", "sizingV": "fixed", "clip": true])
    s.set(track, ["height": height, "cornerRadius": height / 2])
    s.bind(track, "fill", "border")
    let bar = s.frame("Avanzamento", parent: track, width: max(height, (width * fraction).rounded()), height: height)
    s.bind(bar, "fill", token)
    s.set(bar, ["cornerRadius": height / 2])
}

/// A small caption heading for a group of rows.
@discardableResult
func groupLabel(_ s: Script, parent: Int, _ text: String, spaceAbove: Bool = false) -> Int {
    guard spaceAbove else {
        return s.text(text, parent: parent, size: "caption", style: "SemiBold", color: "textSecondary")
    }
    // A group after other rows starts a little further away than its rows are from each other.
    let box = stack(s, text, parent: parent, "horizontal", props: ["paddingTop": 8])
    return s.text(text, parent: box, size: "caption", style: "SemiBold", color: "textSecondary")
}

/// An Avviso instance with its texts; `detail` nil hides the second line, `action` shows the button.
@discardableResult
func notice(_ s: Script, parent: Int, inSlot: Bool, kind: String, title: String, detail: String?,
            action: String? = nil) -> Int {
    let component = s.variant("Avviso", "Tipo=\(kind)")
    let n = inSlot ? s.slotInsert(parent, component: component) : s.instance(of: component, parent: parent)
    s.set(n, ["sizingH": "fill"])
    s.setText(s.find("Titolo dell'avviso", in: n), title)
    let line = s.find("Dettaglio dell'avviso", in: n)
    if let detail { s.setText(line, detail) } else { s.set(line, ["visible": false]) }
    if let action {
        let b = s.find("Tipo=secondary", in: n)
        s.set(b, ["visible": true])
        s.setText(s.children(of: b)[0], action)
    }
    return n
}

/// A ToggleRow in the wizard's slot.
func slotToggle(_ s: Script, slot: Int, on: Bool, _ title: String, _ explanation: String) {
    let r = s.slotInsert(slot, component: s.variant("ToggleRow", on ? "Stato=attiva" : "Stato=disattivata"))
    s.set(r, ["sizingH": "fill"])
    s.setText(s.find("Sincronizza l'ora con il Mac", in: r), title)
    s.setText(s.find("Il Mac imposta l'ora della VM a ogni avvio e dopo la pausa.", in: r), explanation)
}

/// A key and its value on one line, with a hairline under it (no box: it sits inside a panel).
func keyValue(_ s: Script, parent: Int, _ key: String, _ value: String, keyWidth: Double = 112, last: Bool = false) {
    let r = stack(s, key, parent: parent, "horizontal", gap: "m", padding: ["xs", "0"],
                  props: ["sizingH": "fill", "crossAlign": "baseline"])
    if !last { s.stroke(r, "border", props: ["strokeSides": [0, 0, 1, 0]]) }
    let k = stack(s, "Chiave", parent: r, "horizontal", width: keyWidth, props: ["sizingH": "fixed"])
    s.text(key, parent: k, size: "caption", color: "textSecondary")
    s.text(value, parent: r, size: "body", color: "textPrimary", props: ["sizingH": "fill", "textAutoResize": "height"])
}

/// A panel inside a view: surface, outline, a headline.
func panel(_ s: Script, parent: Int, _ title: String?, padding: [String] = ["l"], props: JSON = [:]) -> Int {
    var p: JSON = ["sizingH": "fill"]
    p.merge(props) { _, new in new }
    let box = stack(s, title ?? "Pannello", parent: parent, "vertical", gap: "s", padding: padding, props: p)
    s.bind(box, "fill", "surface")
    s.bind(box, "cornerRadius", "Radius/m")
    s.stroke(box, "border")
    if let title { s.text(title, parent: box, size: "headline", style: "SemiBold", color: "textPrimary") }
    return box
}

// MARK: - VM window views

let appSettingsSections = ["Generale", "Hugging Face", "Informazioni"]

/// The views of the VM window under its toolbar; "Ponte AI attivo" at the end when the bridge is on.
func vmTabs(_ s: Script, window w: Int, selected: String, bridge: Bool) {
    let strip = stack(s, "Viste", parent: w, "horizontal", gap: "xl", padding: ["0", "l"],
                      props: ["sizingH": "fill", "sizingV": "fixed", "crossAlign": "center"])
    s.set(strip, ["height": 36])
    s.bind(strip, "fill", "surface")
    s.stroke(strip, "border", props: ["strokeSides": [0, 0, 1, 0]])
    for tab in ["Schermo", "Monitor", "AI"] {
        let on = tab == selected
        // The label, then a 2 pt underline (accent on the chosen view) on the strip's bottom edge.
        let item = stack(s, tab, parent: strip, "vertical", props: ["sizingV": "fill", "crossAlign": "center",
                                                                   "mainAlign": "max", "gap": 8])
        s.text(tab, parent: item, size: "body", style: on ? "SemiBold" : "Regular",
               color: on ? "textPrimary" : "textSecondary")
        let line = s.frame("Sottolineatura", parent: item, width: 20, height: 2, props: ["sizingH": "fill"])
        if on { s.bind(line, "fill", "accent") }
    }
    spacer(s, parent: strip)
    if bridge { bridgePill(s, parent: strip) }
}

/// A VM window of M3c: title bar, VMToolbar in `state`, the views with `tab` chosen.
func aiVMWindow(_ s: Script, _ name: String, parent: Int?, mode: String, state: String, tab: String,
                bridge: Bool, vm: String = "debian-ai") -> Int {
    let w = window(s, name, parent: parent, x: 0, y: 0, mode: mode)
    let titleBar = stack(s, "Barra del titolo", parent: w, "horizontal", padding: ["0", "l"],
                         props: ["sizingH": "fill", "sizingV": "fixed", "crossAlign": "center"])
    s.set(titleBar, ["height": 28])
    s.bind(titleBar, "fill", "surface")
    trafficLights(s, parent: titleBar)
    let bar = s.instance(of: s.variant("VMToolbar", "Stato=\(state)"), parent: w)
    s.set(bar, ["sizingH": "fill"])
    s.setText(s.find("debian-13", in: bar), vm)
    vmTabs(s, window: w, selected: tab, bridge: bridge)
    return w
}

// MARK: - S13 Monitor

/// The monitor of debian-ai in one state of MonitorModel.State:
/// ferma, attesa, valori, avvisi, vecchi, assenti, ultimo, versione, errore.
func monitorScreen(_ s: Script, _ name: String, parent: Int?, mode: String, state: String) -> ScreenRefs {
    let toolbarState: String = switch state {
    case "ferma", "ultimo": "stopped"
    case "attesa": "starting"
    default: "running"
    }
    let w = aiVMWindow(s, name, parent: parent, mode: mode, state: toolbarState, tab: "Monitor",
                       bridge: state == "valori" || state == "avvisi")
    switch state {
    case "ferma", "attesa", "assenti", "versione", "errore":
        monitorMessage(s, window: w, state: state)
    default:
        monitorValues(s, window: w, state: state)
    }
    return ["window": w]
}

/// The states without values: an EmptyState with the model's title, an explanation and the action.
func monitorMessage(_ s: Script, window w: Int, state: String) {
    let area = fillArea(s, "Monitor", parent: w, gap: "l", padding: ["xl"],
                        props: ["mainAlign": "center", "crossAlign": "center"])
    let empty = s.instance(of: s.firstLayerComponent("EmptyState"), parent: area)
    let egg = s.children(of: s.find("Nido", in: empty))[0]
    let label = s.find("Crea VM", in: empty)
    let action = s.parent(of: label)
    let texts: [String: (String, String, String?, String)] = [
        "ferma": ("La VM non è in esecuzione",
                  "Avvia debian-ai per vedere CPU, memoria e disco. Il monitor legge i dati dal guest via vsock, "
                    + "senza passare dalla rete.", nil, "statusStopped"),
        "attesa": ("In attesa del monitor del guest",
                   "debian-ai sta completando l'avvio. Al primo avvio cloud-init installa pacchetti e Guest Tools: "
                    + "possono servire alcuni minuti.", nil, "accent"),
        "assenti": ("Guest Tools non installati",
                    "debian-ai non ha il monitor del guest: è stata creata senza Guest Tools o con una versione di Nido "
                     + "precedente. Nido li installa via SSH senza toccare pacchetti, file e modelli; il monitor "
                     + "risponde dal prossimo riavvio.", "Installa Guest Tools", "statusPaused"),
        "versione": ("Versione dei Guest Tools non riconosciuta",
                     "I Guest Tools di debian-ai rispondono con la versione 3.0, che questa versione di Nido non conosce. "
                      + "Aggiorna Nido, oppure reinstalla i Guest Tools della versione di Nido che usi.",
                     "Reinstalla Guest Tools", "statusPaused"),
        "errore": ("Monitor non raggiungibile",
                   "Nessuna risposta entro 2 secondi. Nido riprova da solo ogni 3 secondi: la VM continua a "
                    + "funzionare normalmente.", "Riprova ora", "statusError"),
    ]
    let (title, body, actionLabel, eggToken) = texts[state]!
    s.setText(s.find("Il nido è vuoto", in: empty), title)
    s.setText(s.find(emptyStateBody, in: empty), body)
    s.bind(egg, "fill", eggToken)
    if let actionLabel { s.setText(label, actionLabel) } else { s.set(action, ["visible": false]) }
    if state == "attesa" {
        let waiting = stack(s, "Attesa", parent: area, "vertical", gap: "s", props: ["crossAlign": "center"])
        indeterminateBar(s, parent: waiting, width: 240)
        s.text("Nido chiede al guest ogni 3 secondi", parent: waiting, size: "caption", color: "textSecondary")
    }
}

/// A measure of the monitor: name, bar with its detail, value. `warning` is the guest's verdict.
func meterRow(_ s: Script, parent: Int, _ label: String, _ sub: String, value: String, fraction: Double?,
              detail: String, warning: String? = nil, old: Bool = false, last: Bool = false) {
    let r = stack(s, label, parent: parent, "horizontal", gap: "l", padding: ["m", "l"],
                  props: ["sizingH": "fill", "crossAlign": "center"])
    if !last { s.stroke(r, "border", props: ["strokeSides": [0, 0, 1, 0]]) }
    let names = stack(s, "Nome", parent: r, "vertical", gap: "xs", width: 112, props: ["sizingH": "fixed"])
    s.text(label, parent: names, size: "body", style: "SemiBold", color: "textPrimary")
    s.text(sub, parent: names, size: "caption", color: "textSecondary")
    let mid = stack(s, "Misura", parent: r, "vertical", gap: "s", props: ["sizingH": "fill"])
    if let fraction {
        meter(s, parent: mid, fraction: fraction, width: 452, token: warning == nil ? "accent" : "statusPaused",
              height: 8)
    }
    let line = stack(s, "Dettaglio", parent: mid, "horizontal", gap: "s", props: ["crossAlign": "center"])
    if let warning {
        let dot = s.ellipse(parent: line, size: 8)
        s.bind(dot, "fill", "statusPaused")
        s.text(warning, parent: line, size: "caption", style: "SemiBold", color: "textPrimary")
    }
    s.text(detail, parent: line, size: "caption", color: "textSecondary", props: ["features": ["tnum": true]])
    let v = stack(s, "Valore", parent: r, "horizontal", width: 80, props: ["sizingH": "fixed", "mainAlign": "max"])
    s.text(value, parent: v, size: "title", style: "SemiBold", color: old ? "textSecondary" : "textPrimary",
           props: ["features": ["tnum": true]])
}

/// The monitor with values: live (valori, avvisi), stale (vecchi) or the last sample (ultimo).
func monitorValues(_ s: Script, window w: Int, state: String) {
    let old = state == "vecchi" || state == "ultimo"
    let area = fillArea(s, "Monitor", parent: w, gap: "l", padding: ["xl"])
    if state == "ultimo" {
        notice(s, parent: area, inSlot: false, kind: "informazione", title: "Ultimo campione prima dell'arresto",
               detail: "debian-ai si è fermata alle 10:44:02 senza che lo chiedessi. Questi sono i valori delle 10:43:58; "
                + "il monitor riparte al prossimo avvio.")
    }
    let head = stack(s, "Stato del monitor", parent: area, "horizontal", gap: "m",
                     props: ["sizingH": "fill", "crossAlign": "center"])
    let caption: String = switch state {
    case "vecchi": "Ultimo campione alle 10:42:18 · nessuna risposta da 14 secondi"
    case "ultimo": "Campione delle 10:43:58 · la VM è arrestata"
    default: "Aggiornato alle 10:42:18 · ogni 3 secondi, solo mentre questa vista è aperta"
    }
    s.text(caption, parent: head, size: "caption", color: "textSecondary", props: ["features": ["tnum": true]])
    spacer(s, parent: head)
    if state != "ultimo" { button(s, "secondary", "Aggiorna", parent: head) }

    let body = stack(s, "Corpo", parent: area, "horizontal", gap: "l", props: ["sizingH": "fill", "crossAlign": "min"])
    let left = stack(s, "Risorse", parent: body, "vertical", props: ["sizingH": "fill", "clip": true])
    s.bind(left, "fill", "surface")
    s.bind(left, "cornerRadius", "Radius/m")
    s.stroke(left, "border")
    let busy = state == "avvisi"
    meterRow(s, parent: left, "CPU", "4 vCPU", value: busy ? "94 %" : "23 %", fraction: busy ? 0.94 : 0.23,
             detail: busy ? "carico medio 1 min 3,86" : "carico medio 1 min 0,92",
             warning: busy ? "CPU elevata" : nil, old: old)
    meterRow(s, parent: left, "Memoria", "3,9 GiB", value: "54 %", fraction: 0.54,
             detail: "2,1 GiB usati · 1,8 GiB disponibili", old: old)
    meterRow(s, parent: left, "Swap", "Non configurata", value: "–", fraction: nil,
             detail: "La VM non ha un'area di swap", old: old)
    meterRow(s, parent: left, "Disco", "31,3 GiB · /", value: busy ? "93 %" : "39 %", fraction: busy ? 0.93 : 0.39,
             detail: busy ? "29,1 GiB usati · 2,2 GiB liberi" : "12,1 GiB usati · 19,2 GiB liberi",
             warning: busy ? "Disco quasi pieno" : nil, old: old, last: true)

    let right = stack(s, "Colonna", parent: body, "vertical", gap: "l", width: 320, props: ["sizingH": "fixed"])
    let alerts = panel(s, parent: right, "Avvisi")
    var items: [String] = []
    if busy { items = ["CPU elevata", "Disco quasi pieno"] }
    if state == "vecchi" { items = ["Dati vecchi: il guest non risponde da più di 10 secondi"] }
    if items.isEmpty {
        s.text(state == "ultimo" ? "Nessun avviso nell'ultimo campione."
                : "Nessun avviso: CPU, memoria e disco sono entro le soglie dei Guest Tools.",
               parent: alerts, size: "caption", color: "textSecondary",
               props: ["sizingH": "fill", "textAutoResize": "height"])
    }
    for item in items {
        let row = stack(s, item, parent: alerts, "horizontal", gap: "s", props: ["sizingH": "fill", "crossAlign": "min"])
        let mark = stack(s, "Segno", parent: row, "horizontal",
                         props: ["sizingH": "fixed", "sizingV": "fixed", "crossAlign": "center"])
        s.set(mark, ["width": 8, "height": 18])
        let dot = s.ellipse(parent: mark, size: 8)
        s.bind(dot, "fill", "statusPaused")
        s.text(item, parent: row, size: "body", color: "textPrimary",
               props: ["sizingH": "fill", "textAutoResize": "height"])
    }
    let system = panel(s, parent: right, "Sistema")
    s.set(system, ["gap": 0])
    keyValue(s, parent: system, "Nome host", "debian-ai")
    keyValue(s, parent: system, "Architettura", "aarch64")
    keyValue(s, parent: system, "Kernel", "6.12.48+deb13-arm64")
    keyValue(s, parent: system, "Acceso da", "2 h 14 min")
    keyValue(s, parent: system, "Guest Tools", "1.0.0 · protocollo 2.0", last: true)
}

// MARK: - S14 Provisioning progress

let cloudInitLines = """
    [  OK  ] Started cloud-init-local.service - Cloud-init: Local Stage.
    [  OK  ] Finished cloud-init-network.service - Cloud-init: Network Stage.
    [   31.402117] cloud-init[612]: Reading package lists...
    [   38.915530] cloud-init[612]: Setting up python3-venv (3.13.5-1) ...
    [   41.208664] cloud-init[612]: Setting up jq (1.7.1-6) ...
    [   44.770391] cloud-init[612]: Unpacking zstd (1.5.7+dfsg-1) ...
    """

/// The provisioning of debian-ai as a panel over the screen, in one phase:
/// fase1, fase2, errore, log, chiave, completata.
func provisioningScreen(_ s: Script, _ name: String, parent: Int?, mode: String, phase: String) -> ScreenRefs {
    let w = aiVMWindow(s, name, parent: parent, mode: mode, state: "running", tab: "Schermo", bridge: false)
    _ = console(s, parent: w, lines: phase == "fase1" ? cloudInitLines
                    : consoleLines.replacingOccurrences(of: "debian-13", with: "debian-ai"))
    let wide = phase == "log"
    let width: Double = wide ? 560 : 400
    let box = stack(s, "Preparazione", parent: w, "vertical", gap: "m", padding: ["l"], width: width,
                    props: ["sizingH": "fixed"])
    s.set(box, ["absolute": true, "x": windowWidth - width - 24, "y": 133, "effects": sheetShadow])
    s.bind(box, "fill", "surfaceRaised")
    s.bind(box, "cornerRadius", "Radius/m")
    s.stroke(box, "border")

    let head = stack(s, "Testa", parent: box, "vertical", gap: "xs", props: ["sizingH": "fill"])
    let (title, subtitle): (String, String) = switch phase {
    case "fase1": ("Preparazione di debian-ai", "Primo avvio: cloud-init prepara il sistema")
    case "completata": ("debian-ai è pronta", "Ollama e llama3.2:1b verificati alle 10:52")
    default: ("Preparazione di debian-ai", "Ollama e il modello scelti alla creazione")
    }
    s.text(title, parent: head, size: "headline", style: "SemiBold", color: "textPrimary")
    s.text(subtitle, parent: head, size: "caption", color: "textSecondary")

    let steps = stack(s, "Passi", parent: box, "vertical", gap: "xs", props: ["sizingH": "fill"])
    func step(_ label: String, _ state: String, status: String? = nil) {
        let r = s.instance(of: s.variant("PassoPreparazione", "Stato=\(state)"), parent: steps)
        s.set(r, ["sizingH": "fill"])
        s.setText(s.find("Passo", in: r), label)
        if let status {
            let old = ["fatto": "Fatto", "in corso": "In corso", "in attesa": "In attesa", "non riuscito": "Non riuscito"]
            s.setText(s.find(old[state]!, in: r), status)
        }
    }
    let model = "Modello llama3.2:1b"
    switch phase {
    case "fase1":
        groupLabel(s, parent: steps, "Fase 1 · primo avvio")
        step("VM creata", "fatto")
        step("Debian avviato", "fatto")
        step("Pacchetti essenziali e Guest Tools", "in corso")
        step("Guest pronto (risponde il monitor)", "in attesa")
        groupLabel(s, parent: steps, "Fase 2 · dopo l'avvio", spaceAbove: true)
        step("Ollama", "in attesa")
        step(model, "in attesa")
        step("Verifica", "in attesa")
    default:
        step("Fase 1 · pacchetti e Guest Tools", "fatto", status: "Fatto alle 10:38")
        groupLabel(s, parent: steps, "Fase 2 · dopo l'avvio", spaceAbove: true)
        switch phase {
        case "fase2":
            step("Ollama", "fatto")
            step(model, "in corso", status: "46 %")
            meter(s, parent: steps, fraction: 0.46, width: width - 32)
            s.text("0,6 GiB di 1,3 GiB · circa 1 min", parent: steps, size: "caption", color: "textSecondary",
                   props: ["features": ["tnum": true]])
            step("Verifica", "in attesa")
        case "chiave":
            step("Ollama", "non riuscito")
            step(model, "in attesa")
            step("Verifica", "in attesa")
        case "completata":
            step("Ollama", "fatto")
            step(model, "fatto", status: "1,3 GiB")
            step("Verifica", "fatto")
        default:  // errore, log
            step("Ollama", "fatto")
            step(model, "non riuscito")
            step("Verifica", "in attesa")
        }
    }

    switch phase {
    case "fase1":
        s.text("debian-ai sarà usabile alla fine della fase 1. Ollama e il modello arrivano dopo, senza bloccarla.",
               parent: box, size: "caption", color: "textSecondary", props: ["sizingH": "fill", "textAutoResize": "height"])
    case "fase2":
        s.text("debian-ai è già pronta: puoi usarla mentre Nido scarica il modello.",
               parent: box, size: "caption", color: "textSecondary", props: ["sizingH": "fill", "textAutoResize": "height"])
    case "errore", "log":
        notice(s, parent: box, inSlot: false, kind: "errore", title: "Download del modello non riuscito",
               detail: "Spazio insufficiente nel disco di debian-ai: servono 1,3 GiB, ne restano 0,8 GiB. Libera spazio "
                + "nella VM e premi Riprova: Nido riprende dal modello, Ollama resta installato.")
    case "chiave":
        notice(s, parent: box, inSlot: false, kind: "errore", title: "Nido non riesce a collegarsi a debian-ai via SSH",
               detail: "La chiave ~/.ssh/id_ed25519 non è disponibile o non è autorizzata nella VM: se ha una passphrase "
                + "aggiungila all'agente (ssh-add) dal Terminale, poi premi Riprova.")
    default:
        s.text("Usa Ollama dalla vista AI, oppure nella VM su 127.0.0.1:11434.",
               parent: box, size: "caption", color: "textSecondary", props: ["sizingH": "fill", "textAutoResize": "height"])
    }
    if wide {
        let log = stack(s, "Log", parent: box, "vertical", padding: ["m"], props: ["sizingH": "fill", "fills": [consoleFill]])
        s.bind(log, "cornerRadius", "Radius/s")
        s.plainText("""
            10:46:02 ollama-install: versione fissata, sha256 verificato
            10:46:09 ollama-install: fatto
            10:46:10 model-pull: llama3.2:1b
            10:47:31 model-pull: 61 % (0,8 GiB di 1,3 GiB)
            10:47:44 model-pull: errore: no space left on device
            10:47:44 model-pull: non riuscito, file parziali rimossi
            """, parent: log, props: ["fontFamily": consoleFont, "fontStyle": "Regular", "fontSize": 12,
                                       "lineHeight": 18, "fills": [consoleText]])
        s.text("/var/log/nido-provision.log in debian-ai · ultime righe, lette via SSH",
               parent: box, size: "caption", color: "textSecondary")
    }
    let row = stack(s, "Azioni", parent: box, "horizontal", gap: "s", props: ["sizingH": "fill", "mainAlign": "max"])
    switch phase {
    case "fase1": button(s, "secondary", "Nascondi", parent: row)
    case "fase2":
        button(s, "secondary", "Mostra log", parent: row)
        button(s, "secondary", "Smetti di attendere", parent: row)
    case "errore":
        button(s, "secondary", "Mostra log", parent: row)
        button(s, "primary", "Riprova", parent: row)
    case "log":
        button(s, "secondary", "Nascondi log", parent: row)
        button(s, "primary", "Riprova", parent: row)
    case "chiave":
        button(s, "secondary", "Riprova", parent: row)
        button(s, "primary", "Apri il Terminale", parent: row)
    default:
        button(s, "secondary", "Chiudi", parent: row)
        button(s, "primary", "Apri la vista AI", parent: row)
    }
    return ["window": w]
}

// MARK: - S15 AI (Locale and Remoto)

/// One of the two modes: a full-height panel with its title, what it means for privacy, and an accessory.
func aiColumn(_ s: Script, parent: Int, _ title: String, _ subtitle: String) -> (column: Int, head: Int) {
    let c = stack(s, title, parent: parent, "vertical", gap: "m", padding: ["l"],
                  props: ["sizingH": "fill", "sizingV": "fill"])
    s.bind(c, "fill", "surface")
    s.bind(c, "cornerRadius", "Radius/l")
    s.stroke(c, "border")
    let head = stack(s, "Testa", parent: c, "horizontal", gap: "m", props: ["sizingH": "fill", "crossAlign": "center"])
    let names = stack(s, "Titoli", parent: head, "vertical", gap: "xs", props: ["sizingH": "fill"])
    s.text(title, parent: names, size: "title", style: "SemiBold", color: "textPrimary")
    s.text(subtitle, parent: names, size: "caption", color: "textSecondary")
    return (c, head)
}

/// A row of a list inside a column: text on the left, controls on the right, a hairline under it.
func listRow(_ s: Script, parent: Int, _ title: String, _ detail: String?, last: Bool = false) -> Int {
    let r = stack(s, title, parent: parent, "horizontal", gap: "m", padding: ["s", "0"],
                  props: ["sizingH": "fill", "crossAlign": "center"])
    if !last { s.stroke(r, "border", props: ["strokeSides": [0, 0, 1, 0]]) }
    let texts = stack(s, "Testo", parent: r, "vertical", gap: "xs", props: ["sizingH": "fill"])
    s.text(title, parent: texts, size: "body", style: "SemiBold", color: "textPrimary")
    if let detail {
        s.text(detail, parent: texts, size: "caption", color: "textSecondary",
               props: ["sizingH": "fill", "textAutoResize": "height"])
    }
    return r
}

/// The Locale mode: assente (Ollama not installed), modelli (with a download), nota (after
/// "Smetti di attendere"), chat (streaming answer).
func localeMode(_ s: Script, parent: Int, state: String) {
    let (c, head) = aiColumn(s, parent: parent, "Locale", "Ollama dentro debian-ai: i testi non escono dal Mac.")
    let badge = s.instance(of: s.variant("StatusBadge", state == "assente" ? "Stato=stopped" : "Stato=running"),
                           parent: head)
    s.setText(s.children(of: badge)[1], state == "assente" ? "Non installato" : "Attivo")
    if state == "assente" {
        s.text("Nido installa Ollama dalle fonti ufficiali, nella versione verificata da Nido, e lo avvia come "
               + "servizio della VM su 127.0.0.1:11434.",
               parent: c, size: "body", color: "textPrimary", props: ["sizingH": "fill", "textAutoResize": "height"])
        s.text("Ollama usa la CPU della VM: Virtualization non offre una GPU ai guest Linux, quindi conviene un "
               + "modello piccolo. Ci vuole qualche minuto; puoi usare la VM nel frattempo.",
               parent: c, size: "caption", color: "textSecondary", props: ["sizingH": "fill", "textAutoResize": "height"])
        let row = stack(s, "Azioni", parent: c, "horizontal", gap: "s")
        button(s, "primary", "Installa Ollama", parent: row)
        return
    }
    let actions = stack(s, "Azioni di Ollama", parent: c, "horizontal", gap: "s", props: ["sizingH": "fill"])
    for label in ["Verifica", "Riavvia", "Ferma", "Aggiorna"] { button(s, "secondary", label, parent: actions) }
    spacer(s, parent: actions)
    button(s, "secondary", "Disinstalla…", parent: actions)
    if state == "nota" {
        notice(s, parent: c, inSlot: false, kind: "informazione",
               title: "Nido ha smesso di attendere: l'operazione continua nella VM e lo stato si aggiorna da solo.",
               detail: nil)
    }
    segmented(s, parent: c, ["Modelli", "Chat"], selected: state == "chat" ? "Chat" : "Modelli")
    if state == "chat" {
        let picker = stack(s, "Modello", parent: c, "horizontal", gap: "s", props: ["sizingH": "fill", "crossAlign": "center"])
        s.text("Modello", parent: picker, size: "caption", style: "SemiBold", color: "textSecondary")
        textField(s, parent: picker, "llama3.2:1b", width: 160)
        let talk = stack(s, "Conversazione", parent: c, "vertical", gap: "m", padding: ["m"],
                         props: ["sizingH": "fill", "sizingV": "fill"])
        s.bind(talk, "fill", "background")
        s.bind(talk, "cornerRadius", "Radius/m")
        let mine = stack(s, "Domanda", parent: talk, "horizontal", props: ["sizingH": "fill", "mainAlign": "max"])
        let bubble = stack(s, "Messaggio", parent: mine, "horizontal", padding: ["s", "m"], width: 300,
                           props: ["sizingH": "fixed"])
        s.bind(bubble, "fill", "accent")
        s.bind(bubble, "cornerRadius", "Radius/m")
        s.text("Riassumi in tre punti cosa fa cloud-init al primo avvio.", parent: bubble, size: "body",
               color: "accentText", props: ["sizingH": "fill", "textAutoResize": "height"])
        let answer = stack(s, "Risposta", parent: talk, "vertical", gap: "xs", props: ["sizingH": "fill"])
        s.text("1. Legge la configurazione dal disco seed (NoCloud).\n2. Crea l'utente, mette la chiave SSH e "
               + "configura la rete.",
               parent: answer, size: "body", color: "textPrimary", props: ["sizingH": "fill", "textAutoResize": "height"])
        // The answer arrives in pieces: the cursor follows the last word.
        let last = stack(s, "Ultima riga", parent: answer, "horizontal", gap: "xs", props: ["crossAlign": "center"])
        s.text("3. Installa i pacchetti richiesti e", parent: last, size: "body", color: "textPrimary")
        let caret = s.frame("Cursore", parent: last, width: 7, height: 15)
        s.bind(caret, "fill", "accent")
        s.text("llama3.2:1b sta rispondendo · sulla CPU di debian-ai", parent: talk, size: "caption",
               color: "textSecondary")
        let input = stack(s, "Scrivi", parent: c, "horizontal", gap: "s", props: ["sizingH": "fill", "crossAlign": "center"])
        textField(s, parent: input, "Scrivi un messaggio", placeholder: true)
        button(s, "secondary", "Interrompi", parent: input)
        s.text("La chat resta in debian-ai: nulla esce dal Mac e Nido non la salva.", parent: c, size: "caption",
               color: "textSecondary")
        return
    }
    let list = stack(s, "Modelli", parent: c, "vertical", props: ["sizingH": "fill"])
    for (model, size) in [("llama3.2:1b", "1,3 GiB"), ("qwen3:1.7b", "1,4 GiB")] {
        let r = listRow(s, parent: list, model, size)
        button(s, "secondary", "Rimuovi…", parent: r)
    }
    if state == "modelli" {
        let r = listRow(s, parent: list, "qwen3:4b", nil, last: true)
        let progress = stack(s, "Avanzamento", parent: s.find("Testo", in: r), "vertical", gap: "xs",
                             props: ["sizingH": "fill"])
        meter(s, parent: progress, fraction: 0.44, width: 300)
        s.text("Download · 1,1 GiB di 2,5 GiB · 44 %", parent: progress, size: "caption", color: "textSecondary",
               props: ["features": ["tnum": true]])
        button(s, "secondary", "Smetti di attendere", parent: r)
    }
    let pull = stack(s, "Scarica", parent: c, "vertical", gap: "xs", props: ["sizingH": "fill"])
    groupLabel(s, parent: pull, "Scarica un modello")
    let field = stack(s, "Riga", parent: pull, "horizontal", gap: "s", props: ["sizingH": "fill", "crossAlign": "center"])
    textField(s, parent: field, "nome:variante, per esempio llama3.2:1b", placeholder: true, mono: false)
    button(s, state == "modelli" ? "disabled" : "primary", "Scarica", parent: field)
    s.text(state == "modelli" ? "Un'operazione alla volta: attendi la fine del download in corso."
            : "Dalla libreria di Ollama. Con 4 GiB di memoria scegli un modello piccolo.",
           parent: pull, size: "caption", color: "textSecondary", props: ["sizingH": "fill", "textAutoResize": "height"])
}

/// The Remoto mode: spento, limiti (models and limits), registro (usage and calls), guasto (the
/// bridge could not start in this session, the Mac has no token).
func remoteMode(_ s: Script, parent: Int, state: String) {
    let on = state != "spento"
    let (c, head) = aiColumn(s, parent: parent, "Remoto",
                             "Hugging Face tramite il ponte di Nido: i testi escono dal Mac.")
    // The VM's policy (the switch); whether the bridge works is the "Ponte AI attivo" indicator.
    s.text(on ? "Acceso" : "Spento", parent: head, size: "body", style: "SemiBold",
           color: on ? "textPrimary" : "textSecondary")
    switchControl(s, parent: head, on: on)
    if state == "spento" {
        s.text("Con il ponte, i programmi di debian-ai usano i modelli di Hugging Face Inference Providers come "
               + "un'API compatibile OpenAI. Il tuo token resta sul Mac: la VM non lo riceve mai.",
               parent: c, size: "body", color: "textPrimary", props: ["sizingH": "fill", "textAutoResize": "height"])
        let facts = stack(s, "Dati", parent: c, "vertical", props: ["sizingH": "fill"])
        keyValue(s, parent: facts, "Token", "Salvato nel Portachiavi del Mac", keyWidth: 120)
        keyValue(s, parent: facts, "Limiti iniziali", "200 000 token al giorno · 20 richieste al minuto", keyWidth: 120)
        keyValue(s, parent: facts, "Registro", "Ora, modello, token ed esito; mai prompt né risposte", keyWidth: 120,
                 last: true)
        s.text("Alla prima attivazione Nido ti mostra cosa esce dal Mac. La modalità Locale resta sempre disponibile.",
               parent: c, size: "caption", color: "textSecondary", props: ["sizingH": "fill", "textAutoResize": "height"])
        let row = stack(s, "Azioni", parent: c, "horizontal", gap: "s")
        button(s, "primary", "Attiva il ponte…", parent: row)
        return
    }
    if state == "guasto" {
        notice(s, parent: c, inSlot: false, kind: "errore", title: "Il ponte AI non è disponibile in questa sessione",
               detail: "Il registro ai-bridge.log della VM non si apre o la VM non ha il dispositivo vsock. Le richieste "
                + "della VM non arrivano a Hugging Face; riavvia la VM per riprovare.")
        notice(s, parent: c, inSlot: false, kind: "attenzione", title: "Manca il token di Hugging Face",
               detail: "Finché manca, le richieste della VM ricevono un errore 401 e nulla esce dal Mac.",
               action: "Apri le Impostazioni")
    }
    segmented(s, parent: c, ["Modelli e limiti", "Uso e registro"],
              selected: state == "registro" ? "Uso e registro" : "Modelli e limiti")
    if state == "registro" {
        let usage = stack(s, "Uso di oggi", parent: c, "vertical", gap: "xs", props: ["sizingH": "fill"])
        groupLabel(s, parent: usage, "Uso di oggi")
        let figures = stack(s, "Cifre", parent: usage, "horizontal", gap: "s", props: ["crossAlign": "baseline"])
        s.text("12 480", parent: figures, size: "title", style: "SemiBold", color: "textPrimary",
               props: ["features": ["tnum": true]])
        s.text("di 200 000 token · si azzera a mezzanotte", parent: figures, size: "caption", color: "textSecondary")
        meter(s, parent: usage, fraction: 0.0624, width: 466)
        let log = stack(s, "Registro", parent: c, "vertical", props: ["sizingH": "fill"])
        groupLabel(s, parent: log, "Ultime chiamate")
        let columns: [(String, Double?)] = [("Ora", 60), ("Modello e provider", nil), ("Token", 80), ("Esito", 96),
                                            ("Durata", 44)]
        func tableRow(_ cells: [String], header: Bool = false, last: Bool = false) {
            let r = stack(s, header ? "Intestazione" : cells[0], parent: log, "horizontal", gap: "s",
                          padding: ["xs", "0"], props: ["sizingH": "fill", "crossAlign": "center"])
            if !last { s.stroke(r, "border", props: ["strokeSides": [0, 0, 1, 0]]) }
            for (index, (_, width)) in columns.enumerated() {
                let cell = stack(s, "Cella", parent: r, "vertical", width: width ?? 100,
                                 props: ["sizingH": width == nil ? "fill" : "fixed",
                                         "crossAlign": index >= 2 && index != 3 ? "max" : "min"])
                let lines = cells[index].split(separator: "\n").map(String.init)
                for (n, line) in lines.enumerated() {
                    // Tabular figures for the numbers only (they space out the hyphens of model ids).
                    s.text(line, parent: cell, size: "caption", style: header ? "SemiBold" : "Regular",
                           color: header || n > 0 ? "textSecondary" : "textPrimary",
                           props: index == 1 ? [:] : ["features": ["tnum": true]])
                }
            }
        }
        tableRow(columns.map(\.0), header: true)
        tableRow(["10:41:07", "Llama-3.1-8B-Instruct\nnebius", "812 / 164", "Riuscita", "1,9 s"])
        tableRow(["10:40:52", "Llama-3.1-8B-Instruct\nnebius", "640 / 211", "Riuscita", "2,4 s"])
        tableRow(["10:40:50", "Llama-3.1-8B-Instruct", "0 / 0", "Oltre il limite", "0,0 s"])
        tableRow(["10:38:15", "Qwen3-Coder-30B-A3B-Instruct\nnovita", "2 104 / 958", "Riuscita", "6,1 s"], last: true)
        s.text("Il registro non contiene mai prompt né risposte.", parent: c, size: "caption", color: "textSecondary")
        return
    }
    let allowed = stack(s, "Modelli consentiti", parent: c, "vertical", props: ["sizingH": "fill"])
    groupLabel(s, parent: allowed, "Modelli consentiti · prezzi dei provider per milione di token, indicativi")
    let models: [(String, String)] = [
        ("meta-llama/Llama-3.1-8B-Instruct", "nebius, novita · contesto 131 072 · 0,02 $ / 0,06 $"),
        ("Qwen/Qwen3-Coder-30B-A3B-Instruct", "novita · contesto 262 144 · 0,10 $ / 0,30 $"),
    ]
    for (index, (id, detail)) in models.enumerated() {
        let r = listRow(s, parent: allowed, id, detail, last: index == models.count - 1)
        button(s, "secondary", "Rimuovi", parent: r)
    }
    if state == "guasto" { return }
    let more = stack(s, "Catalogo", parent: c, "horizontal", props: ["sizingH": "fill"])
    button(s, "secondary", "Scegli dal catalogo…", parent: more)
    let limits = stack(s, "Limiti", parent: c, "vertical", gap: "xs", props: ["sizingH": "fill"])
    groupLabel(s, parent: limits, "Limiti per debian-ai")
    let fields = stack(s, "Campi", parent: limits, "horizontal", gap: "s", props: ["sizingH": "fill"])
    for (label, value) in [("Token al giorno", "200 000"), ("Richieste al minuto", "20"), ("max_tokens", "4 096")] {
        let f = stack(s, label, parent: fields, "vertical", gap: "xs", props: ["sizingH": "fill"])
        s.text(label, parent: f, size: "caption", color: "textSecondary")
        textField(s, parent: f, value)
    }
    let guest = stack(s, "Nella VM", parent: c, "vertical", gap: "xs", props: ["sizingH": "fill"])
    groupLabel(s, parent: guest, "Nella VM, con una chiave API qualsiasi")
    let code = stack(s, "Codice", parent: guest, "horizontal", gap: "s", props: ["sizingH": "fill", "crossAlign": "center"])
    textField(s, parent: code, "OPENAI_BASE_URL=http://127.0.0.1:11435/v1", mono: true)
    button(s, "secondary", "Copia", parent: code)
}

/// S15: the AI view of debian-ai; `sheet` adds one over it: privacy, catalogo, catalogo-errore,
/// rimuovi, disinstalla.
func aiScreen(_ s: Script, _ name: String, parent: Int?, mode: String, locale: String, remote: String,
              sheet: String? = nil) -> ScreenRefs {
    // "Ponte AI attivo" only when the session really has its bridge (AIBridgeModel.isActive):
    // not when the policy is on but the bridge could not attach (guasto).
    let bridge = remote == "limiti" || remote == "registro"
    let w = aiVMWindow(s, name, parent: parent, mode: mode, state: "running", tab: "AI", bridge: bridge)
    let area = fillArea(s, "AI", parent: w, "horizontal", gap: "l", padding: ["xl"])
    localeMode(s, parent: area, state: locale)
    remoteMode(s, parent: area, state: remote)
    switch sheet {
    case "privacy":
        let f = formSheet(s, window: w, title: "Attivare il ponte AI per debian-ai?",
                          message: "Con il ponte attivo, i testi che i programmi della VM inviano al ponte escono dal Mac e "
                            + "arrivano a Hugging Face e al provider che serve il modello, con il tuo token. Nido non "
                            + "registra prompt né risposte, solo modello, token usati ed esito. La modalità Locale "
                            + "(Ollama nella VM) resta sempre disponibile.")
        s.text("Limiti iniziali, modificabili: 200 000 token al giorno, 20 richieste al minuto, max_tokens 4 096.",
               parent: f, size: "caption", color: "textSecondary", props: ["sizingH": "fill", "textAutoResize": "height"])
        sheetActions(s, parent: f, action: "Attiva il ponte")
    case "catalogo", "catalogo-errore":
        catalogSheet(s, window: w, failed: sheet == "catalogo-errore")
    case "rimuovi":
        _ = confirmSheet(s, window: w, kind: "eliminazione", title: "Rimuovere llama3.2:1b da debian-ai?",
                         message: "Il modello (1,3 GiB) viene cancellato dalla VM. Puoi scaricarlo di nuovo quando vuoi.",
                         action: "Rimuovi")
    case "disinstalla":
        let f = formSheet(s, window: w, title: "Disinstallare Ollama da debian-ai?",
                          message: "Nido ferma il servizio e rimuove Ollama dalla VM. I modelli restano, a meno che tu "
                            + "non scelga di cancellarli.")
        toggleRow(s, parent: f, on: false, "Cancella anche i modelli", "llama3.2:1b e qwen3:1.7b: 2,7 GiB nella VM.")
        sheetActions(s, parent: f, action: "Disinstalla", kind: "destructive")
    default:
        break
    }
    return ["window": w]
}

/// The catalog of the router, to choose the allowed models (a wider sheet), or its error.
func catalogSheet(_ s: Script, window w: Int, failed: Bool) {
    addScrim(s, window: w)
    let width = 600.0
    let sheet = stack(s, "Foglio", parent: w, "vertical", gap: "m", padding: ["xl"], width: width,
                      props: ["sizingH": "fixed"])
    s.set(sheet, ["absolute": true, "x": (windowWidth - width) / 2, "y": 64, "effects": sheetShadow])
    s.bind(sheet, "fill", "surfaceRaised")
    s.bind(sheet, "cornerRadius", "Radius/l")
    s.stroke(sheet, "border")
    s.text("Modelli consentiti per debian-ai", parent: sheet, size: "headline", style: "SemiBold", color: "textPrimary")
    s.text("Dal catalogo di Hugging Face Inference Providers. La VM vede solo i modelli scelti; i prezzi sono dei "
           + "provider, per milione di token in ingresso / in uscita, solo indicativi.",
           parent: sheet, size: "body", color: "textSecondary", props: ["sizingH": "fill", "textAutoResize": "height"])
    let tools = stack(s, "Strumenti", parent: sheet, "horizontal", gap: "s", props: ["sizingH": "fill", "crossAlign": "center"])
    textField(s, parent: tools, "Cerca nel catalogo", placeholder: true)
    button(s, failed ? "primary" : "secondary", failed ? "Riprova" : "Aggiorna", parent: tools)
    if failed {
        notice(s, parent: sheet, inSlot: false, kind: "errore",
               title: "Il catalogo dei modelli non è raggiungibile: controlla la connessione del Mac e riprova.",
               detail: "I modelli già consentiti restano validi: la VM continua a usarli.")
    } else {
        s.text("Aggiornato alle 10:12 · 4 di 118 modelli", parent: sheet, size: "caption", color: "textSecondary")
        let list = stack(s, "Catalogo", parent: sheet, "vertical", props: ["sizingH": "fill"])
        let rows: [(String, String, Bool)] = [
            ("meta-llama/Llama-3.1-8B-Instruct", "nebius, novita · contesto 131 072 · 0,02 $ / 0,06 $", true),
            ("Qwen/Qwen3-Coder-30B-A3B-Instruct", "novita · contesto 262 144 · 0,10 $ / 0,30 $", true),
            ("openai/gpt-oss-20b", "groq, together · contesto 131 072 · 0,05 $ / 0,20 $", false),
            ("deepseek-ai/DeepSeek-R1", "fireworks-ai · contesto 163 840 · prezzo non indicato", false),
        ]
        for (index, (id, detail, on)) in rows.enumerated() {
            let r = stack(s, id, parent: list, "horizontal", gap: "m", padding: ["s", "0"],
                          props: ["sizingH": "fill", "crossAlign": "center"])
            if index < rows.count - 1 { s.stroke(r, "border", props: ["strokeSides": [0, 0, 1, 0]]) }
            checkbox(s, parent: r, on: on)
            let texts = stack(s, "Testo", parent: r, "vertical", gap: "xs", props: ["sizingH": "fill"])
            s.text(id, parent: texts, size: "body", style: "SemiBold", color: "textPrimary")
            s.text(detail, parent: texts, size: "caption", color: "textSecondary")
        }
    }
    sheetActions(s, parent: sheet, action: "Salva", disabled: false)
}

// MARK: - Library with templates, settings

/// A section heading of the library, with its caption.
func librarySection(_ s: Script, parent: Int, _ title: String, _ caption: String) {
    let head = stack(s, title, parent: parent, "horizontal", gap: "s", props: ["crossAlign": "baseline"])
    s.text(title, parent: head, size: "headline", style: "SemiBold", color: "textPrimary")
    s.text(caption, parent: head, size: "caption", color: "textSecondary")
}

/// S01 with templates and a VM whose bridge is on; `sheet`: salva, modifica.
func libraryTemplates(_ s: Script, _ name: String, parent: Int?, mode: String, sheet: String? = nil) -> ScreenRefs {
    let w = window(s, name, parent: parent, x: 0, y: 0, mode: mode)
    let bar = toolbar(s, window: w, title: "Libreria", subtitle: "3 macchine virtuali · 2 modelli · 1 in esecuzione")
    searchField(s, parent: bar)
    button(s, "secondary", "Nuova VM", parent: bar)
    let content = fillArea(s, "Contenuto", parent: w, gap: "l", padding: ["xl"])
    librarySection(s, parent: content, "Macchine virtuali", "3")
    let grid = stack(s, "Griglia", parent: content, "horizontal", gap: "l", props: ["sizingH": "fill"])
    func card(_ state: String, _ vm: String, _ caption: String) -> Int {
        let c = s.instance(of: s.variant("VMCard", "Stato=\(state)"), parent: grid)
        s.set(c, ["width": 340])
        s.setText(s.find("debian-13", in: c), vm)
        s.setText(s.find("4 CPU · 8 GiB di memoria · disco 64 GiB", in: c), caption)
        return c
    }
    _ = card("suspended", "archivio", "2 CPU · 4 GiB di memoria · disco 32 GiB")
    let ai = card("running", "debian-ai", "4 CPU · 4 GiB di memoria · disco 64 GiB")
    s.set(s.find("Ponte AI attivo", in: ai), ["visible": true])
    _ = card("stopped", "ricerca-01", "4 CPU · 8 GiB di memoria · disco 64 GiB")
    librarySection(s, parent: content, "Modelli", "2 · 12,2 GiB sul Mac · non si avviano: servono a creare nuove VM")
    let templates = stack(s, "Modelli", parent: content, "horizontal", gap: "l", props: ["sizingH": "fill"])
    _ = s.instance(of: s.firstLayerComponent("TemplateCard"), parent: templates)
    let base = s.instance(of: s.firstLayerComponent("TemplateCard"), parent: templates)
    s.setText(s.find("debian-ai-base", in: base), "debian-base")
    s.setText(s.find("Debian 13 · Debian AI Starter", in: base), "Debian 13 · Debian Base")
    s.setText(s.find("4 CPU · 8 GiB di memoria · disco 64 GiB", in: base), "2 CPU · 2 GiB di memoria · disco 32 GiB")
    s.setText(s.find("Occupa 9,8 GiB sul Mac", in: base), "Occupa 2,4 GiB sul Mac")
    switch sheet {
    case "salva":
        let f = formSheet(s, window: w, title: "Salvare ricerca-01 come modello?",
                          message: "ricerca-01 diventa un modello: non si avvia più e serve a creare nuove VM con una copia "
                            + "istantanea del disco. Per aggiornarlo scegli Modifica modello, poi salvalo di nuovo.")
        notice(s, parent: f, inSlot: false, kind: "informazione",
               title: "Le VM create dal modello partono senza cartelle condivise e con il ponte AI spento.",
               detail: "Ognuna ha un'identità nuova: indirizzo MAC, nome host e chiavi host SSH.")
        sheetActions(s, parent: f, action: "Salva come modello")
    case "modifica":
        _ = confirmSheet(s, window: w, kind: "download", title: "Modificare debian-ai-base?",
                         message: "Il modello torna una VM che puoi avviare e aggiornare. Quando hai finito, salvala di nuovo "
                            + "come modello. Le VM già create dal modello non cambiano.",
                         action: "Modifica modello")
    default:
        break
    }
    return ["window": w]
}

/// S10, section Hugging Face: the Mac's token (assente, salvato, errore), never shown once saved.
func s10HuggingFace(_ s: Script, _ name: String, parent: Int?, mode: String, state: String) -> ScreenRefs {
    let (w, column) = settingsWindow(s, name, parent: parent, x: 0, y: 0, mode: mode, title: "Impostazioni di Nido",
                                     sections: appSettingsSections, selected: "Hugging Face", heading: "Hugging Face",
                                     intro: "Un solo token per tutte le VM, usato solo dal ponte AI verso "
                                        + "router.huggingface.co. Nido lo tiene nel Portachiavi del Mac: non arriva mai "
                                        + "nelle VM, nei log o nei messaggi d'errore.")
    let box = stack(s, "Token", parent: column, "vertical", gap: "s", padding: ["m", "l"], props: ["sizingH": "fill"])
    s.bind(box, "fill", "surface")
    s.bind(box, "cornerRadius", "Radius/m")
    s.stroke(box, "border")
    switch state {
    case "salvato":
        let row = stack(s, "Riga", parent: box, "horizontal", gap: "m", props: ["sizingH": "fill", "crossAlign": "center"])
        let texts = stack(s, "Testo", parent: row, "vertical", gap: "xs", props: ["sizingH": "fill"])
        s.text("Token di accesso", parent: texts, size: "body", style: "SemiBold", color: "textPrimary")
        s.text("Salvato nel Portachiavi. Non si può rivedere: per cambiarlo, incollane uno nuovo.", parent: texts,
               size: "caption", color: "textSecondary", props: ["sizingH": "fill", "textAutoResize": "height"])
        button(s, "secondary", "Sostituisci…", parent: row)
        button(s, "secondary", "Rimuovi", parent: row)
        infoRow(s, parent: column, "VM con il ponte AI attivo", "debian-ai",
                note: "Se rimuovi il token, il ponte risponde 401 nelle VM e nulla esce dal Mac.", inSlot: false)
    default:
        let invalid = state == "errore"
        s.text("Token di accesso", parent: box, size: "body", style: "SemiBold", color: "textPrimary")
        let row = stack(s, "Riga", parent: box, "horizontal", gap: "s", props: ["sizingH": "fill", "crossAlign": "center"])
        textField(s, parent: row, invalid ? "••••••••••••••••••••••••••••" : "hf_…", placeholder: !invalid,
                  invalid: invalid)
        button(s, invalid ? "primary" : "disabled", "Salva", parent: row)
        if invalid {
            s.text("Il token non è valido: incollalo senza spazi interni né caratteri speciali.", parent: box,
                   size: "caption", style: "SemiBold", color: "statusError",
                   props: ["sizingH": "fill", "textAutoResize": "height"])
        }
        s.text("Crea su huggingface.co un token fine-grained con il solo permesso «Make calls to Inference Providers».",
               parent: box, size: "caption", color: "textSecondary", props: ["sizingH": "fill", "textAutoResize": "height"])
    }
    return ["window": w]
}

/// S08, section Guest Tools of a VM created before M3c: install them, apply the anti-hang settings;
/// `manual`: SSH failed and the commands to copy are shown.
func s08GuestTools(_ s: Script, _ name: String, parent: Int?, mode: String, manual: Bool) -> ScreenRefs {
    let (w, column) = settingsWindow(s, name, parent: parent, x: 0, y: 0, mode: mode, title: "Impostazioni di debian-13",
                                     sections: vmSettingsSections, comingSoon: vmSettingsComingSoon,
                                     selected: "Guest Tools", heading: "Guest Tools",
                                     intro: "Il software di Nido dentro la VM: monitor, preparazione di Ollama e ponte AI. "
                                        + "Nido lo installa via SSH con la chiave della VM; pacchetti, file e modelli "
                                        + "restano come sono.")
    if manual {
        notice(s, parent: column, inSlot: false, kind: "errore",
               title: "Installazione automatica non riuscita: debian-13 non risponde via SSH",
               detail: "Controlla che la VM sia accesa e che il servizio ssh sia attivo e premi Riprova, oppure installa "
                + "i Guest Tools a mano con i comandi qui sotto.", action: "Riprova")
        pickerRow(s, parent: column, "Installazione manuale",
                  "Esegui nella VM, come utente con sudo:\nsudo sh -c 'mkdir -p /opt/nido-guest-tools && base64 -d …'",
                  action: "Copia i comandi")
    } else {
        pickerRow(s, parent: column, "Guest Tools non installati",
                  "debian-13 è stata creata con una versione di Nido precedente. Il monitor risponde dal prossimo riavvio.",
                  action: "Installa Guest Tools")
    }
    pickerRow(s, parent: column, "Impostazioni anti-blocco",
              "Se il kernel va in panic, il messaggio compare nel registro della console e la VM si riavvia dopo "
                + "10 secondi invece di restare bloccata. Valgono dal prossimo riavvio.",
              action: "Applica")
    s.text("Servono debian-13 accesa e la sua chiave SSH. Nido non modifica mai una VM da solo.", parent: column,
           size: "caption", color: "textSecondary")
    return ["window": w]
}

// MARK: - Screens page entries

func aiScreenList(_ s: Script) -> [(String, (String, Int?, String) -> ScreenRefs)] {
    var list: [(String, (String, Int?, String) -> ScreenRefs)] = [
        ("S01 Libreria · modelli e ponte attivo", { libraryTemplates(s, $0, parent: $1, mode: $2) }),
        ("S01 Libreria · salva come modello", { libraryTemplates(s, $0, parent: $1, mode: $2, sheet: "salva") }),
        ("S01 Libreria · modifica modello", { libraryTemplates(s, $0, parent: $1, mode: $2, sheet: "modifica") }),
        ("S08 Impostazioni VM · condivisione a VM accesa", {
            s08Sharing(s, $0, parent: $1, mode: $2, rosettaMissing: false, running: true) }),
        ("S08 Impostazioni VM · Guest Tools", { s08GuestTools(s, $0, parent: $1, mode: $2, manual: false) }),
        ("S08 Impostazioni VM · Guest Tools manuale", { s08GuestTools(s, $0, parent: $1, mode: $2, manual: true) }),
        ("S10 Preferenze · token assente", { s10HuggingFace(s, $0, parent: $1, mode: $2, state: "assente") }),
        ("S10 Preferenze · token salvato", { s10HuggingFace(s, $0, parent: $1, mode: $2, state: "salvato") }),
        ("S10 Preferenze · token non valido", { s10HuggingFace(s, $0, parent: $1, mode: $2, state: "errore") }),
    ]
    let monitor: [(String, String)] = [
        ("VM ferma", "ferma"), ("in attesa", "attesa"), ("valori", "valori"), ("avvisi", "avvisi"),
        ("dati vecchi", "vecchi"), ("Guest Tools assenti", "assenti"), ("ultimo campione", "ultimo"),
        ("versione non riconosciuta", "versione"), ("errore", "errore"),
    ]
    for (label, state) in monitor {
        list.append(("S13 Monitor · \(label)", { monitorScreen(s, $0, parent: $1, mode: $2, state: state) }))
    }
    let provisioning: [(String, String)] = [
        ("fase 1", "fase1"), ("fase 2", "fase2"), ("errore", "errore"), ("log", "log"), ("chiave SSH", "chiave"),
        ("completata", "completata"),
    ]
    for (label, phase) in provisioning {
        list.append(("S14 Preparazione · \(label)", { provisioningScreen(s, $0, parent: $1, mode: $2, phase: phase) }))
    }
    let ai: [(String, String, String, String?)] = [
        ("Ollama assente e ponte spento", "assente", "spento", nil),
        ("avviso privacy", "assente", "spento", "privacy"),
        ("modelli e limiti", "modelli", "limiti", nil),
        ("chat e registro", "chat", "registro", nil),
        ("catalogo", "nota", "limiti", "catalogo"),
        ("catalogo non raggiungibile", "nota", "limiti", "catalogo-errore"),
        ("rimuovi modello", "nota", "limiti", "rimuovi"),
        ("disinstalla Ollama", "nota", "limiti", "disinstalla"),
        ("ponte non disponibile", "nota", "guasto", nil),
    ]
    for (label, locale, remote, sheet) in ai {
        list.append(("S15 AI · \(label)", {
            aiScreen(s, $0, parent: $1, mode: $2, locale: locale, remote: remote, sheet: sheet) }))
    }
    return list
}
