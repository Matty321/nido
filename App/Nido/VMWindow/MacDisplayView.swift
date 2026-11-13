// SPDX-License-Identifier: Apache-2.0
import AppKit
import SwiftUI
import Virtualization

/// The screen of a macOS guest (S07 macOS): a `GuestDisplayView` on the session's machine.
/// The guest's resolution follows the window (`automaticallyReconfiguresDisplay`); system keys
/// (⌘Tab, ⌘Space…) go to the guest only in full screen. A reopened window makes a new view on the
/// same machine (the session lives in `VMSessionStore`, not in the window).
struct MacDisplayView: NSViewRepresentable {
    let machine: VZVirtualMachine
    let isFullScreen: Bool
    /// Hands the view to the window, for "Digita nella VM".
    let controller: MacDisplayController

    func makeNSView(context: Context) -> GuestDisplayView {
        let view = GuestDisplayView()
        view.automaticallyReconfiguresDisplay = true
        configure(view)
        return view
    }

    func updateNSView(_ view: GuestDisplayView, context: Context) {
        configure(view)
    }

    static func dismantleNSView(_ view: GuestDisplayView, coordinator: ()) {
        // The machine keeps running; only this view lets go of it.
        view.virtualMachine = nil
    }

    private func configure(_ view: GuestDisplayView) {
        if view.virtualMachine !== machine { view.virtualMachine = machine }
        if view.capturesSystemKeys != isFullScreen { view.capturesSystemKeys = isFullScreen }
        controller.view = view
    }
}

/// `VZVirtualMachineView` that can hold back the user's own keys while Nido types a command, so
/// a real Return cannot run half of it; Nido's keys go through `inject`.
final class GuestDisplayView: VZVirtualMachineView {
    /// True while "Digita nella VM" types: real key events are dropped.
    var blocksUserKeys = false

    override func keyDown(with event: NSEvent) {
        if !blocksUserKeys { super.keyDown(with: event) }
    }

    override func keyUp(with event: NSEvent) {
        if !blocksUserKeys { super.keyUp(with: event) }
    }

    override func flagsChanged(with event: NSEvent) {
        if !blocksUserKeys { super.flagsChanged(with: event) }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // ⌘-keys while typing would reach the guest (or the menu) mid-command: swallowed.
        blocksUserKeys ? true : super.performKeyEquivalent(with: event)
    }

    /// One of Nido's own key events, past the block.
    func inject(_ event: NSEvent) {
        switch event.type {
        case .keyDown: super.keyDown(with: event)
        case .keyUp: super.keyUp(with: event)
        default: super.flagsChanged(with: event)
        }
    }
}

/// The window's handle on its `GuestDisplayView`: types keys into the guest as if pressed on the
/// Mac's keyboard (key down and key up, Shift and Option around them), paced so the guest drops
/// none. Stops as soon as the VM is no longer running or the view is gone.
@MainActor
final class MacDisplayController: KeystrokeSink {
    weak var view: GuestDisplayView?

    /// Between two events: the guest reads keys from a USB-like queue that drops bursts.
    nonisolated static let eventGap: Duration = .milliseconds(12)

    nonisolated private static let shiftKeyCode: UInt16 = 56
    nonisolated private static let optionKeyCode: UInt16 = 58

    /// One synthetic keyboard event, before it becomes an `NSEvent`.
    struct KeyEvent: Equatable {
        var type: NSEvent.EventType
        var keyCode: UInt16
        var flags: NSEvent.ModifierFlags
        var characters: String
    }

    func type(_ strokes: [Keystroke]) async throws {
        guard let view, let window = view.window, view.virtualMachine != nil else { throw KeystrokeError.noDisplay }
        window.makeFirstResponder(view)
        view.blocksUserKeys = true
        defer { self.view?.blocksUserKeys = false }
        try await Self.run(
            strokes,
            emit: { event in
                try await self.send(event.type, keyCode: event.keyCode, flags: event.flags, characters: event.characters)
            },
            release: { event in self.inject(event) })
    }

    /// Plays `strokes` through `emit`. If `emit` throws (VM stopped, window closed) or the task is
    /// cancelled while Shift or Option is down, `release` gets a key-up (flagsChanged) for each held
    /// modifier, so the guest never keeps one held. `release` must not suspend or throw.
    static func run(_ strokes: [Keystroke], emit: (KeyEvent) async throws -> Void,
                    release: (KeyEvent) -> Void) async throws {
        // `flags` is what the guest may hold. A modifier is marked held BEFORE its key-down is sent
        // (`send` can throw after the event was delivered, for instance when its pause is cancelled)
        // and cleared only after its key-up succeeded. An extra release is harmless.
        var flags: NSEvent.ModifierFlags = []
        func flagsEvent(_ keyCode: UInt16, _ next: NSEvent.ModifierFlags) -> KeyEvent {
            KeyEvent(type: .flagsChanged, keyCode: keyCode, flags: next, characters: "")
        }
        do {
            for stroke in strokes {
                if stroke.shift {
                    flags.insert(.shift)
                    try await emit(flagsEvent(shiftKeyCode, flags))
                }
                if stroke.option {
                    flags.insert(.option)
                    try await emit(flagsEvent(optionKeyCode, flags))
                }
                try await emit(KeyEvent(type: .keyDown, keyCode: stroke.keyCode, flags: flags, characters: stroke.character))
                try await emit(KeyEvent(type: .keyUp, keyCode: stroke.keyCode, flags: flags, characters: stroke.character))
                if stroke.option {
                    try await emit(flagsEvent(optionKeyCode, flags.subtracting(.option)))
                    flags.remove(.option)
                }
                if stroke.shift {
                    try await emit(flagsEvent(shiftKeyCode, flags.subtracting(.shift)))
                    flags.remove(.shift)
                }
            }
        } catch {
            // Option went down after Shift, so it comes up first.
            if flags.contains(.option) {
                flags.remove(.option)
                release(flagsEvent(optionKeyCode, flags))
            }
            if flags.contains(.shift) {
                flags.remove(.shift)
                release(flagsEvent(shiftKeyCode, flags))
            }
            throw error
        }
    }

    /// Sends a release event with no state check and no pause: it runs after a failure, even a
    /// cancellation, and the guest must see it.
    private func inject(_ event: KeyEvent) {
        guard let view, let window = view.window, let nsEvent = Self.nsEvent(event, windowNumber: window.windowNumber)
        else { return }
        view.inject(nsEvent)
    }

    /// Left Shift and left Option as a real key reports them: the generic flag plus the key's
    /// device bit (IOKit NX_DEVICELSHIFTKEYMASK, NX_DEVICELALTKEYMASK). The guest's keyboard
    /// tracks the device bits: with the generic flag alone it never sees Shift held, and "$" comes
    /// out as "4".
    nonisolated private static let leftShiftDeviceBit: UInt = 0x02
    nonisolated private static let leftOptionDeviceBit: UInt = 0x20

    static func nsEvent(_ event: KeyEvent, windowNumber: Int) -> NSEvent? {
        var raw = event.flags.rawValue
        if event.flags.contains(.shift) { raw |= leftShiftDeviceBit }
        if event.flags.contains(.option) { raw |= leftOptionDeviceBit }
        return NSEvent.keyEvent(
            with: event.type, location: .zero, modifierFlags: NSEvent.ModifierFlags(rawValue: raw),
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: windowNumber, context: nil,
            characters: event.characters, charactersIgnoringModifiers: event.characters, isARepeat: false,
            keyCode: event.keyCode)
    }

    private func send(_ type: NSEvent.EventType, keyCode: UInt16, flags: NSEvent.ModifierFlags,
                      characters: String) async throws {
        // The window may close, or the VM stop or pause, while typing: stop there.
        guard let view, let window = view.window, let machine = view.virtualMachine else {
            throw KeystrokeError.noDisplay
        }
        guard machine.state == .running else { throw KeystrokeError.vmNotRunning }
        guard let event = Self.nsEvent(KeyEvent(type: type, keyCode: keyCode, flags: flags, characters: characters),
                                       windowNumber: window.windowNumber)
        else { throw KeystrokeError.noDisplay }
        view.inject(event)
        try await Task.sleep(for: Self.eventGap)
    }
}
