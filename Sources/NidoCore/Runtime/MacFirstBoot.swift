// SPDX-License-Identifier: Apache-2.0
import Foundation
import Virtualization

/// What to hand the macOS 27 guest on its first start so it creates the account itself.
public struct MacProvisioningPlan: Equatable, Sendable {
    public let fullName: String
    public let username: String
    public let password: GuestPassword
    // Always asked for: automatic login and Remote Login.

    public init(fullName: String, username: String, password: GuestPassword) {
        self.fullName = fullName
        self.username = username
        self.password = password
    }
}

/// Decides whether a cold start carries guest provisioning. Pure, so it is unit-tested; the
/// Virtualization calls live in `VMSession.start()`.
public enum MacFirstBoot {
    /// True when every condition of `plan` holds except the password: only then is the Keychain read.
    public static func needsPassword(config: VMConfig, hostMajor: Int) -> Bool {
        guard config.guest == .macos,
            config.macProvisioningSent != true,
            let name = config.macAccountFullName, !name.isEmpty,
            config.sshUser != nil,
            hostMajor >= 27,
            let guest = guestMajor(config.osVersion), guest >= 27
        else { return false }
        return true
    }

    public static func plan(config: VMConfig, hostMajor: Int, password: GuestPassword?) -> MacProvisioningPlan? {
        guard needsPassword(config: config, hostMajor: hostMajor),
            let fullName = config.macAccountFullName, let username = config.sshUser,
            let password
        else { return nil }
        return MacProvisioningPlan(fullName: fullName, username: username, password: password)
    }

    /// Whether `validate` asks Virtualization (macOS 27 SDK and host); otherwise it accepts
    /// everything (no account is offered there: `nido create --account` and the wizard need a
    /// macOS 27 host).
    public static var canValidate: Bool {
        #if compiler(>=6.4) && arch(arm64)
        if #available(macOS 27, *) { return true }
        #endif
        return false
    }

    /// What macOS would refuse at the first start (`VZMacGuestProvisioningOptions.validate`),
    /// asked before the VM is created: an account it refuses would leave the VM unable to start.
    /// Throws `MacProvisioningError`.
    public static func validate(fullName: String, username: String, password: GuestPassword) throws {
        #if compiler(>=6.4) && arch(arm64)
        if #available(macOS 27, *) {
            let options = VZMacGuestProvisioningOptions()
            options.fullName = fullName
            options.username = username
            options.password = password.value
            do {
                try options.validate()
            } catch {
                throw provisioningError(error, password: password)
            }
        }
        #endif
    }

    /// A refusal of `VZMacGuestProvisioningOptions.validate` as `MacProvisioningError`, naming the
    /// field and macOS's reason; any other error unchanged. The reason of a refused password is
    /// left out when it contains the password.
    public static func provisioningError(_ error: any Error, password: GuestPassword) -> any Error {
        let ns = error as NSError
        guard ns.domain == VZErrorDomain else { return error }
        var reason = (ns.localizedFailureReason ?? ns.localizedDescription)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        switch ns.code {
        case 40001: return MacProvisioningError.invalidFullName(reason)
        case 40002: return MacProvisioningError.invalidUsername(reason)
        case 40003:
            if reason.contains(password.value) { reason = "" }
            return MacProvisioningError.invalidPassword(reason)
        default: return error
        }
    }

    /// Leading integer of a macOS version string ("27.2.1" gives 27).
    public static func guestMajor(_ osVersion: String?) -> Int? {
        guard let osVersion else { return nil }
        return Int(osVersion.split(separator: ".", omittingEmptySubsequences: false).first ?? "")
    }
}

/// An account macOS refuses to create at the first start (`VZMacGuestProvisioningOptions`): the
/// field and macOS's reason (in the Mac's language; empty when it was left out).
public enum MacProvisioningError: Error, Equatable, Sendable, LocalizedError {
    case invalidFullName(String)
    case invalidUsername(String)
    case invalidPassword(String)

    public var errorDescription: String? {
        switch self {
        case .invalidFullName(let reason):
            reason.isEmpty
                ? L10n.string("macOS doesn’t accept the full name of the account.")
                : L10n.string("macOS doesn’t accept the full name of the account: \(reason)")
        case .invalidUsername(let reason):
            reason.isEmpty
                ? L10n.string("macOS doesn’t accept the short name of the account.")
                : L10n.string("macOS doesn’t accept the short name of the account: \(reason)")
        case .invalidPassword(let reason):
            reason.isEmpty
                ? L10n.string("macOS doesn’t accept the password of the account.")
                : L10n.string("macOS doesn’t accept the password of the account: \(reason)")
        }
    }
}
