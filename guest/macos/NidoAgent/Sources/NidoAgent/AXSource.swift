// SPDX-License-Identifier: Apache-2.0
import AppKit
import ApplicationServices
import NidoAgentKit

/// Reads the accessibility tree of the app on screen for `uiTree`, with the Accessibility
/// permission Nido Agent already has. The walk itself (what is kept, secure fields, limits,
/// frames) is `UITreeWalker`; this picks the app and makes the AX calls.
struct AXSource: AccessibilitySource {
    /// One walk at a time, off the cooperative pool: AX calls block until the app answers.
    private static let queue = DispatchQueue(label: "io.gitlab.pichierri.Nido.Agent.accessibility")

    /// The app processes (pid and launch time: a pid can be reused) a walk already went through
    /// a window of (`AppWalk.reachedAWindow`), for `UITreeWalker.walkApp`'s first contact.
    /// Read and written on `queue` only.
    nonisolated(unsafe) private static var walked: Set<String> = []

    struct NoFrontmostApp: Error, CustomStringConvertible {
        var description: String { "no app is frontmost" }
    }

    func uiTree(space: CoordinateSpace, maxElements: Int) async throws -> UITree {
        let target = await MainActor.run { () -> (pid: pid_t, name: String, process: String?, front: pid_t?,
                                                  system: AXNodeReader.SystemProcesses)? in
            let front = NSWorkspace.shared.frontmostApplication
            // The menu bar on screen is its owner's, which right after login is Finder while no app
            // is active (frontmost is another app or none): the owner, else the frontmost app.
            let barOwner = NSWorkspace.shared.menuBarOwningApplication ?? front
            guard let choice = UITreeWalker.appToWalk(windows: Self.onScreenWindows(),
                                                      frontmost: front?.processIdentifier) else { return nil }
            let app = choice.pid == front?.processIdentifier
                ? front : NSRunningApplication(processIdentifier: choice.pid)
            // Without a launch time a reused pid would pass for the old process: not remembered.
            let process = app?.launchDate.map { "\(choice.pid)@\($0.timeIntervalSinceReferenceDate)" }
            return (choice.pid, app?.localizedName ?? choice.ownerName ?? app?.bundleIdentifier ?? "", process,
                    barOwner?.processIdentifier, AXNodeReader.SystemProcesses.running(frontmost: barOwner?.processIdentifier))
        }
        guard let target else { throw NoFrontmostApp() }
        return await withCheckedContinuation { continuation in
            Self.queue.async {
                let app = AXUIElementCreateApplication(target.pid)
                AXUIElementSetMessagingTimeout(app, AXNodeReader.timeout)
                // The menu bar on screen is its owner's (`front` here), which may not be the app walked.
                let menuBarRoot = target.front.map { front -> AXUIElement in
                    let element = front == target.pid ? app : AXUIElementCreateApplication(front)
                    AXUIElementSetMessagingTimeout(element, AXNodeReader.timeout)
                    return element
                }
                let firstContact = target.process.map { !Self.walked.contains($0) } ?? true
                let result = UITreeWalker.walkApp(
                    app: target.name, root: app, menuBarRoot: menuBarRoot, space: space, maxElements: maxElements, firstContact: firstContact,
                    source: { AXNodeReader(deadline: $0, system: target.system) },
                    sleep: { Thread.sleep(forTimeInterval: Double($0.components.seconds)
                                          + Double($0.components.attoseconds) / 1e18) })
                if result.reachedAWindow, let process = target.process { Self.walked.insert(process) }
                let tree = result.tree
                Log.app.notice("ui tree: \(tree.elements.count) elements, truncated: \(tree.truncated), first contact: \(firstContact)")
                continuation.resume(returning: tree)
            }
        }
    }

    /// The windows on screen, front to back, without the desktop. Owner and layer need no
    /// Screen Recording (only window names would).
    private static func onScreenWindows() -> [OnScreenWindow] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.compactMap { info in
            guard let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue else { return nil }
            return OnScreenWindow(pid: pid, layer: layer, ownerName: info[kCGWindowOwnerName as String] as? String)
        }
    }
}

/// The AX calls behind `UITreeWalker`. Only an app that does not answer in time throws; any
/// other error (an element that went away, an attribute it lacks) reads as empty.
struct AXNodeReader: AXNodeSource {
    /// Seconds an app has to answer one AX call.
    static let timeout: Float = 0.5

    struct Unresponsive: Error {}

    /// The walk's deadline: past it, no more optional calls (labels, menu roles).
    let deadline: ContinuousClock.Instant

    private var pastDeadline: Bool { ContinuousClock.now >= deadline }

    private static let attributeNames = [
        "AXRole", "AXSubrole", "AXTitle", "AXDescription", "AXValue", "AXEnabled", "AXFocused",
        "AXPosition", "AXSize", "AXMinimized", "AXIsApplicationRunning",
    ]

    /// The other processes a walk reads, found on the main actor (`running(frontmost:)`).
    /// `extras`: every running app that may show menu bar extras, that is any app but a
    /// background-only one, without the frontmost app (the walk adds it last). The owner varies
    /// with the system: Control Center and SystemUIServer up to macOS 26; on macOS 27 they have
    /// none and MenuBarAgent (Control Center, clock), Siri (`com.apple.campo`: Spotlight) and each
    /// app with a status item show them. An app without extras answers with no `AXExtrasMenuBar`.
    /// `dock`: the Dock, which shows its items; nil when it is not running.
    struct SystemProcesses: Sendable {
        var extras: [pid_t] = []
        var dock: pid_t?

        static func running(frontmost: pid_t?) -> SystemProcesses {
            let apps = NSWorkspace.shared.runningApplications
            return SystemProcesses(
                extras: ExtrasOwners.pids(
                    apps: apps.map { ($0.processIdentifier, $0.activationPolicy == .prohibited) },
                    menuBarOwner: frontmost),
                dock: apps.first { $0.bundleIdentifier == "com.apple.dock" }?.processIdentifier)
        }
    }

    let system: SystemProcesses

    init(deadline: ContinuousClock.Instant, system: SystemProcesses) {
        self.deadline = deadline
        self.system = system
    }

    /// One call; the walk reads `AXMinimized` with each window's attributes.
    func windows(of app: AXUIElement) throws -> [AXUIElement] {
        try elements(app, "AXWindows")
    }

    /// The application element's `AXMenu` children (an open context menu), one role read each,
    /// stopping at the deadline.
    func menus(of app: AXUIElement) throws -> [AXUIElement] {
        var menus: [AXUIElement] = []
        for child in try elements(app, "AXChildren") {
            if pastDeadline { break }
            AXUIElementSetMessagingTimeout(child, Self.timeout)
            if try copy(child, "AXRole").flatMap(Self.string) == "AXMenu" { menus.append(child) }
        }
        return menus
    }

    /// The app's `AXMenuBar` and its children: the top-level items only.
    func menuBar(of app: AXUIElement) throws -> [AXUIElement] {
        guard let bar = try element(app, "AXMenuBar") else { return [] }
        return try elements(bar, "AXChildren")
    }

    /// The running apps that may show extras, the menu-bar owner last (`ExtrasOwners.pids`, read
    /// on the main actor into `SystemProcesses.extras`).
    func extrasOwners(of app: AXUIElement?) -> [AXUIElement] {
        system.extras.map(Self.process(pid:))
    }

    /// A process whose extras fail sooner than this has no accessibility to answer with: it has
    /// none, and the walk is not `truncated` for it. The rule can be wrong both ways. A slow
    /// guest can turn an instant failure into one past the threshold: a spurious `truncated`, the
    /// safe side. An app still starting may answer `cannotComplete` at once: its extras are
    /// missed until the next call.
    static let instantFailure: Duration = .seconds(Double(timeout) / 2)

    /// `AXExtrasMenuBar` of one process and its children. MenuBarAgent (macOS 27) wraps each
    /// item in an `AXGroup` with no name: such a group gives its children instead, one role read
    /// each, stopping at the deadline. Throws when the process does not answer in time, so the
    /// walk says `truncated` for it alone. A process that fails at once, well before the timeout,
    /// has no accessibility to answer with (`com.apple.WebKit.Networking` has no window server
    /// connection): it has no extras, and the walk is not truncated for it.
    func extras(ofProcess process: AXUIElement) throws -> [AXUIElement] {
        AXUIElementSetMessagingTimeout(process, Self.timeout)
        let start = ContinuousClock.now
        let bar: AXUIElement?
        do {
            bar = try element(process, "AXExtrasMenuBar")
        } catch {
            if ContinuousClock.now - start < Self.instantFailure { return [] }
            throw error
        }
        guard let bar else { return [] }
        var items: [AXUIElement] = []
        for child in try elements(bar, "AXChildren") {
            if pastDeadline { break }
            AXUIElementSetMessagingTimeout(child, Self.timeout)
            // A child that stops answering ends the list: what was read stays, the walk says
            // `truncated` (`PartialList`).
            do {
                if try copy(child, "AXRole").flatMap(Self.string) == "AXGroup" {
                    items += try elements(child, "AXChildren")
                } else {
                    items.append(child)
                }
            } catch is Unresponsive {
                throw PartialList(items: items)
            }
        }
        return items
    }

    /// The Dock process's `AXList` and its children (apps, folders, the Trash).
    func dockItems() throws -> [AXUIElement] {
        guard let dockPid = system.dock else { return [] }
        let dock = Self.process(pid: dockPid)
        var items: [AXUIElement] = []
        for child in try elements(dock, "AXChildren") {
            if pastDeadline { break }
            AXUIElementSetMessagingTimeout(child, Self.timeout)
            if try copy(child, "AXRole").flatMap(Self.string) == "AXList" {
                items += try elements(child, "AXChildren")
            }
        }
        return items
    }

    private static func process(pid: pid_t) -> AXUIElement {
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, timeout)
        return element
    }

    func children(of node: AXUIElement) throws -> [AXUIElement] {
        try elements(node, "AXChildren")
    }

    func attributes(of node: AXUIElement) throws -> AXNodeAttributes {
        AXUIElementSetMessagingTimeout(node, Self.timeout)
        var raw: CFArray?
        let error = AXUIElementCopyMultipleAttributeValues(
            node, Self.attributeNames as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &raw)
        if error == .cannotComplete { throw Unresponsive() }
        guard error == .success, let values = raw as? [AnyObject], values.count == Self.attributeNames.count else {
            return AXNodeAttributes()
        }
        var attributes = AXNodeAttributes(
            role: Self.string(values[0]), subrole: Self.string(values[1]), title: Self.string(values[2]),
            description: Self.string(values[3]), value: Self.text(values[4]), enabled: Self.bool(values[5]),
            focused: Self.bool(values[6]))
        if let position = Self.point(values[7]), let size = Self.size(values[8]) {
            attributes.frame = CGRect(origin: position, size: size)
        }
        attributes.minimized = Self.bool(values[9])
        attributes.running = Self.bool(values[10])
        // Belt and braces: the walk drops it too.
        if attributes.role == "AXSecureTextField" || attributes.subrole == "AXSecureTextField" {
            attributes.value = nil
        }
        if UITreeWalker.wantsLabel(title: attributes.title, description: attributes.description,
                                   pastDeadline: pastDeadline) {
            attributes.label = try label(of: node)
        }
        return attributes
    }

    /// The title, else the value, of the element that labels `node`; never the value of a secure
    /// text field (`UITreeWalker.labelText`), which is then not even read.
    private func label(of node: AXUIElement) throws -> String? {
        guard let object = try copy(node, "AXTitleUIElement"),
              CFGetTypeID(object) == AXUIElementGetTypeID() else { return nil }
        let element = object as! AXUIElement
        AXUIElementSetMessagingTimeout(element, Self.timeout)
        let title = try copy(element, "AXTitle").flatMap(Self.string)
        if let title = UITreeWalker.labelText(title: title, value: nil, role: nil, subrole: nil) { return title }
        let role = try copy(element, "AXRole").flatMap(Self.string)
        let subrole = try copy(element, "AXSubrole").flatMap(Self.string)
        guard !UITreeWalker.isSecure(role: role, subrole: subrole) else { return nil }
        let value = try copy(element, "AXValue").flatMap(Self.string)
        return UITreeWalker.labelText(title: nil, value: value, role: role, subrole: subrole)
    }

    private func elements(_ node: AXUIElement, _ attribute: String) throws -> [AXUIElement] {
        guard let object = try copy(node, attribute), CFGetTypeID(object) == CFArrayGetTypeID() else { return [] }
        return (object as! [AnyObject]).compactMap { item in
            CFGetTypeID(item) == AXUIElementGetTypeID() ? (item as! AXUIElement) : nil
        }
    }

    private func element(_ node: AXUIElement, _ attribute: String) throws -> AXUIElement? {
        guard let object = try copy(node, attribute), CFGetTypeID(object) == AXUIElementGetTypeID() else { return nil }
        let element = object as! AXUIElement
        AXUIElementSetMessagingTimeout(element, Self.timeout)
        return element
    }

    private func copy(_ node: AXUIElement, _ attribute: String) throws -> AnyObject? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(node, attribute as CFString, &value)
        if error == .cannotComplete { throw Unresponsive() }
        return error == .success ? value : nil
    }

    // MARK: - Values

    private static func string(_ object: AnyObject) -> String? {
        CFGetTypeID(object) == CFStringGetTypeID() ? (object as! String) : nil
    }

    /// Text, or a number (a checkbox's 0/1, a slider's position) as its decimal form.
    private static func text(_ object: AnyObject) -> String? {
        if let s = string(object) { return s }
        let type = CFGetTypeID(object)
        guard type == CFNumberGetTypeID() || type == CFBooleanGetTypeID() else { return nil }
        return (object as! NSNumber).stringValue
    }

    private static func bool(_ object: AnyObject) -> Bool? {
        let type = CFGetTypeID(object)
        guard type == CFBooleanGetTypeID() || type == CFNumberGetTypeID() else { return nil }
        return (object as! NSNumber).boolValue
    }

    private static func point(_ object: AnyObject) -> CGPoint? {
        guard CFGetTypeID(object) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(object as! AXValue, .cgPoint, &point) ? point : nil
    }

    private static func size(_ object: AnyObject) -> CGSize? {
        guard CFGetTypeID(object) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(object as! AXValue, .cgSize, &size) ? size : nil
    }
}
