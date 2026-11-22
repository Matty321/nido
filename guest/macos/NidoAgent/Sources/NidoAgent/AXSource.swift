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
        let target = await MainActor.run { () -> (pid: pid_t, name: String, process: String?)? in
            let front = NSWorkspace.shared.frontmostApplication
            guard let choice = UITreeWalker.appToWalk(windows: Self.onScreenWindows(),
                                                      frontmost: front?.processIdentifier) else { return nil }
            let app = choice.pid == front?.processIdentifier
                ? front : NSRunningApplication(processIdentifier: choice.pid)
            // Without a launch time a reused pid would pass for the old process: not remembered.
            let process = app?.launchDate.map { "\(choice.pid)@\($0.timeIntervalSinceReferenceDate)" }
            return (choice.pid, app?.localizedName ?? choice.ownerName ?? app?.bundleIdentifier ?? "", process)
        }
        guard let target else { throw NoFrontmostApp() }
        return await withCheckedContinuation { continuation in
            Self.queue.async {
                let app = AXUIElementCreateApplication(target.pid)
                AXUIElementSetMessagingTimeout(app, AXNodeReader.timeout)
                let firstContact = target.process.map { !Self.walked.contains($0) } ?? true
                let result = UITreeWalker.walkApp(
                    app: target.name, root: app, space: space, maxElements: maxElements, firstContact: firstContact,
                    source: { AXNodeReader(deadline: $0) },
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
        "AXPosition", "AXSize", "AXMinimized",
    ]

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
