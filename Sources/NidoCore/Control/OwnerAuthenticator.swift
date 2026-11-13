// SPDX-License-Identifier: Apache-2.0
import Foundation
import LocalAuthentication

/// Asks the Mac's owner to confirm an action that widens what a VM may do (adding a domain to
/// its network list): Touch ID or the Mac password. Tests use a fake; nothing else may stand in.
public protocol OwnerAuthenticator: Sendable {
    /// True only when the owner confirmed; false when refused, cancelled or unavailable.
    /// `reason` completes macOS's prompt; pass it in the UI language.
    func authenticate(reason: String) async -> Bool
}

/// `OwnerAuthenticator` through LocalAuthentication (`deviceOwnerAuthentication`: Touch ID, or
/// the Mac password when there is no Touch ID or it fails). Works from a terminal as well.
public struct LocalOwnerAuthenticator: OwnerAuthenticator {
    public init() {}

    public func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return false }
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch {
            return false
        }
    }
}
