// SPDX-License-Identifier: Apache-2.0

/// Whether Nido Agent opens at login, as `SMAppService.mainApp.status` reports it. The raw values
/// are those of `SMAppService.Status`.
public enum LoginItemState: Int, Sendable, Equatable, CaseIterable {
    case notRegistered = 0
    case enabled = 1
    case requiresApproval = 2
    /// Also what macOS 26 reports for `SMAppService.mainApp` before the app was ever registered
    /// (Background Task Management has no record of it), not only after a failure.
    case notFound = 3

    /// An unknown raw value (a newer macOS) counts as `notFound`: registering again is harmless.
    public init(status rawValue: Int) {
        self = LoginItemState(rawValue: rawValue) ?? .notFound
    }

    /// Whether the helper should call `register()`. `notFound` is included: on macOS 26 it is the
    /// status of a helper never registered, and skipping it left the helper off at every login.
    /// `requiresApproval` is not: only the user can approve it, in System Settings.
    public var shouldRegister: Bool {
        switch self {
        case .notRegistered, .notFound: true
        case .enabled, .requiresApproval: false
        }
    }

    /// Whether the user must turn it on in System Settings › General › Login Items.
    public var needsApproval: Bool { self == .requiresApproval }

    /// A stable name for the log.
    public var logName: String {
        switch self {
        case .notRegistered: "notRegistered"
        case .enabled: "enabled"
        case .requiresApproval: "requiresApproval"
        case .notFound: "notFound"
        }
    }
}
