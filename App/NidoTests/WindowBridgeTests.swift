// SPDX-License-Identifier: Apache-2.0
import AppKit
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
}
