// SPDX-License-Identifier: Apache-2.0
import CoreGraphics
import Foundation
import Testing
@testable import NidoAgentKit

// MARK: - Fake tree

private struct FakeNode {
    var attributes: AXNodeAttributes
    var children: [FakeNode] = []
    /// Reading this node's attributes throws, like an app that stopped answering.
    var hangs = false
    /// The app's open menus (children of the application element, not of a window).
    var menus: [FakeNode] = []
    /// Listing the app's menus throws.
    var menusHang = false
    /// Children shown only later, like a WebKit web view (see `LazyChildren`).
    var lazyChildren: LazyChildren?
}

/// A web view in Safari: its group has no children until an accessibility request reached it and
/// a moment passed (`settle`), then the page.
private final class LazyChildren {
    let content: [FakeNode]
    private var asked = false
    private(set) var shown = false
    init(_ content: [FakeNode]) { self.content = content }
    func read() -> [FakeNode] {
        asked = true
        return shown ? content : []
    }
    func settle() {
        if asked { shown = true }
    }
}

private struct FakeTimeout: Error {}

/// Root's children are the app's windows.
private struct FakeSource: AXNodeSource {
    func windows(of app: FakeNode) throws -> [FakeNode] { app.children }
    func attributes(of node: FakeNode) throws -> AXNodeAttributes {
        if node.hangs { throw FakeTimeout() }
        return node.attributes
    }
    func children(of node: FakeNode) throws -> [FakeNode] { node.lazyChildren?.read() ?? node.children }
    func menus(of app: FakeNode) throws -> [FakeNode] {
        if app.menusHang { throw FakeTimeout() }
        return app.menus
    }
}

private func node(_ role: String, subrole: String? = nil, title: String? = nil, description: String? = nil,
                  label: String? = nil, value: String? = nil, enabled: Bool? = true, focused: Bool? = false,
                  frame: CGRect? = CGRect(x: 10, y: 10, width: 80, height: 24),
                  _ children: [FakeNode] = []) -> FakeNode {
    FakeNode(attributes: AXNodeAttributes(role: role, subrole: subrole, title: title, description: description,
                                          label: label, value: value, enabled: enabled, focused: focused,
                                          frame: frame),
             children: children)
}

private func window(_ children: [FakeNode]) -> FakeNode {
    node("AXWindow", frame: CGRect(x: 0, y: 0, width: 1024, height: 640), children)
}

private func app(_ windows: [FakeNode]) -> FakeNode {
    node("AXApplication", title: "Test", frame: nil, windows)
}

/// display 1024x640 points, screenshot 512x320 pixels.
private let space = CoordinateSpace(display: PixelSize(1024, 640), maxLongEdge: 512)

private func walk(_ root: FakeNode, maxElements: Int = 300,
                  now: () -> ContinuousClock.Instant = { ContinuousClock.now }) -> UITree {
    UITreeWalker.walk(app: "Test", root: root, source: FakeSource(), space: space, maxElements: maxElements,
                      deadline: ContinuousClock.now + .seconds(60), now: now)
}

// MARK: - Brief tests

@Test func secureFieldHasNoValue() {
    for (role, subrole) in [("AXTextField", "AXSecureTextField"), ("AXSecureTextField", nil)] {
        let tree = walk(app([window([node(role, subrole: subrole, title: "Password", value: "hunter2")])]))
        let fields = tree.elements.filter { $0.name == "Password" }
        #expect(fields.count == 1)
        #expect(fields.first?.value == nil)
        #expect(fields.first?.role == "secureTextField")
        let json = String(data: try! JSONEncoder().encode(tree), encoding: .utf8) ?? ""
        #expect(!json.contains("hunter2"))
    }
}

/// An app may show the typed text in a child of the secure field: the walk never goes in.
@Test func secureFieldChildrenNotWalked() {
    for (role, subrole) in [("AXTextField", "AXSecureTextField"), ("AXSecureTextField", nil)] {
        let field = node(role, subrole: subrole, title: "Password", value: "hunter2",
                         [node("AXStaticText", value: "hunter2"), node("AXButton", title: "Reveal")])
        let tree = walk(app([window([field, node("AXButton", title: "After")])]))
        let json = String(data: try! JSONEncoder().encode(tree), encoding: .utf8) ?? ""
        #expect(!json.contains("hunter2"))
        #expect(!tree.elements.contains { $0.name == "Reveal" })
        #expect(tree.elements.contains { $0.name == "After" })
        #expect(tree.truncated == false)
    }
}

/// The label of an element is its title element's title, else its value, but never the value
/// of a secure field.
@Test func labelNeverTakesASecureValue() {
    #expect(UITreeWalker.labelText(title: "Name", value: "x", role: "AXStaticText", subrole: nil) == "Name")
    #expect(UITreeWalker.labelText(title: "  ", value: "Name", role: "AXStaticText", subrole: nil) == "Name")
    #expect(UITreeWalker.labelText(title: nil, value: "hunter2", role: "AXTextField",
                                   subrole: "AXSecureTextField") == nil)
    #expect(UITreeWalker.labelText(title: nil, value: "hunter2", role: "AXSecureTextField", subrole: nil) == nil)
    #expect(UITreeWalker.labelText(title: "Password", value: "hunter2", role: "AXSecureTextField",
                                   subrole: nil) == "Password")
    #expect(UITreeWalker.labelText(title: nil, value: nil, role: nil, subrole: nil) == nil)
}

/// A secure field never shows its value even through its name fallbacks.
@Test func secureFieldWithoutNameIsStillListed() {
    let tree = walk(app([window([node("AXTextField", subrole: "AXSecureTextField", value: "hunter2")])]))
    let fields = tree.elements.filter { $0.role == "secureTextField" }
    #expect(fields.count == 1)
    #expect(fields.first?.name == nil)
    #expect(fields.first?.value == nil)
}

@Test func containersSkippedChildrenKept() {
    let tree = walk(app([node("AXWindow", frame: CGRect(x: 0, y: 0, width: 1024, height: 640), [
        node("AXGroup", [node("AXButton", title: "Save")]),
    ])]))
    #expect(tree.elements.count == 1)
    #expect(tree.elements.first?.role == "button")
    #expect(tree.elements.first?.name == "Save")
    #expect(tree.elements.first?.id == 0)
    #expect(tree.app == "Test")
    #expect(tree.truncated == false)
}

@Test func offscreenAndEmptyDropped() {
    let tree = walk(app([window([
        node("AXButton", title: "Empty", frame: CGRect(x: 10, y: 10, width: 0, height: 0)),
        node("AXButton", title: "Away", frame: CGRect(x: 2000, y: 10, width: 50, height: 20)),
        node("AXButton", title: "NoFrame", frame: nil),
        node("AXButton", title: "Edge", frame: CGRect(x: 1000, y: 600, width: 100, height: 100)),
    ])]))
    let names = tree.elements.compactMap(\.name)
    #expect(!names.contains("Empty"))
    #expect(!names.contains("Away"))
    #expect(!names.contains("NoFrame"))
    let edge = tree.elements.first { $0.name == "Edge" }
    #expect(edge?.frame == PixelRect(x: 500, y: 300, w: 12, h: 20))
}

@Test func framesInScreenshotPixels() {
    let tree = walk(app([window([node("AXButton", title: "OK", frame: CGRect(x: 100, y: 200, width: 80, height: 24))])]))
    #expect(tree.elements.first { $0.name == "OK" }?.frame == PixelRect(x: 50, y: 100, w: 40, h: 12))
}

@Test func maxElementsTruncates() {
    let buttons = (0..<10).map { node("AXButton", title: "B\($0)") }
    let tree = walk(app([node("AXWindow", frame: nil, buttons)]), maxElements: 3)
    #expect(tree.elements.count == 3)
    #expect(tree.truncated == true)
    #expect(tree.elements.map(\.id) == [0, 1, 2])
    #expect(tree.elements.map(\.name) == ["B0", "B1", "B2"])
}

@Test func exactlyMaxElementsIsNotTruncated() {
    let buttons = (0..<3).map { node("AXButton", title: "B\($0)") }
    let tree = walk(app([node("AXWindow", frame: nil, buttons)]), maxElements: 3)
    #expect(tree.elements.count == 3)
    #expect(tree.truncated == false)
}

/// Counts the clock's reads: after `limit` reads, it is a minute later.
private final class FakeClock {
    let start = ContinuousClock.now
    var reads = 0
    let limit: Int
    init(limit: Int) { self.limit = limit }
    func now() -> ContinuousClock.Instant {
        reads += 1
        return reads > limit ? start + .seconds(120) : start
    }
}

@Test func deadlineTruncates() {
    let clock = FakeClock(limit: 2)
    let buttons = (0..<10).map { node("AXButton", title: "B\($0)") }
    let root = app([node("AXWindow", frame: nil, buttons)])
    let tree = UITreeWalker.walk(app: "Test", root: root, source: FakeSource(), space: space, maxElements: 300,
                                 deadline: clock.start + .seconds(3), now: clock.now)
    #expect(tree.truncated == true)
    #expect(tree.elements.count < 10)
}

@Test func unansweringAppTruncates() {
    var hung = node("AXButton", title: "Hung")
    hung.hangs = true
    let tree = walk(app([window([node("AXButton", title: "Before"), hung, node("AXButton", title: "After")])]))
    #expect(tree.truncated == true)
    #expect(tree.elements.compactMap(\.name) == ["Before"])
}

// MARK: - Web views (first contact)

/// Safari's window as Nido Agent first saw it on agent-27: the tab's group (the web view's host)
/// answers no children until a walk has reached it, then, a moment later, scroll area > web area
/// > the page's links.
private func safari() -> (root: FakeNode, page: LazyChildren) {
    let page = LazyChildren([node("AXGroup", frame: CGRect(x: 0, y: 82, width: 1024, height: 500), [
        node("AXScrollArea", frame: CGRect(x: 0, y: 82, width: 1024, height: 500), [
            node("AXWebArea", title: "Nido test", frame: CGRect(x: 0, y: 82, width: 1024, height: 2000), [
                node("AXLink", title: "Link number 1", frame: CGRect(x: 8, y: 394, width: 95, height: 19)),
            ]),
        ]),
    ])])
    var web = node("AXGroup", frame: CGRect(x: 0, y: 82, width: 1024, height: 500))
    web.lazyChildren = page
    let root = app([node("AXWindow", title: "nido-page.html", frame: CGRect(x: 0, y: 30, width: 1024, height: 553), [
        node("AXTabGroup", frame: CGRect(x: 0, y: 82, width: 1024, height: 500), [web]),
        node("AXButton", title: "Go back", frame: CGRect(x: 167, y: 39, width: 37, height: 36)),
    ])])
    return (root, page)
}

@Test func firstContactWaitsForAWebViewsContent() {
    let (root, page) = safari()
    let start = ContinuousClock.now
    var deadlines: [ContinuousClock.Instant] = []
    var slept: [Duration] = []
    let result = UITreeWalker.walkApp(app: "Safari", root: root, space: space, maxElements: 300, firstContact: true,
                                      source: { deadlines.append($0); return FakeSource() },
                                      now: { start }, sleep: { slept.append($0); page.settle() })
    let tree = result.tree
    #expect(result.reachedAWindow)
    #expect(tree.elements.contains { $0.role == "link" && $0.name == "Link number 1" })
    // The waking walk is dropped, not added to the answer.
    #expect(tree.elements.filter { $0.name == "Go back" }.count == 1)
    #expect(tree.elements.map(\.id) == Array(0..<tree.elements.count))
    #expect(tree.truncated == false)
    #expect(slept == [UITreeWalker.settleDelay])
    #expect(deadlines == [start + UITreeWalker.wakeDuration, start + UITreeWalker.maxDuration])
}

/// After the first walk of an app, no extra walk and no wait.
@Test func laterWalksDoNotWait() {
    let (root, page) = safari()
    _ = page.read()
    page.settle()
    var walks = 0
    var slept = false
    let result = UITreeWalker.walkApp(app: "Safari", root: root, space: space, maxElements: 300, firstContact: false,
                                      source: { _ in walks += 1; return FakeSource() }, sleep: { _ in slept = true })
    #expect(result.tree.elements.contains { $0.name == "Link number 1" })
    #expect(result.reachedAWindow)
    #expect(walks == 1)
    #expect(slept == false)
}

private func reachedAWindow(_ root: FakeNode) -> Bool {
    UITreeWalker.walkApp(app: "Test", root: root, space: space, maxElements: 300, firstContact: false,
                         source: { _ in FakeSource() }, sleep: { _ in }).reachedAWindow
}

/// Only a walk that went into a window counts as the first contact: one of a locked screen
/// (no window, only the menu bar) does not.
@Test func onlyAWalkThroughAWindowIsAContact() {
    #expect(reachedAWindow(safari().root))
    let locked = app([node("AXMenuBar", frame: CGRect(x: 0, y: 0, width: 1024, height: 30), [
        node("AXMenuBarItem", title: "Safari", frame: CGRect(x: 43, y: 0, width: 59, height: 30)),
    ])])
    #expect(!reachedAWindow(locked))
    #expect(!reachedAWindow(app([])))
}

/// A window without a title (many Electron and utility apps), or off screen, is not listed, but
/// the walk went into it: it counts, or every walk of that app would wake it again.
@Test func anUntitledWindowIsAContact() {
    let untitled = app([node("AXWindow", frame: CGRect(x: 0, y: 30, width: 1024, height: 553), [
        node("AXButton", title: "OK", frame: CGRect(x: 10, y: 40, width: 80, height: 24)),
    ])])
    #expect(reachedAWindow(untitled))
    #expect(reachedAWindow(app([node("AXWindow", title: "Away", frame: CGRect(x: 3000, y: 0, width: 100, height: 100))])))
}

/// A minimized window is not walked, so it does not count; an open menu is not a window.
@Test func minimizedWindowsAndMenusAreNoContact() {
    var minimized = node("AXWindow", title: "Mini", frame: CGRect(x: 0, y: 30, width: 400, height: 300))
    minimized.attributes.minimized = true
    #expect(!reachedAWindow(app([minimized])))
    var menuOnly = app([])
    menuOnly.menus = [node("AXMenu", frame: CGRect(x: 100, y: 100, width: 200, height: 100),
                           [node("AXMenuItem", title: "Copy")])]
    #expect(!reachedAWindow(menuOnly))
}

@Test func valueCappedAt200() {
    let long = String(repeating: "a", count: 500)
    let tree = walk(app([window([node("AXTextArea", value: long)])]))
    #expect(tree.elements.first { $0.role == "textArea" }?.value?.count == 200)
}

// MARK: - Roles, names, filtering

@Test func rolesLoseTheAXPrefix() {
    #expect(UITreeWalker.shortRole("AXButton", subrole: nil) == "button")
    #expect(UITreeWalker.shortRole("AXMenuItem", subrole: nil) == "menuItem")
    #expect(UITreeWalker.shortRole("AXPopUpButton", subrole: nil) == "popUpButton")
    #expect(UITreeWalker.shortRole("AXTextField", subrole: "AXSecureTextField") == "secureTextField")
    #expect(UITreeWalker.shortRole("AXSecureTextField", subrole: nil) == "secureTextField")
    #expect(UITreeWalker.shortRole("Custom", subrole: nil) == "custom")
    #expect(UITreeWalker.shortRole(nil, subrole: nil) == "unknown")
}

@Test func nameFallsBackFromTitleToDescriptionToLabel() {
    let tree = walk(app([node("AXWindow", frame: nil, [
        node("AXButton", title: "  Title  ", description: "Desc", label: "Label"),
        node("AXButton", title: "   ", description: "Desc", label: "Label"),
        node("AXButton", description: "", label: "Label"),
        node("AXButton"),
    ])]))
    #expect(tree.elements.map(\.name) == ["Title", "Desc", "Label", nil])
}

@Test func plainElementsWithoutNameOrValueSkipped() {
    let tree = walk(app([node("AXWindow", frame: nil, [
        node("AXImage"),
        node("AXStaticText", value: "Hello"),
        node("AXCheckBox", value: "1"),
        node("AXLink"),
    ])]))
    #expect(tree.elements.map(\.role) == ["staticText", "checkBox", "link"])
    #expect(tree.elements.first?.value == "Hello")
}

@Test func emptyValueIsNil() {
    let tree = walk(app([node("AXWindow", frame: nil, [node("AXTextField", title: "Name", value: "  ")])]))
    #expect(tree.elements.first?.value == nil)
}

@Test func enabledAndFocusedRead() {
    let tree = walk(app([node("AXWindow", frame: nil, [
        node("AXButton", title: "Off", enabled: false, focused: nil),
        node("AXTextField", title: "Here", enabled: nil, focused: true),
    ])]))
    #expect(tree.elements.map(\.enabled) == [false, true])
    #expect(tree.elements.map(\.focused) == [false, true])
}

@Test func readingOrderIsDepthFirst() {
    let tree = walk(app([
        node("AXWindow", title: "One", [
            node("AXGroup", [node("AXButton", title: "A"), node("AXButton", title: "B")]),
            node("AXButton", title: "C"),
        ]),
        node("AXWindow", title: "Two", [node("AXButton", title: "D")]),
    ]))
    #expect(tree.elements.compactMap(\.name) == ["One", "A", "B", "C", "Two", "D"])
    #expect(tree.elements.map(\.id) == Array(0..<6))
}

@Test func depthIsLimited() {
    var deep = node("AXButton", title: "Deep")
    for _ in 0..<40 { deep = node("AXGroup", [deep]) }
    let tree = walk(app([node("AXWindow", frame: nil, [deep, node("AXButton", title: "Shallow")])]))
    #expect(tree.elements.compactMap(\.name) == ["Shallow"])
    #expect(tree.truncated == true)
}

// MARK: - Windows that do not answer, minimized windows, open menus

/// A window that does not answer is skipped; the other windows are still listed.
@Test func unansweringWindowIsSkipped() {
    var hung = window([node("AXButton", title: "Lost")])
    hung.hangs = true
    let tree = walk(app([hung, window([node("AXButton", title: "Kept")])]))
    #expect(tree.elements.compactMap(\.name) == ["Kept"])
    #expect(tree.truncated == true)
}

/// An element deep in a window that does not answer drops the rest of that window only.
@Test func unansweringElementSkipsOnlyItsWindow() {
    var hung = node("AXButton", title: "Hung")
    hung.hangs = true
    let tree = walk(app([
        window([node("AXButton", title: "Before"), hung, node("AXButton", title: "After")]),
        window([node("AXButton", title: "Other")]),
    ]))
    #expect(tree.elements.compactMap(\.name) == ["Before", "Other"])
    #expect(tree.truncated == true)
}

@Test func minimizedWindowIsSkipped() {
    var minimized = window([node("AXButton", title: "Hidden")])
    minimized.attributes.title = "Minimized"
    minimized.attributes.minimized = true
    let tree = walk(app([minimized, window([node("AXButton", title: "Shown")])]))
    #expect(tree.elements.compactMap(\.name) == ["Shown"])
    #expect(tree.truncated == false)
}

/// A context menu is a child of the application element: listed after the windows.
@Test func openMenusAreListedAfterTheWindows() {
    var root = app([window([node("AXButton", title: "Save")])])
    root.menus = [node("AXMenu", frame: CGRect(x: 300, y: 300, width: 200, height: 100), [
        node("AXMenuItem", title: "Copy", frame: CGRect(x: 300, y: 300, width: 200, height: 20)),
        node("AXMenuItem", title: "Paste", frame: CGRect(x: 300, y: 320, width: 200, height: 20)),
    ])]
    let tree = walk(root)
    #expect(tree.elements.compactMap(\.name) == ["Save", "Copy", "Paste"])
    #expect(tree.elements.map(\.role) == ["button", "menuItem", "menuItem"])
    #expect(tree.elements.map(\.id) == [0, 1, 2])
    #expect(tree.truncated == false)
}

@Test func unansweringMenusKeepTheWindows() {
    var root = app([window([node("AXButton", title: "Save")])])
    root.menusHang = true
    let tree = walk(root)
    #expect(tree.elements.compactMap(\.name) == ["Save"])
    #expect(tree.truncated == true)
}

/// Menus share the element limit with the windows.
@Test func menusCountTowardsMaxElements() {
    var root = app([window([node("AXButton", title: "Save")])])
    root.menus = [node("AXMenu", frame: CGRect(x: 300, y: 300, width: 200, height: 100), [
        node("AXMenuItem", title: "Copy", frame: CGRect(x: 300, y: 300, width: 200, height: 20)),
        node("AXMenuItem", title: "Paste", frame: CGRect(x: 300, y: 320, width: 200, height: 20)),
    ])]
    let tree = walk(root, maxElements: 2)
    #expect(tree.elements.compactMap(\.name) == ["Save", "Copy"])
    #expect(tree.truncated == true)
}

/// Past the deadline the reader no longer looks up labels (up to five more calls per element).
@Test func labelLookupOnlyBeforeTheDeadline() {
    #expect(UITreeWalker.wantsLabel(title: nil, description: nil, pastDeadline: false))
    #expect(UITreeWalker.wantsLabel(title: "  ", description: "", pastDeadline: false))
    #expect(!UITreeWalker.wantsLabel(title: nil, description: nil, pastDeadline: true))
    #expect(!UITreeWalker.wantsLabel(title: "Save", description: nil, pastDeadline: false))
    #expect(!UITreeWalker.wantsLabel(title: nil, description: "Close", pastDeadline: false))
}

// MARK: - Scrolled-out elements

/// Children of a scroll area are listed only where the scroll area shows them, with the part
/// that shows; elements outside a scroll area are not clipped by it.
@Test func scrollAreaClipsItsChildren() {
    // Scroll area from y 100 to 300 points; screenshot pixels are half the points.
    let tree = walk(app([window([
        node("AXScrollArea", frame: CGRect(x: 0, y: 100, width: 1024, height: 200), [
            node("AXButton", title: "Above", frame: CGRect(x: 10, y: 20, width: 80, height: 24)),
            node("AXButton", title: "Inside", frame: CGRect(x: 10, y: 150, width: 80, height: 24)),
            node("AXButton", title: "Partly", frame: CGRect(x: 10, y: 280, width: 80, height: 40)),
            node("AXButton", title: "Below", frame: CGRect(x: 10, y: 400, width: 80, height: 24)),
        ]),
        node("AXButton", title: "Footer", frame: CGRect(x: 10, y: 400, width: 80, height: 24)),
    ])]))
    #expect(tree.elements.compactMap(\.name) == ["Inside", "Partly", "Footer"])
    #expect(tree.elements.first { $0.name == "Inside" }?.frame == PixelRect(x: 5, y: 75, w: 40, h: 12))
    #expect(tree.elements.first { $0.name == "Partly" }?.frame == PixelRect(x: 5, y: 140, w: 40, h: 10))
    #expect(tree.elements.first { $0.name == "Footer" }?.frame == PixelRect(x: 5, y: 200, w: 40, h: 12))
    #expect(tree.truncated == false)
}

/// Nested scroll areas (a web area's scroll area inside a window's) clip to both; children of
/// a web area are clipped by its frame too.
@Test func nestedScrollAreasClipToBoth() {
    let tree = walk(app([window([
        node("AXScrollArea", frame: CGRect(x: 0, y: 100, width: 1024, height: 400), [
            node("AXGroup", [
                node("AXScrollArea", frame: CGRect(x: 0, y: 0, width: 500, height: 300), [
                    node("AXWebArea", frame: CGRect(x: 0, y: 0, width: 500, height: 2000), [
                        node("AXLink", title: "Top", frame: CGRect(x: 10, y: 50, width: 80, height: 20)),
                        node("AXLink", title: "Shown", frame: CGRect(x: 10, y: 200, width: 80, height: 20)),
                        node("AXLink", title: "Fold", frame: CGRect(x: 10, y: 900, width: 80, height: 20)),
                    ]),
                ]),
            ]),
        ]),
    ])]))
    #expect(tree.elements.compactMap(\.name) == ["Shown"])
}

/// Elements outside their window are not listed.
@Test func windowClipsItsElements() {
    let tree = walk(app([node("AXWindow", frame: CGRect(x: 100, y: 100, width: 300, height: 200), [
        node("AXButton", title: "In", frame: CGRect(x: 120, y: 120, width: 80, height: 24)),
        node("AXButton", title: "Out", frame: CGRect(x: 600, y: 120, width: 80, height: 24)),
    ])]))
    #expect(tree.elements.compactMap(\.name) == ["In"])
}

/// A menu or popover opened from a window draws in its own window: not clipped by the opener.
@Test func menuOpenedFromAWindowIsNotClippedByIt() {
    let tree = walk(app([node("AXWindow", frame: CGRect(x: 100, y: 100, width: 300, height: 200), [
        node("AXScrollArea", frame: CGRect(x: 100, y: 100, width: 300, height: 100), [
            node("AXPopUpButton", title: "Size", frame: CGRect(x: 120, y: 120, width: 80, height: 24), [
                node("AXMenu", frame: CGRect(x: 120, y: 120, width: 120, height: 400), [
                    node("AXMenuItem", title: "Large", frame: CGRect(x: 120, y: 450, width: 120, height: 20)),
                ]),
            ]),
        ]),
        node("AXPopover", frame: CGRect(x: 350, y: 150, width: 300, height: 300), [
            node("AXButton", title: "Done", frame: CGRect(x: 500, y: 400, width: 80, height: 24)),
        ]),
    ])]))
    #expect(tree.elements.compactMap(\.name) == ["Size", "Large", "Done"])
}

// MARK: - Which app to walk

@Test func frontmostAppWithAWindowIsWalked() {
    let windows = [
        OnScreenWindow(pid: 20, layer: 0, ownerName: "Safari"),
        OnScreenWindow(pid: 10, layer: 0, ownerName: "Notes"),
    ]
    #expect(UITreeWalker.appToWalk(windows: windows, frontmost: 10) == AppToWalk(pid: 10, ownerName: "Notes"))
}

/// Finder is frontmost after a click on the desktop, but only System Settings shows a window.
@Test func frontmostAppWithoutAWindowFallsBackToTheTopmostWindow() {
    let windows = [
        OnScreenWindow(pid: 1, layer: 25, ownerName: "SystemUIServer"),
        OnScreenWindow(pid: 30, layer: 24, ownerName: "Dock"),
        OnScreenWindow(pid: 40, layer: 0, ownerName: "System Settings"),
        OnScreenWindow(pid: 50, layer: 0, ownerName: "Notes"),
    ]
    #expect(UITreeWalker.appToWalk(windows: windows, frontmost: 99) == AppToWalk(pid: 40, ownerName: "System Settings"))
}

/// A frontmost app with only panels above normal windows (layer > 0) has no window to walk.
@Test func onlyNormalWindowsCount() {
    let windows = [
        OnScreenWindow(pid: 10, layer: 3, ownerName: "Notes"),
        OnScreenWindow(pid: 40, layer: 0, ownerName: "TextEdit"),
    ]
    #expect(UITreeWalker.appToWalk(windows: windows, frontmost: 10) == AppToWalk(pid: 40, ownerName: "TextEdit"))
}

@Test func noWindowAtAllKeepsTheFrontmostApp() {
    let windows = [OnScreenWindow(pid: 30, layer: 20, ownerName: "Dock")]
    #expect(UITreeWalker.appToWalk(windows: windows, frontmost: 10) == AppToWalk(pid: 10, ownerName: nil))
    #expect(UITreeWalker.appToWalk(windows: [], frontmost: 10) == AppToWalk(pid: 10, ownerName: nil))
}

@Test func noFrontmostAppTakesTheTopmostWindow() {
    let windows = [OnScreenWindow(pid: 40, layer: 0, ownerName: "TextEdit")]
    #expect(UITreeWalker.appToWalk(windows: windows, frontmost: nil) == AppToWalk(pid: 40, ownerName: "TextEdit"))
    #expect(UITreeWalker.appToWalk(windows: [], frontmost: nil) == nil)
}
