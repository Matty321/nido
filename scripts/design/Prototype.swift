// SPDX-License-Identifier: Apache-2.0
//
// Page Prototype (part of 03-screens.json): the screens of F01, F03, F04 and F01 macOS in light mode, built with
// the same functions as page Screens, linked with click and delay interactions and two flows.
//
// F01 (empty library → Debian VM created and running) takes 6 clicks:
//   1 "Crea VM" (S01) · 2 "Avanti" (S02) · 3 "Scarica" (S03) · download and verification run on
//   their own · 4 "Avanti" (S04) · 5 "Avanti" (S05) · 6 "Crea e avvia" (S06) · creation and
//   start run on their own → S07 in esecuzione.
//
// F01 macOS (empty library → macOS installed and running, at its setup assistant) takes 6 clicks:
//   1 "Crea VM" (S01) · 2 the macOS tile (S02: it chooses macOS and opens the IPSW panel; the file
//   is picked in the system's open panel) · the check runs on its own · 3 "Avanti" (S03 Immagine
//   macOS, compatibile) · 4 "Avanti" (S04) · 5 "Avanti" (S05, after typing the user name) ·
//   6 "Crea e installa" (S06) · the installation runs on its own → S07 macOS with the
//   "Accesso da terminale" panel (first boot).

import Foundation

/// Delays of the steps that need no click (download, verification, creation, boot), in ms.
let autoStepDelay = 1800

func prototypePage(_ s: Script) {
    s.page("Prototype")
    let mode = "Chiaro"
    let pitch = windowWidth + 120
    func at(_ column: Int) -> Double { Double(column) * pitch }
    let row2 = windowHeight + 200

    // F01: first row.
    let library = libraryWindow(s, "F01 · 1 S01 Libreria vuota", parent: nil, x: at(0), y: 0, mode: mode, withVMs: false)
    let system = s02System(s, "F01 · 2 S02 Sistema", parent: nil, x: at(1), y: 0, mode: mode)
    let confirm = s03Confirm(s, "F01 · 3 S03 Conferma download", parent: nil, x: at(2), y: 0, mode: mode)
    let download = s03Progress(s, "F01 · 4 S03 Download", parent: nil, x: at(3), y: 0, mode: mode, phase: "download")
    let verify = s03Progress(s, "F01 · 5 S03 Verifica", parent: nil, x: at(4), y: 0, mode: mode, phase: "verifica")
    let resources = s04Resources(s, "F01 · 6 S04 Risorse", parent: nil, x: at(5), y: 0, mode: mode, overLimit: false)
    let access = s05Access(s, "F01 · 7 S05 Accesso", parent: nil, x: at(6), y: 0, mode: mode)
    let summary = s06Summary(s, "F01 · 8 S06 Riepilogo", parent: nil, x: at(7), y: 0, mode: mode, phase: "riepilogo")
    let creating = s06Summary(s, "F01 · 9 S06 Creazione", parent: nil, x: at(8), y: 0, mode: mode, phase: "creazione")

    // F03: second row (F01 ends here too, on the VM window).
    let vms = libraryWindow(s, "F03 · 1 S01 Libreria", parent: nil, x: at(0), y: row2, mode: mode, withVMs: true)
    let starting = vmWindow(s, "F03 · 2 S07 Avvio", parent: nil, x: at(1), y: row2, mode: mode, state: "starting")
    let running = vmWindow(s, "F03 · 3 S07 In esecuzione", parent: nil, x: at(2), y: row2, mode: mode, state: "running")
    let paused = vmWindow(s, "F03 · 4 S07 In pausa", parent: nil, x: at(3), y: row2, mode: mode, state: "paused")
    let stopped = vmWindow(s, "F03 · 5 S07 Arrestata", parent: nil, x: at(4), y: row2, mode: mode, state: "stopped")
    let suspended = vmWindow(s, "F03 · 6 S07 Sospesa", parent: nil, x: at(5), y: row2, mode: mode, state: "suspended")

    // F04: third row, the snapshots of the VM (S09), from the VM window's Snapshot button.
    let row3 = 2 * row2
    let list = snapshotsWindow(s, "F04 · 1 S09 Snapshot", parent: nil, x: at(0), y: row3, mode: mode,
                               phase: "elenco", running: true)
    let naming = snapshotNameSheet(s, "F04 · 2 S09 Nuovo snapshot", parent: nil, x: at(1), y: row3, mode: mode,
                                   running: true)
    let creatingSnapshot = snapshotsWindow(s, "F04 · 3 S09 Creazione", parent: nil, x: at(2), y: row3, mode: mode,
                                           phase: "creazione", running: true, extra: ("snapshot-1", "", true))
    let created = snapshotsWindow(s, "F04 · 4 S09 Snapshot creato", parent: nil, x: at(3), y: row3, mode: mode,
                                  phase: "elenco", running: true, extra: ("snapshot-1", "24 ott 2026, 17:30", true))
    let stoppedList = snapshotsWindow(s, "F04 · 5 S09 Snapshot a VM arrestata", parent: nil, x: at(4), y: row3,
                                      mode: mode, phase: "elenco")
    let restoring = snapshotConfirmSheet(s, "F04 · 6 S09 Conferma ripristino", parent: nil, x: at(5), y: row3,
                                         mode: mode, restore: true)

    // F01 macOS: fourth row.
    let row4 = 3 * row2
    let macLibraryEmpty = libraryWindow(s, "F01 macOS · 1 S01 Libreria vuota", parent: nil, x: at(0), y: row4,
                                        mode: mode, withVMs: false)
    let macSystem = s02System(s, "F01 macOS · 2 S02 Sistema", parent: nil, x: at(1), y: row4, mode: mode)
    let macCheck = s03Image(s, "F01 macOS · 3 S03 Controllo dell'immagine", parent: nil, x: at(2), y: row4,
                            mode: mode, state: "controllo")
    let macImage = s03Image(s, "F01 macOS · 4 S03 Immagine compatibile", parent: nil, x: at(3), y: row4,
                            mode: mode, state: "compatibile")
    let macResources = s04ResourcesMac(s, "F01 macOS · 5 S04 Risorse", parent: nil, x: at(4), y: row4, mode: mode,
                                       belowMinimum: false)
    let macAccess = s05AccessMac(s, "F01 macOS · 6 S05 Accesso", parent: nil, x: at(5), y: row4, mode: mode)
    let macSummary = s06Mac(s, "F01 macOS · 7 S06 Riepilogo", parent: nil, x: at(6), y: row4, mode: mode,
                            phase: "riepilogo")
    let macInstalling = s06Mac(s, "F01 macOS · 8 S06 Installazione", parent: nil, x: at(7), y: row4, mode: mode,
                               phase: "installazione")
    let macFirstBoot = macVMWindow(s, "F01 macOS · 9 S07 macOS in esecuzione", parent: nil, x: at(8), y: row4,
                                   mode: mode, panel: true)
    let macScreen = macVMWindow(s, "F01 macOS · 10 S07 macOS senza pannello", parent: nil, x: at(9), y: row4,
                                mode: mode, panel: false)

    func window(_ refs: ScreenRefs) -> Int { refs["window"]! }

    // F01 happy path: 6 clicks.
    s.navigate(from: library["crea"]!, to: window(system))                  // click 1
    s.navigate(from: library["nuova"]!, to: window(system))                 // same step from the toolbar
    s.navigate(from: system["avanti"]!, to: window(confirm))                // click 2
    s.navigate(from: confirm["avanti"]!, to: window(download))              // click 3: "Scarica"
    s.navigate(from: window(download), to: window(verify), afterDelay: autoStepDelay)
    s.navigate(from: window(verify), to: window(resources), afterDelay: autoStepDelay)
    s.navigate(from: resources["avanti"]!, to: window(access))              // click 4
    s.navigate(from: access["avanti"]!, to: window(summary))                // click 5
    s.navigate(from: summary["avanti"]!, to: window(creating))              // click 6: "Crea e avvia"
    s.navigate(from: window(creating), to: window(starting), afterDelay: autoStepDelay)

    // F01 side paths: back one step, or cancel to the library.
    s.navigate(from: confirm["indietro"]!, to: window(system))
    s.navigate(from: resources["indietro"]!, to: window(confirm))
    s.navigate(from: access["indietro"]!, to: window(resources))
    s.navigate(from: summary["indietro"]!, to: window(access))
    for refs in [system, confirm, download, verify, resources, access, summary] {
        s.navigate(from: refs["annulla"]!, to: window(library))
    }

    // F03: start, pause, resume, stop.
    s.navigate(from: vms["avvia"]!, to: window(starting))
    s.navigate(from: window(starting), to: window(running), afterDelay: autoStepDelay)
    s.navigate(from: starting["arresta"]!, to: window(stopped))
    s.navigate(from: running["pausa"]!, to: window(paused))
    s.navigate(from: running["arresta"]!, to: window(stopped))
    s.navigate(from: paused["riprendi"]!, to: window(running))
    s.navigate(from: paused["arresta"]!, to: window(stopped))
    s.navigate(from: stopped["avvia"]!, to: window(starting))
    // Sospendi saves the state; Riprendi continues from it.
    s.navigate(from: running["sospendi"]!, to: window(suspended))
    s.navigate(from: suspended["riprendi"]!, to: window(running))

    // F04: create a snapshot of the running VM; restore one once it is stopped (the snapshot
    // holds the memory too, so the VM comes back suspended).
    s.navigate(from: running["snapshot"]!, to: window(list))
    s.navigate(from: list["crea"]!, to: window(naming))
    s.navigate(from: naming["annulla"]!, to: window(list))
    s.navigate(from: naming["conferma"]!, to: window(creatingSnapshot))
    s.navigate(from: window(creatingSnapshot), to: window(created), afterDelay: autoStepDelay)
    s.navigate(from: stopped["snapshot"]!, to: window(stoppedList))
    s.navigate(from: suspended["snapshot"]!, to: window(stoppedList))
    s.navigate(from: stoppedList["ripristina-prima-dell-aggiornamento"]!, to: window(restoring))
    s.navigate(from: restoring["annulla"]!, to: window(stoppedList))
    s.navigate(from: restoring["conferma"]!, to: window(suspended))

    // F01 macOS happy path: 6 clicks.
    s.navigate(from: macLibraryEmpty["crea"]!, to: window(macSystem))                       // click 1
    s.navigate(from: macLibraryEmpty["nuova"]!, to: window(macSystem))
    s.navigate(from: macSystem["macos"]!, to: window(macCheck))                            // click 2: macOS
    s.navigate(from: window(macCheck), to: window(macImage), afterDelay: autoStepDelay)
    s.navigate(from: macImage["avanti"]!, to: window(macResources))                        // click 3
    s.navigate(from: macResources["avanti"]!, to: window(macAccess))                       // click 4
    s.navigate(from: macAccess["avanti"]!, to: window(macSummary))                         // click 5
    s.navigate(from: macSummary["avanti"]!, to: window(macInstalling))                     // click 6
    s.navigate(from: window(macInstalling), to: window(macFirstBoot), afterDelay: autoStepDelay)
    // The panel closes, and opens again from the toolbar.
    s.navigate(from: macFirstBoot["chiudi"]!, to: window(macScreen))
    s.navigate(from: macScreen["accesso"]!, to: window(macFirstBoot))
    // Side paths: back one step, or cancel to the library.
    s.navigate(from: macImage["indietro"]!, to: window(macSystem))
    s.navigate(from: macResources["indietro"]!, to: window(macImage))
    s.navigate(from: macAccess["indietro"]!, to: window(macResources))
    s.navigate(from: macSummary["indietro"]!, to: window(macAccess))
    for refs in [macSystem, macCheck, macImage, macResources, macAccess, macSummary] {
        s.navigate(from: refs["annulla"]!, to: window(macLibraryEmpty))
    }

    s.flow(start: window(library), name: "F01 · Crea una VM Debian")
    s.flow(start: window(vms), name: "F03 · Avvia, metti in pausa, riprendi, arresta")
    s.flow(start: window(list), name: "F04 · Crea e ripristina uno snapshot")
    s.flow(start: window(macLibraryEmpty), name: "F01 macOS · Crea una VM macOS da un IPSW")
}

/// `--count-clicks <03-screens.json>`: the fewest clicks from the start of F01 to the running VM
/// window, for F01 and F01 macOS, reading the interactions of page Prototype (delays cost
/// nothing). Prints the paths; exits 1 when one is above the 6-click goal.
func countClicks(scriptPath: String) -> Never {
    guard let data = FileManager.default.contents(atPath: scriptPath),
          let steps = try? JSONSerialization.jsonObject(with: data) as? [JSON],
          let start = steps.firstIndex(where: { $0["command"] as? String == "page.add"
              && ($0["params"] as? JSON)?["name"] as? String == "Prototype" })
    else {
        FileHandle.standardError.write(Data("Impossibile leggere la pagina Prototype in \(scriptPath)\n".utf8))
        exit(2)
    }
    var frames: [Int: String] = [:]  // top-level frames of the page, by id
    var edges: [Int: [(clicks: Int, to: Int, label: String)]] = [:]
    var frameOf: (Int) -> Int = { _ in 0 }
    for step in steps[start...] {
        let params = step["params"] as? JSON ?? [:]
        if step["command"] as? String == "frame.create", params["parent"] == nil, let id = step["expectId"] as? Int {
            frames[id] = params["name"] as? String ?? "?"
            frameOf = { node in frames.keys.filter { $0 <= node }.max() ?? 0 }
        }
        if step["command"] as? String == "proto.interaction.add", let node = params["id"] as? Int,
           let action = params["action"] as? JSON, let dest = action["dest"] as? Int,
           let trigger = (params["trigger"] as? JSON)?["type"] as? String {
            let click = trigger == "onClick"
            edges[frameOf(node), default: []].append((click ? 1 : 0, dest, click ? "clic sul livello \(node)" : "attesa"))
        }
    }
    // F01 (Debian) and F01 macOS: each must reach its running VM window within 6 clicks.
    let paths: [(String, String, String)] = [
        ("F01", "F01 · 1 ", "S07 In esecuzione"),
        ("F01 macOS", "F01 macOS · 1 ", "S07 macOS in esecuzione"),
    ]
    var withinBudget = true
    for (label, startPrefix, goalSuffix) in paths {
        guard let first = frames.first(where: { $0.value.hasPrefix(startPrefix) })?.key,
              let goal = frames.first(where: { $0.value.hasSuffix(goalSuffix) })?.key
        else {
            FileHandle.standardError.write(Data("Frame di \(label) non trovati\n".utf8))
            exit(2)
        }
        // Dijkstra on 0/1 weights.
        var best: [Int: (Int, [String])] = [first: (0, [])]
        var queue = [first]
        while !queue.isEmpty {
            queue.sort { best[$0]!.0 < best[$1]!.0 }
            let frame = queue.removeFirst()
            let (clicks, path) = best[frame]!
            for edge in edges[frame] ?? [] {
                let total = clicks + edge.clicks
                if best[edge.to].map({ total < $0.0 }) ?? true {
                    best[edge.to] = (total, path + ["\(frames[frame]!) → \(frames[edge.to] ?? "?") (\(edge.label))"])
                    queue.append(edge.to)
                }
            }
        }
        guard let (clicks, path) = best[goal] else {
            print("\(label): la finestra della VM in esecuzione non si raggiunge dal prototipo.")
            withinBudget = false
            continue
        }
        print("\(label): \(clicks) clic (obiettivo ≤ 6)")
        for line in path { print("  \(line)") }
        if clicks > 6 { withinBudget = false }
    }
    exit(withinBudget ? 0 : 1)
}
