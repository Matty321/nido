// SPDX-License-Identifier: Apache-2.0
//
// Script builder shared by every FigCraft script of Nido: it tracks the positional layer ids
// FigCraft hands out in a fresh headless session (the page is 1; every created layer takes the
// next id; an instance takes one id per layer of its main component, in pre-order;
// `component.create` keeps the frame's id; `component.combineVariants` takes a new id for the
// set; a file opened with `--in` continues after its highest id), so the generated JSON stays
// consistent. Content lives in Tokens.swift, Components.swift, Screens.swift, Prototype.swift
// and Icon.swift; main.swift writes the files. design/scripts/README.md has the details.

import Foundation

// MARK: - Script builder

typealias JSON = [String: Any]

final class Script {
    private(set) var steps: [JSON] = []
    private var nextID: Int
    private var children: [Int: [Int]] = [:]
    private var parentOf: [Int: Int] = [:]
    /// Layer names as FigCraft sets them at creation (a text layer is named after its text);
    /// instance copies take the names of their main component's layers.
    private var names: [Int: String] = [:]
    /// Text layers (a section title can share its name with the component below it).
    private var texts: Set<Int> = []
    private(set) var maxID: Int

    init(firstID: Int) {
        nextID = firstID
        maxID = firstID - 1
    }

    /// A script for the next file in the chain (run with `--in` on the previous one's output):
    /// it starts after the highest id and still knows every layer, so it can instance components
    /// and find the copies of their layers.
    init(continuing previous: Script) {
        nextID = previous.maxID + 1
        maxID = previous.maxID
        children = previous.children
        parentOf = previous.parentOf
        names = previous.names
        texts = previous.texts
    }

    func step(_ command: String, _ params: JSON = [:]) {
        steps.append(["command": command, "params": params])
    }

    /// Records on the last step the id FigCraft must return for it (checked by --verify).
    private func expect(_ id: Int) {
        steps[steps.count - 1]["expectId"] = id
    }

    /// Records the variable or collection id (e.g. "VariableID:3") the last step must return.
    func expectVariableID(_ id: String) {
        steps[steps.count - 1]["expectId"] = id
    }

    /// Reserves the id of a page created by `page.add`.
    func page(_ name: String) {
        step("page.add", ["name": name])
        let id = nextID
        nextID += 1
        maxID = id
        names[id] = name
        expect(id)
    }

    /// Makes an existing page the current one: layers created without a parent go there.
    func selectPage(_ id: Int) {
        step("page.select", ["id": id])
    }

    private func allocate(parent: Int?, name: String? = nil) -> Int {
        let id = nextID
        nextID += 1
        maxID = id
        if let name { names[id] = name }
        if let parent {
            children[parent, default: []].append(id)
            parentOf[id] = parent
        }
        return id
    }

    /// Ids of the subtree rooted at `id`, in pre-order (the order instances copy it in).
    func preorder(_ id: Int) -> [Int] {
        [id] + (children[id] ?? []).flatMap { preorder($0) }
    }

    /// Reserves ids for a copy of `source` (an instance) under `parent`, keeping its shape.
    private func copySubtree(of source: Int, parent: Int?) -> Int {
        let id = allocate(parent: parent, name: names[source])
        if texts.contains(source) { texts.insert(id) }
        for child in children[source] ?? [] { _ = copySubtree(of: child, parent: id) }
        return id
    }

    // Layers

    @discardableResult
    func frame(_ name: String, parent: Int?, x: Double = 0, y: Double = 0, width: Double, height: Double,
               props: JSON = [:]) -> Int {
        var merged: JSON = ["fills": [Any](), "strokesIncluded": false, "clip": false]
        merged.merge(props) { _, new in new }
        var params: JSON = ["x": x, "y": y, "width": width, "height": height, "name": name, "props": merged]
        if let parent { params["parent"] = parent }
        step("frame.create", params)
        let id = allocate(parent: parent, name: name)
        expect(id)
        return id
    }

    /// A frame without auto layout, for free placement of its children (`strokesIncluded`, set by
    /// `frame`, is an auto layout property: FigCraft turns auto layout on with it).
    @discardableResult
    func freeFrame(_ name: String, parent: Int?, x: Double, y: Double, width: Double, height: Double,
                   props: JSON = [:]) -> Int {
        var merged: JSON = ["fills": [Any](), "clip": false]
        merged.merge(props) { _, new in new }
        var params: JSON = ["x": x, "y": y, "width": width, "height": height, "name": name, "props": merged]
        if let parent { params["parent"] = parent }
        step("frame.create", params)
        let id = allocate(parent: parent, name: name)
        expect(id)
        return id
    }

    @discardableResult
    func text(_ characters: String, parent: Int, size: String, style: String = "Regular", color: String,
              props: JSON = [:]) -> Int {
        var merged: JSON = ["fontFamily": fontFamily, "fontStyle": style, "fontSize": typeSize(size)]
        merged.merge(props) { _, new in new }
        step("text.create", ["text": characters, "x": 0, "y": 0, "parent": parent, "props": merged])
        let id = allocate(parent: parent, name: characters)
        texts.insert(id)
        expect(id)
        bind(id, "fill", color)
        bind(id, "fontSize", "Type/\(size)")
        return id
    }

    /// A text layer with a fixed (not themed) colour and font: content drawn by the guest, such
    /// as the VM console, which looks the same in both modes.
    @discardableResult
    func plainText(_ characters: String, parent: Int, props: JSON) -> Int {
        step("text.create", ["text": characters, "x": 0, "y": 0, "parent": parent, "props": props])
        let id = allocate(parent: parent, name: characters)
        texts.insert(id)
        expect(id)
        return id
    }

    @discardableResult
    func ellipse(parent: Int, size: Double, props: JSON = [:]) -> Int {
        ellipse(parent: parent, x: 0, y: 0, width: size, height: size, props: props)
    }

    /// An ellipse with its own box, relative to the parent.
    @discardableResult
    func ellipse(parent: Int, x: Double, y: Double, width: Double, height: Double, props: JSON = [:]) -> Int {
        step("shape.ellipse", ["x": x, "y": y, "width": width, "height": height, "parent": parent, "props": props])
        let id = allocate(parent: parent)
        expect(id)
        return id
    }

    @discardableResult
    func instance(of component: Int, parent: Int) -> Int {
        step("instance.create", ["component": component, "parent": parent])
        let id = copySubtree(of: component, parent: parent)
        expect(id)
        return id
    }

    /// The id, inside instance `instance` of `component`, of the copy of `layer`.
    func copy(of layer: Int, in instance: Int, of component: Int) -> Int {
        guard let offset = preorder(component).firstIndex(of: layer) else {
            fatalError("layer \(layer) is not in component \(component)")
        }
        return instance + offset
    }

    func setText(_ id: Int, _ characters: String) {
        step("text.set", ["id": id, "characters": characters])
    }

    func set(_ id: Int, _ props: JSON) {
        var params = props
        params["ids"] = [id]
        step("node.set", params)
    }

    /// Binds a variable; `token` is a color name ("surface") or "Collection/name".
    func bind(_ id: Int, _ field: String, _ token: String) {
        step("variable.bind", ["ids": [id], "field": field, "variable": variableID(token)])
    }

    func stroke(_ id: Int, _ token: String, weight: Double = 1, props: JSON = [:]) {
        step("stroke.add", ["ids": [id]])
        var params: JSON = ["strokeWeight": weight, "strokeAlign": "inside"]
        params.merge(props) { _, new in new }
        set(id, params)
        bind(id, "stroke", token)
    }

    func makeComponent(_ id: Int) {
        step("component.create", ["ids": [id]])
    }

    // Lookups (no steps)

    func children(of id: Int) -> [Int] { children[id] ?? [] }

    func parent(of id: Int) -> Int { parentOf[id]! }

    /// The layer with the lowest id named `name` (the first one created).
    func firstLayer(named name: String) -> Int {
        guard let id = names.filter({ $0.value == name }).keys.min() else { fatalError("no layer named \(name)") }
        return id
    }

    /// The first layer named `name` below `root`, in pre-order (the root itself excluded).
    func find(_ name: String, in root: Int) -> Int {
        guard let id = preorder(root).dropFirst().first(where: { names[$0] == name }) else {
            fatalError("no layer named \"\(name)\" below \(root)")
        }
        return id
    }

    /// A component that sits in a board section of the same name (the section is created first).
    func firstLayerComponent(_ name: String) -> Int {
        let section = firstLayer(named: name)
        guard let id = preorder(section).dropFirst().first(where: { names[$0] == name && !texts.contains($0) }) else {
            fatalError("no component \(name) in section \(section)")
        }
        return id
    }

    /// The variant `variant` (e.g. "Stato=running") of the component set named `set`.
    func variant(_ set: String, _ variant: String) -> Int {
        guard let setID = names.filter({ $0.value == set }).keys.sorted().first(where: { id in
            children(of: id).contains { names[$0] == variant }
        }) else { fatalError("no variant \(variant) in set \(set)") }
        return children(of: setID).first { names[$0] == variant }!
    }

    // Instances, slots, prototype

    /// Switches an instance to another variant: the instance keeps its id, the layers inside it
    /// are replaced by new ones (fresh ids, pre-order) and lose their overrides.
    func switchVariant(_ instance: Int, property: String, value: String, component: Int) {
        step("instance.setProperties", ["ids": [instance], "properties": [property: value]])
        for child in children[instance] ?? [] { parentOf[child] = nil }
        children[instance] = []
        for child in children[component] ?? [] { _ = copySubtree(of: child, parent: instance) }
    }

    /// Turns a frame inside a main component into a slot: its instances can take other content there.
    func makeSlot(_ id: Int, name: String) {
        step("component.makeSlot", ["id": id, "name": name])
    }

    /// Inserts an instance of `component` into a slot of an instance (after its current content,
    /// or in place of it with `replace`).
    @discardableResult
    func slotInsert(_ slot: Int, component: Int, replace: Bool = false) -> Int {
        var params: JSON = ["id": slot, "component": component]
        if replace {
            params["replace"] = true
            for child in children[slot] ?? [] { parentOf[child] = nil }
            children[slot] = []
        }
        step("instance.slotInsert", params)
        let id = copySubtree(of: component, parent: slot)
        expect(id)
        return id
    }

    /// A vector layer from SVG path data.
    @discardableResult
    func vector(_ name: String, path: String, parent: Int, props: JSON = [:]) -> Int {
        step("vector.create", ["path": path, "parent": parent, "props": props])
        let id = allocate(parent: parent, name: name)
        expect(id)
        set(id, ["name": name])
        return id
    }

    /// Prototype: a click (or a delay, for automatic steps) on `id` navigates to the frame `dest`.
    func navigate(from id: Int, to dest: Int, afterDelay ms: Int? = nil) {
        let trigger: JSON = ms.map { ["type": "afterDelay", "ms": $0] } ?? ["type": "onClick"]
        step("proto.interaction.add", ["id": id, "trigger": trigger,
                                        "action": ["type": "navigate", "dest": dest],
                                        "transition": ["type": "dissolve"], "durationMs": 200])
    }

    func flow(start: Int, name: String) {
        step("proto.flow.add", ["start": start, "name": name])
    }

    /// Combines variant components into a set named `name`, laid out in a wrapping row.
    @discardableResult
    func combine(_ ids: [Int], name: String, parent: Int) -> Int {
        step("component.combineVariants", ["ids": ids])
        // The set takes the variants' place in their parent.
        let setID = nextID
        nextID += 1
        maxID = setID
        names[setID] = name
        expect(setID)
        for id in ids {
            children[parent]?.removeAll { $0 == id }
            children[setID, default: []].append(id)
            parentOf[id] = setID
        }
        children[parent, default: []].append(setID)
        parentOf[setID] = parent
        step("object.rename", ["ids": [setID], "name": name])
        step("object.removeStroke", ["ids": [setID]])
        set(setID, ["layout": "horizontal", "wrap": true, "gap": 16, "crossGap": 16, "padding": 0,
                  "fills": [Any](), "sizingH": "fill", "sizingV": "hug", "crossAlign": "min",
                  "strokesIncluded": false])
        return setID
    }
}

// MARK: - Variable ids

/// Variable ids in creation order: the 12 colors, then Space, Radius, Type.
let variableIDs: [String: String] = {
    var ids: [String: String] = [:]
    var next = 1
    for (name, _, _) in colorTokens { ids[name] = "VariableID:\(next)"; next += 1 }
    for (name, _) in spaceTokens { ids["Space/\(name)"] = "VariableID:\(next)"; next += 1 }
    for (name, _) in radiusTokens { ids["Radius/\(name)"] = "VariableID:\(next)"; next += 1 }
    for (name, _) in typeTokens { ids["Type/\(name)"] = "VariableID:\(next)"; next += 1 }
    return ids
}()

func variableID(_ token: String) -> String {
    guard let id = variableIDs[token] else { fatalError("unknown token \(token)") }
    return id
}

func typeSize(_ name: String) -> Double { typeTokens.first { $0.0 == name }!.1 }
func space(_ name: String) -> Double { spaceTokens.first { $0.0 == name }!.1 }
func radius(_ name: String) -> Double { radiusTokens.first { $0.0 == name }!.1 }

// MARK: - Shared helpers

/// An auto layout frame with no fill. `direction` is horizontal or vertical.
@discardableResult
func stack(_ s: Script, _ name: String, parent: Int, _ direction: String, gap: String? = nil,
           padding: [String]? = nil, width: Double = 100, height: Double = 20, props: JSON = [:]) -> Int {
    var p: JSON = ["layout": direction, "sizingH": "hug", "sizingV": "hug"]
    p.merge(props) { _, new in new }
    let id = s.frame(name, parent: parent, width: width, height: height, props: p)
    if let gap { s.bind(id, "gap", "Space/\(gap)") }
    if let padding {
        let fields = ["paddingTop", "paddingRight", "paddingBottom", "paddingLeft"]
        let values = padding.count == 1 ? Array(repeating: padding[0], count: 4)
            : padding.count == 2 ? [padding[0], padding[1], padding[0], padding[1]] : padding
        for (field, value) in zip(fields, values) where value != "0" {
            s.bind(id, field, "Space/\(value)")
        }
    }
    return id
}

/// A flexible empty frame that pushes its siblings apart in a horizontal stack.
@discardableResult
func spacer(_ s: Script, parent: Int) -> Int {
    s.frame("Spazio", parent: parent, width: 1, height: 1, props: ["sizingH": "fill"])
}

func boardStyle(_ s: Script, _ board: Int, mode: String) {
    s.bind(board, "fill", "background")
    s.bind(board, "gap", "Space/xxl")
    for field in ["paddingTop", "paddingRight", "paddingBottom", "paddingLeft"] {
        s.bind(board, field, "Space/xxl")
    }
    s.step("variable.setMode", ["ids": [board], "collection": "Color", "mode": mode])
}

// MARK: - Output

func write(_ script: Script, to url: URL) throws {
    let data = try JSONSerialization.data(withJSONObject: script.steps, options: [.prettyPrinted, .sortedKeys])
    try (data + Data("\n".utf8)).write(to: url, options: .atomic)
}

/// `--verify <script.json> <run log>`: every step with `expectId` must have returned that id.
func verify(scriptPath: String, logPath: String) -> Never {
    guard let scriptData = FileManager.default.contents(atPath: scriptPath),
          let steps = try? JSONSerialization.jsonObject(with: scriptData) as? [JSON],
          let log = try? String(contentsOfFile: logPath, encoding: .utf8)
    else {
        FileHandle.standardError.write(Data("Impossibile leggere \(scriptPath) o \(logPath)\n".utf8))
        exit(2)
    }
    /// Layer ids are numbers, variable and collection ids strings; both compare as text.
    func idText(_ value: Any?) -> String? {
        if let number = value as? Int { return String(number) }
        return value as? String
    }
    var returned: [Int: String] = [:]
    for line in log.split(separator: "\n") {
        guard let entry = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? JSON,
              let index = entry["step"] as? Int,
              let result = entry["result"] as? JSON, let id = idText(result["id"])
        else { continue }
        returned[index] = id
    }
    var mismatches: [String] = []
    for (index, step) in steps.enumerated() {
        guard let expected = idText(step["expectId"]) else { continue }
        if returned[index] != expected {
            mismatches.append("passo \(index) (\(step["command"] ?? "?")): atteso id \(expected), "
                + "ottenuto \(returned[index] ?? "nessuno")")
        }
    }
    if mismatches.isEmpty {
        print("\(scriptPath): id di livelli e variabili come previsto.")
        exit(0)
    }
    print("\(scriptPath): id diversi da quelli previsti, rigenera gli script con scripts/gen-design-scripts.sh design/scripts:")
    for line in mismatches.prefix(20) { print("  - \(line)") }
    exit(1)
}
