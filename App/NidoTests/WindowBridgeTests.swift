// SPDX-License-Identifier: Apache-2.0
import AppKit
import SwiftUI
import Testing

@testable import Nido

/// A stand-in for SwiftUI's own window delegate.
private final class OtherDelegate: NSObject, NSWindowDelegate {
    var asked = 0
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        asked += 1
        return true
    }
}

@MainActor
struct WindowBridgeTests {
    private func window() -> NSWindow {
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }

    @Test func closeGuardAsksTheModelAndForwards() {
        let window = window()
        let original = OtherDelegate()
        window.delegate = original
        let bridge = WindowBridge()
        var allow = false
        bridge.shouldClose = { allow }
        bridge.attach(window)

        #expect(window.delegate is CloseGuard)
        #expect(window.delegate?.windowShouldClose?(window) == false)
        #expect(original.asked == 0, "Rifiutata dal modello: il delegato originale non viene chiamato")
        allow = true
        #expect(window.delegate?.windowShouldClose?(window) == true)
        #expect(original.asked == 1)
    }

    @Test func closeGuardIsReArmedWhenTheDelegateIsReplaced() {
        let window = window()
        let bridge = WindowBridge()
        bridge.shouldClose = { false }
        bridge.attach(window)

        // SwiftUI installs a new delegate later (e.g. around full screen).
        let replacement = OtherDelegate()
        window.delegate = replacement

        #expect(window.delegate is CloseGuard, "La conferma di chiusura deve tornare davanti al nuovo delegato")
        #expect((window.delegate as? CloseGuard)?.forward === replacement)
        #expect(window.delegate?.windowShouldClose?(window) == false)
        withExtendedLifetime(replacement) {}
    }

    /// When the window closes the bridge lets go: delegate restored, KVO and observers removed.
    @Test func closingTheWindowDetachesTheBridge() {
        let window = window()
        let original = OtherDelegate()
        window.delegate = original
        let bridge = WindowBridge()
        bridge.shouldClose = { false }
        bridge.attach(window)
        #expect(window.delegate is CloseGuard)
        #expect(bridge.isAttached)

        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)

        #expect(!bridge.isAttached)
        #expect(bridge.observerCount == 0)
        #expect(window.delegate === original, "Il delegato originale torna al suo posto")
        // KVO is gone: a later delegate change is not guarded again.
        let later = OtherDelegate()
        window.delegate = later
        #expect(window.delegate === later)
        withExtendedLifetime(later) {}
    }

    /// S11: the toolbar is a title bar accessory only in full screen; it leaves the title bar
    /// as the window starts to go back, so the windowed title strip never shows it.
    @Test func fullScreenAccessoryFollowsFullScreen() {
        let window = window()
        let bridge = WindowBridge()
        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 40))
        bridge.fullScreenAccessory = accessory
        bridge.attach(window)
        #expect(!bridge.hasAccessoryInWindow, "In finestra la barra non va nel titolo")

        let center = NotificationCenter.default
        center.post(name: NSWindow.willEnterFullScreenNotification, object: window)
        #expect(!bridge.hasAccessoryInWindow, "Durante l'animazione d'ingresso la finestra è ancora in finestra")
        center.post(name: NSWindow.didEnterFullScreenNotification, object: window)
        #expect(bridge.isFullScreen)
        #expect(bridge.hasAccessoryInWindow)
        #expect(window.titlebarAccessoryViewControllers.count == 1)

        center.post(name: NSWindow.willExitFullScreenNotification, object: window)
        #expect(!bridge.hasAccessoryInWindow, "Fuori dal titolo prima che la finestra torni")
        center.post(name: NSWindow.didExitFullScreenNotification, object: window)
        #expect(!bridge.isFullScreen)
        #expect(window.titlebarAccessoryViewControllers.isEmpty)

        // Again: added once, not twice.
        center.post(name: NSWindow.didEnterFullScreenNotification, object: window)
        center.post(name: NSWindow.didEnterFullScreenNotification, object: window)
        #expect(window.titlebarAccessoryViewControllers.count == 1)
    }

    /// An accessory handed over while the window is already in full screen goes in at once; the
    /// window closing takes it out.
    @Test func fullScreenAccessorySetLateAndRemovedOnClose() {
        let window = window()
        let bridge = WindowBridge()
        bridge.attach(window)
        NotificationCenter.default.post(name: NSWindow.didEnterFullScreenNotification, object: window)

        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 40))
        bridge.fullScreenAccessory = accessory
        #expect(bridge.hasAccessoryInWindow)

        // A new one replaces it.
        let replacement = NSTitlebarAccessoryViewController()
        replacement.view = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 40))
        bridge.fullScreenAccessory = replacement
        #expect(window.titlebarAccessoryViewControllers.count == 1)
        #expect(window.titlebarAccessoryViewControllers.first === replacement)

        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
        #expect(window.titlebarAccessoryViewControllers.isEmpty)
    }

    /// The accessory sits under the title bar, shows only while macOS reveals it in full screen,
    /// and is as tall as its content.
    @Test func titlebarAccessoryHostsTheContent() {
        let accessory = TitlebarAccessory.bottom { Text(verbatim: "Nido").padding(10) }
        #expect(accessory.layoutAttribute == .bottom)
        #expect(accessory.fullScreenMinHeight == 0)
        #expect(!accessory.automaticallyAdjustsSize)
        #expect(accessory.view.frame.height > 20)
    }
}
