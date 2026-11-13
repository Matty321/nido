// SPDX-License-Identifier: Apache-2.0
//
// M3b screens (part of 03-screens.json): macOS VMs from an IPSW. The wizard's macOS path (S02
// with macOS chosen, S03 "Immagine macOS", S04 with the image's minimums, S05 with the macOS user
// name, S06 summary and installation), the library cards "Installazione in corso" and "Occupata",
// the VM window with the guest's screen and the "Accesso da terminale" panel (S07 macOS), and the
// "Clona…" sheet of a macOS VM. Same tokens and components as Screens.swift; one new component
// (TextFieldRow) sits on the board "Componenti delle schermate". The M3c views (Monitor, AI) and
// the provisioning are Linux-only (ruling R4), so the macOS window has no views strip.

import Foundation

/// The guest's screen as VZVirtualMachineView shows it: the VM's own framebuffer, not app UI, so
/// it keeps the same colours in both modes (like the Linux console).
let macScreenFill = "#1D2733"
let macScreenText = "#E3E8EE"
let macScreenCaption = "#9AA5B1"

/// Example names (generic, never a real machine).
let macVM = "macos-agenti"
let macUser = "agente"
let macVersion = "macOS 26.6"
let macIPSW = "UniversalMac_26.6_Restore.ipsw"
/// A made-up public key for the design (not a real one).
let macPublicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHk2Lw9QeXbT4mZr7Vd1cN8sJpFa3uYoG6tRqE0iWzK5 tu@mac"

// MARK: - Components (page Components)

func macScreenComponents(_ s: Script, board: Int) {
    let box = stack(s, "TextFieldRow", parent: board, "vertical", gap: "s", props: ["sizingH": "fill"])
    let head = stack(s, "Titolo", parent: box, "horizontal", gap: "s", props: ["crossAlign": "baseline"])
    s.text("TextFieldRow", parent: head, size: "headline", style: "SemiBold", color: "textPrimary")
    s.text("valore da scrivere, con la sua nota", parent: head, size: "caption", color: "textSecondary")
    // TextFieldRow: the row look of InfoRow with a text field in place of the value.
    let r = stack(s, "TextFieldRow", parent: box, "horizontal", gap: "m", padding: ["m", "l"], width: 512,
                  props: ["sizingH": "fixed", "crossAlign": "center"])
    s.bind(r, "fill", "surface")
    s.bind(r, "cornerRadius", "Radius/m")
    s.stroke(r, "border")
    let labels = stack(s, "Testo", parent: r, "vertical", gap: "xs", props: ["sizingH": "fill"])
    s.text("Etichetta", parent: labels, size: "body", style: "SemiBold", color: "textPrimary")
    s.text("Nota", parent: labels, size: "caption", color: "textSecondary",
           props: ["sizingH": "fill", "textAutoResize": "height"])
    textField(s, parent: r, "valore", width: 160)
    s.makeComponent(r)
}

// MARK: - Small blocks

/// A command in monospace on its own box, with an optional action button: Copia for commands run
/// on the Mac or through `nido ssh` (the Mac's clipboard does not reach a macOS guest), "Digita
/// nella VM" for a command Nido types into the guest's focused window.
@discardableResult
func commandBlock(_ s: Script, parent: Int, _ command: String, action: String?) -> Int {
    let r = stack(s, "Comando", parent: parent, "horizontal", gap: "s", padding: ["s"],
                  props: ["sizingH": "fill", "crossAlign": "center"])
    s.bind(r, "fill", "background")
    s.bind(r, "cornerRadius", "Radius/s")
    s.stroke(r, "border")
    s.text(command, parent: r, size: "caption", color: "textPrimary",
           props: ["fontFamily": consoleFont, "sizingH": "fill", "textAutoResize": "height"])
    if let action { button(s, "secondary", action, parent: r) }
    return r
}

/// A numbered step: the number in an accent disc, a title and a detail. Returns the text column,
/// for a command under it.
@discardableResult
func numberedStep(_ s: Script, parent: Int, _ number: Int, _ title: String, _ detail: String) -> Int {
    let row = stack(s, "Passo \(number)", parent: parent, "horizontal", gap: "s",
                    props: ["sizingH": "fill", "crossAlign": "min"])
    let disc = stack(s, "Numero", parent: row, "horizontal",
                     props: ["mainAlign": "center", "crossAlign": "center", "sizingH": "fixed", "sizingV": "fixed"])
    s.set(disc, ["width": 22, "height": 22, "cornerRadius": 11])
    s.bind(disc, "fill", "accent")
    s.text("\(number)", parent: disc, size: "caption", style: "SemiBold", color: "accentText")
    let texts = stack(s, "Testo", parent: row, "vertical", gap: "xs", props: ["sizingH": "fill"])
    s.text(title, parent: texts, size: "body", style: "SemiBold", color: "textPrimary",
           props: ["sizingH": "fill", "textAutoResize": "height"])
    s.text(detail, parent: texts, size: "caption", color: "textSecondary",
           props: ["sizingH": "fill", "textAutoResize": "height"])
    return texts
}

// MARK: - Library (S01)

/// A VMCard of the macOS screens with its name, system, resources and glyph.
@discardableResult
func macCard(_ s: Script, grid: Int, _ state: String, _ vm: String, system: String, glyph: String,
             _ caption: String = "4 CPU · 8 GiB di memoria · disco 64 GiB", reason: String? = nil) -> Int {
    let c = s.instance(of: s.variant("VMCard", "Stato=\(state)"), parent: grid)
    s.set(c, ["width": 340])
    s.setText(s.find("debian-13", in: c), vm)
    s.setText(s.find("Debian 13 · arm64", in: c), system)
    s.setText(s.find("D", in: c), glyph)
    s.setText(s.find("4 CPU · 8 GiB di memoria · disco 64 GiB", in: c), caption)
    if let reason { s.setText(s.find("Clonazione in corso", in: c), reason) }
    return c
}

/// S01 with macOS VMs: one installing, one busy with its clone, a Linux VM busy with a snapshot.
/// `clone`: nil (the cards), "foglio" (Clona… over a stopped macos-base), "fatto" (the copy is
/// ready, with the steps to run in it).
func macLibrary(_ s: Script, _ name: String, parent: Int?, mode: String, clone: String? = nil) -> ScreenRefs {
    let w = window(s, name, parent: parent, x: 0, y: 0, mode: mode)
    let count = clone == "fatto" ? 6 : 5
    let bar = toolbar(s, window: w, title: "Libreria",
                      subtitle: "\(count) macchine virtuali · 1 in esecuzione · 1 in installazione")
    searchField(s, parent: bar)
    button(s, "secondary", "Nuova VM", parent: bar)
    let content = fillArea(s, "Contenuto", parent: w, padding: ["xl"])
    let grid = stack(s, "Griglia", parent: content, "horizontal", gap: "l",
                     props: ["wrap": true, "crossGap": 16, "sizingH": "fill"])
    // In the app's order (by name). The installing VM has no bundle yet: its card comes from the
    // wizard's installation and stays while the wizard is closed.
    macCard(s, grid: grid, "suspended", "archivio", system: "Debian 13 · arm64", glyph: "D",
            "2 CPU · 4 GiB di memoria · disco 32 GiB")
    macCard(s, grid: grid, clone == nil ? "busy" : "stopped", "debian-13", system: "Debian 13 · arm64", glyph: "D",
            reason: clone == nil ? "Snapshot in corso" : nil)
    macCard(s, grid: grid, "running", macVM, system: macVersion, glyph: "M",
            "4 CPU · 8 GiB di memoria · disco 96 GiB")
    macCard(s, grid: grid, clone == nil ? "busy" : "stopped", "macos-base", system: macVersion, glyph: "M")
    if clone == "fatto" {
        macCard(s, grid: grid, "stopped", "macos-base-copia", system: macVersion, glyph: "M")
    }
    let installing = macCard(s, grid: grid, "installing", "macos-beta", system: "macOS 26.6", glyph: "M")
    s.setText(s.find("Installazione di macOS · 42 % · circa 9 min", in: installing),
              "Installazione di macOS 26.6 · 42 % · circa 9 min")
    var refs: ScreenRefs = ["window": w]

    switch clone {
    case "foglio":
        let sheet = formSheet(s, window: w, title: "Clonare macos-base?",
                              message: "La copia avrà un nuovo indirizzo di rete e un nuovo identificatore della "
                                + "macchina. Cartelle condivise, snapshot e stato sospeso non vengono copiati.")
        notice(s, parent: sheet, inSlot: false, kind: "attenzione",
               title: "Dentro macOS la copia resta uguale a macos-base",
               detail: "Stesso nome del computer, stesso account con le sue chiavi autorizzate, stesse chiavi host "
                + "SSH. Dopo la clonazione Nido ti mostra i comandi per cambiarli nella copia.")
        infoRow(s, parent: sheet, "Nome", "macos-base-copia", inSlot: false)
        let (cancel, confirm) = sheetActions(s, parent: sheet, action: "Clona")
        refs["annulla"] = cancel
        refs["clona"] = confirm
    case "fatto":
        // VMCloner.cloneNotes for macOS: run in the copy, through `nido ssh` (the copy keeps the
        // account and its authorized keys) or in the guest's Terminal.
        let sheet = formSheet(s, window: w, title: "macos-base-copia è pronta",
                              message: "Avviala e cambia la sua identità dentro macOS, con nido ssh macos-base-copia "
                                + "o nel Terminale della VM.")
        groupLabel(s, parent: sheet, "Nuove chiavi host SSH")
        commandBlock(s, parent: sheet, "sudo rm /etc/ssh/ssh_host_* && sudo ssh-keygen -A", action: nil)
        groupLabel(s, parent: sheet, "Nuovo nome del computer")
        commandBlock(s, parent: sheet, "sudo scutil --set ComputerName macos-base-copia\n"
                        + "sudo scutil --set LocalHostName macos-base-copia\n"
                        + "sudo scutil --set HostName macos-base-copia", action: nil)
        let row = stack(s, "Azioni", parent: sheet, "horizontal", gap: "s",
                        props: ["sizingH": "fill", "mainAlign": "max"])
        button(s, "secondary", "Copia i comandi", parent: row)
        button(s, "primary", "Fine", parent: row)
    default:
        break
    }
    return refs
}

// MARK: - Wizard, macOS path (S02–S06)

let macResourcesDescription = "Scegli quanta CPU, memoria e disco del Mac assegnare a \(macVM)."
let macImageDescription = "Scegli il file IPSW di macOS che hai scaricato: Nido controlla che questo Mac possa "
    + "installarlo."

/// S02 with macOS chosen: no profile (Linux only), a word on what macOS VMs do not have.
func s02SystemMac(_ s: Script, _ name: String, parent: Int?, x: Double = 0, y: Double = 0,
                  mode: String) -> ScreenRefs {
    let (refs, slot) = wizardWindow(s, name, parent: parent, x: x, y: y, mode: mode, step: 1, title: "Sistema",
                                    description: "Scegli il sistema della nuova macchina virtuale.")
    let system = s.slotInsert(slot, component: s.variant("SystemChoice", "Selezione=macos"), replace: true)
    s.set(system, ["sizingH": "fill"])
    notice(s, parent: slot, inSlot: true, kind: "informazione",
           title: "Monitor, Guest Tools, Ollama, ponte AI e modelli di VM sono per ora solo per Debian.",
           detail: "Una VM macOS ha schermo, snapshot, sospensione, cloni, cartelle condivise e nido ssh.")
    return refs
}

/// S03 "Immagine macOS": `state` nessuno (no file yet), controllo, compatibile, incompatibile.
func s03Image(_ s: Script, _ name: String, parent: Int?, x: Double = 0, y: Double = 0, mode: String,
              state: String) -> ScreenRefs {
    let ready = state == "compatibile"
    let (refs, slot) = wizardWindow(s, name, parent: parent, x: x, y: y, mode: mode, nextEnabled: ready, step: 2,
                                    title: "Immagine macOS", description: macImageDescription)
    let file = s.slotInsert(slot, component: s.firstLayerComponent("PickerRow"), replace: true)
    s.set(file, ["sizingH": "fill"])
    s.setText(s.find("Etichetta", in: file), "File IPSW")
    let chooser = s.children(of: s.children(of: file).last!)[0]
    switch state {
    case "nessuno":
        s.setText(s.find("Percorso", in: file), "Nessun file scelto")
        notice(s, parent: slot, inSlot: true, kind: "informazione",
               title: "Scarica l'IPSW dal sito sviluppatori di Apple, anche una beta.",
               detail: "Nido lo legge soltanto: non lo scarica, non lo copia, non lo sposta e non lo modifica.")
    case "controllo":
        s.setText(s.find("Percorso", in: file), "~/Downloads/\(macIPSW) · 17,4 GiB")
        s.setText(chooser, "Cambia…")
        let check = progressPanel(s, slot: slot, phase: "verifica", title: "Controllo dell'immagine",
                                  detail: "Nido legge l'IPSW e verifica che questo Mac possa installarlo: di solito "
                                    + "pochi secondi.", fraction: nil, replace: false)
        // A check of unknown length: no bar.
        s.set(s.find("Barra", in: check), ["visible": false])
    case "compatibile":
        s.setText(s.find("Percorso", in: file), "~/Downloads/\(macIPSW) · 17,4 GiB")
        s.setText(chooser, "Cambia…")
        infoRow(s, parent: slot, "Versione", "\(macVersion) (25G62)")
        infoRow(s, parent: slot, "Questo Mac", "Compatibile",
                note: "Virtualization supporta l'immagine e il suo modello hardware.")
        infoRow(s, parent: slot, "Requisiti minimi", "2 CPU · 4 GiB di memoria")
        infoRow(s, parent: slot, "Installazione", "circa 10–20 minuti")
    default:
        s.setText(s.find("Percorso", in: file), "~/Downloads/UniversalMac_27.0_Restore.ipsw · 18,1 GiB")
        s.setText(chooser, "Cambia…")
        // MacRestoreImage.inspect: .restoreImageUnsupported for a newer major version.
        notice(s, parent: slot, inSlot: true, kind: "errore",
               title: "macOS 27.0 non si può installare in una VM su questo Mac: serve un Mac con macOS 27 o "
                + "successivo.",
               detail: "Scegli un IPSW di macOS 26 (anche una beta 26.x). Nido non ha creato alcun file.")
    }
    return refs
}

/// S04 for macOS: the defaults (4 CPU, 8 GiB, 64 GiB) with the image's minimums; `belowMinimum`
/// shows the memory under the minimum, which blocks Avanti.
func s04ResourcesMac(_ s: Script, _ name: String, parent: Int?, x: Double = 0, y: Double = 0, mode: String,
                     belowMinimum: Bool) -> ScreenRefs {
    let (refs, slot) = wizardWindow(s, name, parent: parent, x: x, y: y, mode: mode, nextEnabled: !belowMinimum, step: 3,
                                    title: "Risorse", description: macResourcesDescription)
    stepperRow(s, parent: slot, label: "CPU", detail: "Almeno 2 per \(macVersion) · al massimo 8 (core di questo Mac)",
               value: "4", replace: true)
    if belowMinimum {
        stepperRow(s, parent: slot, state: "fuori limite", label: "Memoria",
                   detail: "\(macVersion) richiede almeno 4 GiB di memoria.", value: "2 GiB")
    } else {
        stepperRow(s, parent: slot, label: "Memoria", detail: "Almeno 4 GiB per \(macVersion) · al massimo 12 GiB",
                   value: "8 GiB")
    }
    stepperRow(s, parent: slot, label: "Disco",
               detail: "Consigliati almeno 40 GiB · spazio libero sul Mac: 412 GiB", value: "64 GiB")
    return refs
}

/// S05 for macOS: the SSH key and the user name of the account created in the setup assistant.
func s05AccessMac(_ s: Script, _ name: String, parent: Int?, x: Double = 0, y: Double = 0,
                  mode: String) -> ScreenRefs {
    let (refs, slot) = wizardWindow(s, name, parent: parent, x: x, y: y, mode: mode, step: 4, title: "Accesso",
                                    description: "Accedi a \(macVM) da terminale con nido ssh e la tua chiave, "
                                        + "senza password.")
    let key = s.slotInsert(slot, component: s.firstLayerComponent("PickerRow"), replace: true)
    s.set(key, ["sizingH": "fill"])
    s.setText(s.find("Etichetta", in: key), "Chiave SSH pubblica")
    s.setText(s.find("Percorso", in: key), "~/.ssh/id_ed25519.pub · ssh-ed25519")
    let user = s.slotInsert(slot, component: s.firstLayerComponent("TextFieldRow"))
    s.set(user, ["sizingH": "fill"])
    s.setText(s.find("Etichetta", in: user), "Nome utente in macOS")
    s.setText(s.find("Nota", in: user), "Il nome breve dell'account che creerai nell'assistente iniziale. "
        + "Serve solo a nido ssh e si può cambiare dopo.")
    s.setText(s.find("valore", in: user), macUser)
    notice(s, parent: slot, inSlot: true, kind: "informazione",
           title: "Nido non chiede né salva password.",
           detail: "Dopo l'assistente iniziale attivi Login remoto in macOS: il pannello Accesso da terminale della "
            + "finestra della VM ti guida.")
    return refs
}

/// S06 for macOS: `phase` riepilogo, installazione, annulla (the confirmation), errore.
func s06Mac(_ s: Script, _ name: String, parent: Int?, x: Double = 0, y: Double = 0, mode: String,
            phase: String) -> ScreenRefs {
    let description = "Controlla le scelte: Nido installa macOS in \(macVM) e la avvia per l'assistente iniziale."
    switch phase {
    case "riepilogo":
        let (refs, slot) = wizardWindow(s, name, parent: parent, x: x, y: y, mode: mode, step: 5, title: "Riepilogo",
                                        description: description, next: "Crea e installa")
        infoRow(s, parent: slot, "Nome", macVM, replace: true)
        infoRow(s, parent: slot, "Sistema", "\(macVersion) · da \(macIPSW)")
        infoRow(s, parent: slot, "Risorse", "4 CPU · 8 GiB · disco 64 GiB")
        infoRow(s, parent: slot, "Accesso", "nido ssh come \(macUser) · id_ed25519.pub")
        infoRow(s, parent: slot, "Rete e cartelle", "NAT · nessuna cartella condivisa")
        infoRow(s, parent: slot, "Installazione", "circa 10–20 minuti",
                note: "Poi completi l'assistente iniziale di macOS nella finestra della VM.")
        return refs
    case "errore":
        let (refs, slot) = wizardWindow(s, name, parent: parent, x: x, y: y, mode: mode, step: 5, title: "Riepilogo",
                                        description: description, next: "Riprova")
        progressPanel(s, slot: slot, phase: "errore", title: "Installazione non riuscita",
                      detail: "Spazio su disco esaurito durante l'installazione: servono 66 GiB, sul Mac ne restano "
                        + "41 GiB. Nido ha cancellato i file creati; l'IPSW resta dov'è.", fraction: nil)
        return refs
    default:
        // Installing: the wizard can close (the library card keeps the progress); Annulla asks first.
        let (refs, slot) = wizardWindow(s, name, parent: parent, x: x, y: y, mode: mode, step: 5, title: "Installazione",
                                        description: "Nido installa \(macVersion) in \(macVM). Puoi chiudere la "
                                            + "procedura: l'avanzamento resta nella libreria.",
                                        next: "Continua nella libreria")
        s.set(refs["indietro"]!, ["visible": false])
        progressPanel(s, slot: slot, phase: "creazione", title: "Installazione di \(macVersion)",
                      detail: "42 % · circa 9 min rimanenti", fraction: 0.42)
        notice(s, parent: slot, inSlot: true, kind: "attenzione",
               title: "Uscire da Nido annulla l'installazione.",
               detail: "Prima di uscire Nido te lo chiede; i file creati vengono cancellati, l'IPSW resta dov'è.")
        if phase == "annulla" {
            let (cancel, _) = confirmSheet(s, window: refs["window"]!, kind: "eliminazione",
                                           title: "Annullare l'installazione di \(macVM)?",
                                           message: "Nido ferma l'installazione e cancella i file creati finora. "
                                            + "L'IPSW resta dov'è.",
                                           action: "Annulla l'installazione")
            s.setText(s.children(of: cancel)[0], "Continua")
        }
        return refs
    }
}

// MARK: - VM window (S07 macOS)

/// S07 for macOS: title bar, VMToolbar with "Accesso da terminale", no views strip (the M3c views
/// are Linux-only), the guest's screen; `panel` opens "Accesso da terminale" beside it.
func macVMWindow(_ s: Script, _ name: String, parent: Int?, x: Double = 0, y: Double = 0, mode: String,
                 panel: Bool) -> ScreenRefs {
    let w = window(s, name, parent: parent, x: x, y: y, mode: mode)
    let titleBar = stack(s, "Barra del titolo", parent: w, "horizontal", padding: ["0", "l"],
                         props: ["sizingH": "fill", "sizingV": "fixed", "crossAlign": "center"])
    s.set(titleBar, ["height": 28])
    s.bind(titleBar, "fill", "surface")
    trafficLights(s, parent: titleBar)
    let bar = s.instance(of: s.variant("VMToolbar", "Stato=running-macos"), parent: w)
    s.set(bar, ["sizingH": "fill"])
    s.setText(s.find("debian-13", in: bar), macVM)
    var refs: ScreenRefs = ["window": w]
    let buttons = Array(s.children(of: bar).dropFirst(3))  // after name, badge and spacer
    for (key, id) in zip(["pausa", "sospendi", "arresta", "snapshot", "accesso", "schermoIntero"], buttons) {
        refs[key] = id
    }

    let body = fillArea(s, "Corpo", parent: w, "horizontal")
    // A placeholder for VZVirtualMachineView: the guest draws here; its resolution follows the window.
    let screen = fillArea(s, "Schermo della VM", parent: body, gap: "s", padding: ["xl"],
                          props: ["fills": [macScreenFill], "mainAlign": "center", "crossAlign": "center"])
    s.plainText("Schermo di macOS", parent: screen, props: ["fontFamily": fontFamily, "fontStyle": "SemiBold",
                                                           "fontSize": 17, "fills": [macScreenText]])
    s.plainText("Qui la VM mostra l'assistente iniziale, poi la scrivania. La risoluzione segue la finestra.",
                parent: screen, props: ["fontFamily": fontFamily, "fontStyle": "Regular", "fontSize": 13,
                                        "fills": [macScreenCaption]])
    guard panel else { return refs }

    let side = stack(s, "Accesso da terminale", parent: body, "vertical", gap: "m", padding: ["l"], width: 384,
                     props: ["sizingH": "fixed", "sizingV": "fill"])
    s.bind(side, "fill", "surface")
    s.stroke(side, "border", props: ["strokeSides": [0, 0, 0, 1]])
    let head = stack(s, "Testa", parent: side, "horizontal", gap: "s", props: ["sizingH": "fill", "crossAlign": "center"])
    s.text("Accesso da terminale", parent: head, size: "headline", style: "SemiBold", color: "textPrimary")
    spacer(s, parent: head)
    refs["chiudi"] = button(s, "secondary", "Chiudi", parent: head)
    s.text("Per usare \(macVM) con nido ssh, una volta sola dopo l'assistente iniziale. Nido non chiede né salva "
           + "password.", parent: side, size: "caption", color: "textSecondary",
           props: ["sizingH": "fill", "textAutoResize": "height"])
    numberedStep(s, parent: side, 1, "Completa l'assistente iniziale",
                 "Crea l'account \(macUser): è il nome che usa nido ssh. Puoi cambiarlo nelle impostazioni della VM.")
    numberedStep(s, parent: side, 2, "Attiva Login remoto",
                 "Nella VM: Impostazioni di Sistema › Generali › Condivisione › Login remoto.")
    let authorize = numberedStep(s, parent: side, 3, "Autorizza la tua chiave",
                                 "Apri il Terminale nella VM, poi Digita nella VM: Nido scrive il comando con la "
                                    + "tua chiave pubblica. Puoi anche digitarlo a mano.")
    commandBlock(s, parent: authorize, "mkdir -p ~/.ssh && chmod 700 ~/.ssh && echo '\(macPublicKey)' "
                    + ">> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys", action: "Digita nella VM")
    let connect = numberedStep(s, parent: side, 4, "Collegati dal Mac", "Nel Terminale del Mac:")
    commandBlock(s, parent: connect, "nido ssh \(macVM)", action: "Copia")
    s.text("Il pannello si apre da solo finché nido ssh non è mai riuscito; poi dalla barra, Accesso da terminale.",
           parent: side, size: "caption", color: "textSecondary", props: ["sizingH": "fill", "textAutoResize": "height"])
    return refs
}

// MARK: - Screens page entries

func macScreenList(_ s: Script) -> [(String, (String, Int?, String) -> ScreenRefs)] {
    [
        ("S01 Libreria · macOS in installazione e occupata", { macLibrary(s, $0, parent: $1, mode: $2) }),
        ("S01 Libreria · Clona macOS", { macLibrary(s, $0, parent: $1, mode: $2, clone: "foglio") }),
        ("S01 Libreria · Clona macOS completata", { macLibrary(s, $0, parent: $1, mode: $2, clone: "fatto") }),
        ("S02 Sistema · macOS", { s02SystemMac(s, $0, parent: $1, mode: $2) }),
        ("S03 Immagine macOS · nessun file", { s03Image(s, $0, parent: $1, mode: $2, state: "nessuno") }),
        ("S03 Immagine macOS · controllo", { s03Image(s, $0, parent: $1, mode: $2, state: "controllo") }),
        ("S03 Immagine macOS · compatibile", { s03Image(s, $0, parent: $1, mode: $2, state: "compatibile") }),
        ("S03 Immagine macOS · non compatibile", {
            s03Image(s, $0, parent: $1, mode: $2, state: "incompatibile") }),
        ("S04 Risorse · macOS", { s04ResourcesMac(s, $0, parent: $1, mode: $2, belowMinimum: false) }),
        ("S04 Risorse · macOS sotto il minimo", {
            s04ResourcesMac(s, $0, parent: $1, mode: $2, belowMinimum: true) }),
        ("S05 Accesso · macOS", { s05AccessMac(s, $0, parent: $1, mode: $2) }),
        ("S06 Riepilogo · macOS", { s06Mac(s, $0, parent: $1, mode: $2, phase: "riepilogo") }),
        ("S06 Installazione macOS · in corso", { s06Mac(s, $0, parent: $1, mode: $2, phase: "installazione") }),
        ("S06 Installazione macOS · conferma annullamento", {
            s06Mac(s, $0, parent: $1, mode: $2, phase: "annulla") }),
        ("S06 Installazione macOS · errore", { s06Mac(s, $0, parent: $1, mode: $2, phase: "errore") }),
        ("S07 Finestra macOS · in esecuzione", { macVMWindow(s, $0, parent: $1, mode: $2, panel: false) }),
        ("S07 Finestra macOS · Accesso da terminale", { macVMWindow(s, $0, parent: $1, mode: $2, panel: true) }),
    ]
}
