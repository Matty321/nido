// SPDX-License-Identifier: Apache-2.0
import CoreServices
import Foundation
import NidoCore

/// Whether an update may be installed now: never while any VM runs, in the app or with
/// `nido start` (spec M4 §6.3). Pure, so it is tested without Sparkle.
enum UpdateGate {
    enum Decision: Equatable {
        case proceed
        /// The notice shown to the user, naming the VMs that block the update.
        case postpone(message: String)
    }

    static func decision(running: [VMName]) -> Decision {
        guard !running.isEmpty else { return .proceed }
        let names = running.map(\.rawValue).joined(separator: ", ")
        return .postpone(message: String(localized: "Nido will update when no VM is running. Running now: \(names)."))
    }

    /// The error that stops Sparkle before it offers (and so downloads) an update while a VM
    /// runs; Sparkle's window shows its description. nil: go on.
    static func proceedError(running: [VMName]) -> NSError? {
        guard case .postpone(let message) = decision(running: running) else { return nil }
        return NSError(
            domain: "io.gitlab.pichierri.Nido.updates", code: 1,
            userInfo: [NSLocalizedDescriptionKey: message])
    }

    /// The `kAEQuitReason` of a logout, restart or shutdown (and of their dialogs): the quit
    /// guard never holds those. nil (no reason: Cmd-Q, the menu, the Dock) is a user's quit.
    static func isSystemQuit(reason: OSType?) -> Bool {
        guard let reason else { return false }
        let system = [kAELogOut, kAEReallyLogOut, kAEShowRestartDialog, kAERestart, kAEShowShutdownDialog, kAEShutDown]
        return system.map { OSType($0) }.contains(reason)
    }
}
