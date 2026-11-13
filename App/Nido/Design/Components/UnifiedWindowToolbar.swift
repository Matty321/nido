// SPDX-License-Identifier: Apache-2.0
import AppKit
import SwiftUI

extension View {
    /// Gives the hosting window the unified toolbar, whatever its scene asked for.
    ///
    /// The `Settings` scene ignores `.windowToolbarStyle(.unified)` and keeps the taller
    /// preferences toolbar: its close, minimise and zoom buttons then sit 18 pt below the middle of
    /// the 52 pt bar the view draws (measured on macOS 27). The VM settings (S08), a `WindowGroup`,
    /// honour the scene modifier and need none of this.
    func unifiedWindowToolbar() -> some View {
        background(UnifiedToolbarAccessor())
    }
}

private struct UnifiedToolbarAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowView { WindowView() }

    func updateNSView(_ view: WindowView, context: Context) { view.apply() }

    final class WindowView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
        }

        func apply() {
            guard let window, window.toolbarStyle != .unified else { return }
            window.toolbarStyle = .unified
        }
    }
}
