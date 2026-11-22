// SPDX-License-Identifier: Apache-2.0
import CoreGraphics
import Foundation

/// What one accessibility element says about itself, as read from the app.
public struct AXNodeAttributes: Equatable, Sendable {
    /// `AXRole`, e.g. "AXButton".
    public var role: String?
    /// `AXSubrole`, e.g. "AXSecureTextField".
    public var subrole: String?
    /// `AXTitle`.
    public var title: String?
    /// `AXDescription`.
    public var description: String?
    /// The title (or value) of the element's `AXTitleUIElement`, the label next to it.
    public var label: String?
    /// `AXValue` as text (numbers as their decimal form); nil when it is neither.
    public var value: String?
    /// `AXEnabled`; nil when the element does not say (taken as enabled).
    public var enabled: Bool?
    /// `AXFocused`; nil when the element does not say (taken as not focused).
    public var focused: Bool?
    /// `AXPosition` and `AXSize`: global display points, origin top left of the main display.
    public var frame: CGRect?
    /// `AXMinimized`: only windows say; a minimized window is not walked.
    public var minimized: Bool?

    public init(role: String? = nil, subrole: String? = nil, title: String? = nil, description: String? = nil,
                label: String? = nil, value: String? = nil, enabled: Bool? = nil, focused: Bool? = nil,
                frame: CGRect? = nil, minimized: Bool? = nil) {
        self.role = role
        self.subrole = subrole
        self.title = title
        self.description = description
        self.label = label
        self.value = value
        self.enabled = enabled
        self.focused = focused
        self.frame = frame
        self.minimized = minimized
    }
}

/// The accessibility calls the walk makes, so it can run over a fake tree in tests.
///
/// A method throws only when the app did not answer (the messaging timeout): the walk then
/// gives up that window (or the menus) and says `truncated`. An element that went away answers
/// empty attributes and no children, it does not throw.
public protocol AXNodeSource {
    associatedtype Node
    /// The app's windows, sheets and dialogs included, frontmost first (`AXWindows`; the walk
    /// skips the minimized ones).
    func windows(of app: Node) throws -> [Node]
    func attributes(of node: Node) throws -> AXNodeAttributes
    /// `AXChildren`, in order.
    func children(of node: Node) throws -> [Node]
    /// The app's open menus that are children of the application element, not of a window
    /// (a context menu).
    func menus(of app: Node) throws -> [Node]
}

/// One window on screen as the window server lists it (`CGWindowListCopyWindowInfo`), owner and
/// layer only: reading them needs no Screen Recording.
public struct OnScreenWindow: Equatable, Sendable {
    public var pid: Int32
    /// `kCGWindowLayer`: 0 for an app's normal windows; menus, panels, the Dock are above.
    public var layer: Int
    public var ownerName: String?

    public init(pid: Int32, layer: Int, ownerName: String?) {
        self.pid = pid
        self.layer = layer
        self.ownerName = ownerName
    }
}

/// The app `uiTree` walks: its pid and, when known from the window list, its name.
public struct AppToWalk: Equatable, Sendable {
    public var pid: Int32
    public var ownerName: String?

    public init(pid: Int32, ownerName: String?) {
        self.pid = pid
        self.ownerName = ownerName
    }
}

/// Reads the frontmost app's controls for `uiTree` (`AXSource` in the app).
public protocol AccessibilitySource: Sendable {
    /// The frontmost app's tree, frames in pixels of `space.image`. Throws when there is no
    /// frontmost app to read.
    func uiTree(space: CoordinateSpace, maxElements: Int) async throws -> UITree
}

/// Flattens an app's accessibility tree into the elements an agent can act on, in reading order
/// (depth first, windows frontmost first).
public enum UITreeWalker {
    /// Deepest level walked below a window.
    public static let maxDepth = 30
    /// Longest a whole walk may take.
    public static let maxDuration: Duration = .seconds(3)
    /// Longest name and value kept, in characters.
    public static let maxTextCharacters = 200
    /// Longest role kept, in characters (an app may invent its own roles).
    static let maxRoleCharacters = 64

    /// Roles an agent can act on: listed even without a name or a value.
    public static let actionableRoles: Set<String> = [
        "button", "link", "textField", "secureTextField", "textArea", "checkBox", "radioButton",
        "popUpButton", "menuButton", "comboBox", "slider", "tab", "menuItem", "disclosureTriangle",
        "incrementor",
    ]

    /// Roles that show only part of their content: their children are clipped to their frame
    /// (rows scrolled out, a web page below the fold).
    static let clippingRoles: Set<String> = ["AXScrollArea", "AXWebArea"]

    /// Roles drawn in a window of their own, over their opener: clipped to their own frame, not
    /// to the window or scroll area they were opened from.
    static let ownWindowRoles: Set<String> = ["AXMenu", "AXPopover", "AXSheet"]

    /// Walks `source.windows(of: root)` and their descendants. Stops, with `truncated`, at
    /// `maxElements` kept elements, below `maxDepth`, at `deadline` (read with `now`) or when the
    /// app stops answering.
    ///
    /// The windows come first, then the app's open menus. A window (or the menus) that stops
    /// answering is given up, the rest is still walked: the walk says `truncated`.
    public static func walk<Source: AXNodeSource>(
        app: String, root: Source.Node, source: Source, space: CoordinateSpace, maxElements: Int,
        deadline: ContinuousClock.Instant, now: () -> ContinuousClock.Instant = { ContinuousClock.now }
    ) -> UITree {
        walkReachingWindows(app: app, root: root, source: source, space: space, maxElements: maxElements,
                            deadline: deadline, now: now).tree
    }

    /// `walk`, and whether it went into one of the app's windows (`AppWalk.reachedAWindow`).
    static func walkReachingWindows<Source: AXNodeSource>(
        app: String, root: Source.Node, source: Source, space: CoordinateSpace, maxElements: Int,
        deadline: ContinuousClock.Instant, now: () -> ContinuousClock.Instant
    ) -> AppWalk {
        withoutActuallyEscaping(now) { now in
            var walk = UITreeWalk(source: source, space: space, maxElements: maxElements, deadline: deadline, now: now)
            walk.visitTops(windows: true) { try source.windows(of: root) }
            walk.visitTops(windows: false) { try source.menus(of: root) }
            return AppWalk(tree: UITree(app: app, elements: walk.elements, truncated: walk.truncated),
                           reachedAWindow: walk.reachedAWindow)
        }
    }

    /// Longest the waking walk of `walkApp` may take.
    public static let wakeDuration: Duration = .seconds(1)
    /// Wait between the waking walk and the walk that answers (Safari needed about 0.1 s).
    public static let settleDelay: Duration = .milliseconds(300)

    /// The walk `uiTree` answers with. WebKit (Safari, Mail, any app with a web view) leaves a web
    /// view's content out of the tree until an accessibility request reaches the view, and adds
    /// it a moment later: the first walk of such an app finds an empty group where the page is.
    /// So on `firstContact` (no walk of that app process has `reachedAWindow` yet) one walk, bounded by
    /// `wakeDuration`, wakes the web views and its tree is dropped; after `settleDelay` comes
    /// the walk that answers, bounded by `maxDuration`. `source` makes the reader for a deadline.
    public static func walkApp<Source: AXNodeSource>(
        app: String, root: Source.Node, space: CoordinateSpace, maxElements: Int, firstContact: Bool,
        source: (_ deadline: ContinuousClock.Instant) -> Source,
        now: () -> ContinuousClock.Instant = { ContinuousClock.now },
        sleep: (Duration) -> Void
    ) -> AppWalk {
        var woke = false
        if firstContact {
            let wake = now() + wakeDuration
            woke = walkReachingWindows(app: app, root: root, source: source(wake), space: space,
                                       maxElements: maxElements, deadline: wake, now: now).reachedAWindow
            sleep(settleDelay)
        }
        let deadline = now() + maxDuration
        var answer = walkReachingWindows(app: app, root: root, source: source(deadline), space: space,
                                         maxElements: maxElements, deadline: deadline, now: now)
        answer.reachedAWindow = answer.reachedAWindow || woke
        return answer
    }

    /// The app to walk: the frontmost app when it has a normal window (layer 0) on screen,
    /// otherwise the owner of the topmost normal window. Finder stays frontmost after a click on
    /// the desktop while another app's window is all there is to see. With no normal window at
    /// all, the frontmost app; nil when there is neither. `windows` is front to back.
    public static func appToWalk(windows: [OnScreenWindow], frontmost: Int32?) -> AppToWalk? {
        let normal = windows.filter { $0.layer == 0 }
        if let frontmost {
            if let own = normal.first(where: { $0.pid == frontmost }) {
                return AppToWalk(pid: frontmost, ownerName: own.ownerName)
            }
            guard let top = normal.first else { return AppToWalk(pid: frontmost, ownerName: nil) }
            return AppToWalk(pid: top.pid, ownerName: top.ownerName)
        }
        return normal.first.map { AppToWalk(pid: $0.pid, ownerName: $0.ownerName) }
    }

    /// Whether to look up an element's label (`AXTitleUIElement`, up to five more AX calls): only
    /// when it has neither a title nor a description, and not once the walk is past its deadline.
    public static func wantsLabel(title: String?, description: String?, pastDeadline: Bool) -> Bool {
        !pastDeadline && text(title) == nil && text(description) == nil
    }

    /// `AXButton` → `button`; a secure text field (role or subrole) → `secureTextField`.
    public static func shortRole(_ role: String?, subrole: String?) -> String {
        if isSecure(role: role, subrole: subrole) { return "secureTextField" }
        guard var name = role.map(trimmed), !name.isEmpty else { return "unknown" }
        if name.hasPrefix("AX"), name.count > 2 { name.removeFirst(2) }
        let short = name.prefix(1).lowercased() + name.dropFirst()
        return String(short.prefix(maxRoleCharacters))
    }

    public static func isSecure(role: String?, subrole: String?) -> Bool {
        role == "AXSecureTextField" || subrole == "AXSecureTextField"
    }

    /// What an element's title element (`AXTitleUIElement`) says as a label: its title, else its
    /// value, but never the value of a secure text field.
    public static func labelText(title: String?, value: String?, role: String?, subrole: String?) -> String? {
        if let title = text(title) { return title }
        return isSecure(role: role, subrole: subrole) ? nil : text(value)
    }

    /// Trimmed, capped at `maxTextCharacters`; nil when nothing is left.
    static func text(_ s: String?) -> String? {
        guard let s else { return nil }
        let t = trimmed(s)
        return t.isEmpty ? nil : String(t.prefix(maxTextCharacters))
    }

    private static func trimmed(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// What `UITreeWalker.walkApp` found.
public struct AppWalk: Equatable, Sendable {
    /// The answer.
    public var tree: UITree
    /// Whether a walk went into one of the app's windows (an `AXWindow` from `AXWindows`, not
    /// minimized), listed or not (a window without a title is not), and so woke its web views. A
    /// walk of a locked screen goes into none.
    public var reachedAWindow: Bool

    public init(tree: UITree, reachedAWindow: Bool) {
        self.tree = tree
        self.reachedAWindow = reachedAWindow
    }
}

/// One walk's state: what it kept and whether it stopped.
private struct UITreeWalk<Source: AXNodeSource> {
    let source: Source
    let space: CoordinateSpace
    let maxElements: Int
    let deadline: ContinuousClock.Instant
    let now: () -> ContinuousClock.Instant
    var elements: [UIElement] = []
    var truncated = false
    var stopped = false
    /// Went into an `AXWindow` of the windows list (`AppWalk.reachedAWindow`).
    var reachedAWindow = false
    /// The tops being walked come from the windows list, not the menus.
    private var walkingWindows = false

    init(source: Source, space: CoordinateSpace, maxElements: Int, deadline: ContinuousClock.Instant,
         now: @escaping () -> ContinuousClock.Instant) {
        self.source = source
        self.space = space
        self.maxElements = maxElements
        self.deadline = deadline
        self.now = now
    }

    mutating func stop() {
        truncated = true
        stopped = true
    }

    /// Walks the top-level nodes `list` gives (windows, or menus). One that does not answer is
    /// given up (`truncated`) and the next one walked; a list that does not answer is skipped.
    mutating func visitTops(windows: Bool, _ list: () throws -> [Source.Node]) {
        walkingWindows = windows
        guard !stopped else { return }
        guard now() < deadline else { return stop() }
        guard let tops = try? list() else {
            truncated = true
            return
        }
        for top in tops where !stopped {
            do {
                try visit(top, depth: 0, clip: nil)
            } catch {
                truncated = true
            }
        }
    }

    /// Lists `node` when it shows inside `clip` (display points; nil is no clip), then its
    /// children. Throws when the app stops answering, so the caller gives up the window.
    mutating func visit(_ node: Source.Node, depth: Int, clip: CGRect?) throws {
        guard !stopped else { return }
        guard now() < deadline else { return stop() }
        let attributes = try source.attributes(of: node)
        if depth == 0, attributes.minimized == true { return }
        if depth == 0, walkingWindows, attributes.role == "AXWindow" { reachedAWindow = true }
        let frame = attributes.frame.map(\.standardized)
        // A window, menu or popover is clipped to its own frame, not to what opened it.
        var clip = clip
        if depth == 0 || attributes.role.map(UITreeWalker.ownWindowRoles.contains) == true {
            clip = frame
        }
        if let element = element(attributes, frame: frame, clip: clip) {
            guard elements.count < maxElements else { return stop() }
            elements.append(element)
        }
        // An app may show the typed text in a child of a secure field: never look inside one.
        guard !UITreeWalker.isSecure(role: attributes.role, subrole: attributes.subrole) else { return }
        if let frame, attributes.role.map(UITreeWalker.clippingRoles.contains) == true {
            clip = clip.map { $0.intersection(frame) } ?? frame
        }
        // Nothing of a scroll area outside the window shows: its children are not read.
        if let clip, Self.isEmpty(clip) { return }
        guard now() < deadline else { return stop() }
        let children = try source.children(of: node)
        guard !children.isEmpty else { return }
        guard depth < UITreeWalker.maxDepth else {
            truncated = true
            return
        }
        for child in children {
            try visit(child, depth: depth + 1, clip: clip)
            if stopped { return }
        }
    }

    private static func isEmpty(_ rect: CGRect) -> Bool {
        rect.isNull || rect.width <= 0 || rect.height <= 0
    }

    /// The element to list for `attributes`, or nil for a plain container, an empty element or
    /// one that does not show inside `clip`. Its frame is the part that shows. A secure text
    /// field never carries its value.
    private func element(_ attributes: AXNodeAttributes, frame: CGRect?, clip: CGRect?) -> UIElement? {
        let role = UITreeWalker.shortRole(attributes.role, subrole: attributes.subrole)
        let secure = UITreeWalker.isSecure(role: attributes.role, subrole: attributes.subrole)
        let name = UITreeWalker.text(attributes.title) ?? UITreeWalker.text(attributes.description)
            ?? UITreeWalker.text(attributes.label)
        let value = secure ? nil : UITreeWalker.text(attributes.value)
        guard name != nil || value != nil || UITreeWalker.actionableRoles.contains(role) else { return nil }
        guard var frame else { return nil }
        if let clip { frame = frame.intersection(clip) }
        guard !Self.isEmpty(frame), let pixels = space.toImageRect(frame) else { return nil }
        return UIElement(id: elements.count, role: role, name: name, value: value,
                         enabled: attributes.enabled ?? true, focused: attributes.focused ?? false, frame: pixels)
    }
}
