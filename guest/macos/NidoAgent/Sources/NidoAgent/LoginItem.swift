// SPDX-License-Identifier: Apache-2.0
import Foundation
import NidoAgentKit
import ServiceManagement

/// Opens Nido Agent at login, so the guest is reachable after every restart.
enum LoginItem {
    @MainActor static var state: LoginItemState {
        LoginItemState(status: SMAppService.mainApp.status.rawValue)
    }

    @MainActor static func registerIfNeeded() {
        let before = state
        Log.app.notice("login item status: \(before.logName, privacy: .public)")
        guard before.shouldRegister else {
            if before.needsApproval {
                Log.app.notice("login item needs approval in System Settings > General > Login Items")
            }
            return
        }
        do {
            try SMAppService.mainApp.register()
            Log.app.notice("registered as a login item, status now: \(state.logName, privacy: .public)")
        } catch {
            // Not fatal: the user can still open Nido Agent by hand or add it in System Settings.
            Log.app.error("could not register as a login item: \(String(describing: error), privacy: .public)")
        }
    }

    @MainActor static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
