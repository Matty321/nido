// SPDX-License-Identifier: Apache-2.0
import ApplicationServices
import CoreGraphics
import Foundation
import NidoAgentKit
import os

enum Log {
    static let subsystem = "io.gitlab.pichierri.Nido.Agent"
    static let app = Logger(subsystem: subsystem, category: "app")
    static let listener = Logger(subsystem: subsystem, category: "listener")
    static let capture = Logger(subsystem: subsystem, category: "capture")
    static let input = Logger(subsystem: subsystem, category: "input")
}

/// The only two permissions Nido Agent uses: Screen Recording (screenshots) and
/// Accessibility (posting mouse and keyboard events). Reading them never prompts.
struct SystemPermissions: PermissionState {
    var screenRecording: Bool { CGPreflightScreenCaptureAccess() }
    var accessibility: Bool { AXIsProcessTrusted() }

    static let screenRecordingSettings = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
    static let accessibilitySettings = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!

    private static let promptedKey = "PromptedForPermissions"

    /// On first launch, asks macOS once for each permission so Nido Agent appears in both
    /// lists in System Settings. Later launches only show the permissions window.
    static func promptOnFirstLaunch() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: promptedKey) else { return }
        defaults.set(true, forKey: promptedKey)
        Log.app.notice("first launch: asking for Screen Recording and Accessibility")
        if !CGPreflightScreenCaptureAccess() {
            _ = CGRequestScreenCaptureAccess()
        }
        if !AXIsProcessTrusted() {
            // "AXTrustedCheckOptionPrompt" is the value of kAXTrustedCheckOptionPrompt, a C global
            // that Swift 6 treats as shared mutable state.
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        }
    }
}
