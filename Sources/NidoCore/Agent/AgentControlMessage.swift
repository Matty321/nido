// SPDX-License-Identifier: Apache-2.0
import Foundation
import NidoAgentKit

/// One line a local client (`nido act`, `nido mcp`) writes to the owner's control socket: a
/// single JSON object followed by `\n`. `vmID` and `bundlePath` are the VM the client means: the
/// socket's name holds only the first 8 hex digits of the id, and a bundle duplicated in Finder
/// keeps the whole id, so the owner refuses a command for another id or another bundle
/// (`notRunning`) rather than drive the wrong VM.
public struct AgentCommand: Codable, Equatable, Sendable {
    public var vmID: UUID
    /// The bundle's path as `bundlePath(_:)` gives it.
    public var bundlePath: String
    public var action: AgentAction

    public init(vmID: UUID, bundlePath: String, action: AgentAction) {
        self.vmID = vmID
        self.bundlePath = bundlePath
        self.action = action
    }

    /// `bundle`'s path, standardized with every symlink resolved (`realpath`), so the client and
    /// the owner name the same folder alike however each reached it; the standardized path when
    /// it cannot be resolved.
    public static func bundlePath(_ bundle: URL) -> String {
        let standardized = bundle.standardizedFileURL.path
        guard let resolved = realpath(standardized, nil) else { return standardized }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

/// The owner's one-line answer to an `AgentCommand`. A screenshot never travels over the socket:
/// the owner saves it in the bundle (`AgentShots`) and `path` names the file, so a client reads
/// it only if it wants the pixels. `image` and `screen` are the sizes the next coordinates refer
/// to; `error`/`message` come from the helper, from the transport, or from the owner itself
/// (`agentAccessOff`, `noScreenshot`, `badRequest`, `notRunning`).
public struct AgentAnswer: Codable, Equatable, Sendable {
    public var ok: Bool
    public var status: AgentStatus?
    public var path: String?
    public var image: PixelSize?
    public var screen: ScreenSize?
    public var error: AgentErrorCode?
    public var message: String?

    public init(ok: Bool, status: AgentStatus? = nil, path: String? = nil, image: PixelSize? = nil,
                screen: ScreenSize? = nil, error: AgentErrorCode? = nil, message: String? = nil) {
        self.ok = ok
        self.status = status
        self.path = path
        self.image = image
        self.screen = screen
        self.error = error
        self.message = message
    }

    /// A refusal: `ok` false with a code and a localized message.
    public static func failure(_ code: AgentErrorCode, _ message: String) -> AgentAnswer {
        AgentAnswer(ok: false, error: code, message: message)
    }

    /// The longest `message` kept by `cleaned`, in characters.
    static let maxMessageCharacters = 2000

    /// This answer with the text the guest can write in it (`message`, the helper's version)
    /// made safe for a terminal, a JSON line or a model: every control character (C0, DEL, C1
    /// and format characters, also line breaks) becomes a space, and the length is bounded.
    /// JSON escapes C0 controls but not C1 ones, which some terminals read as CSI or OSC: an
    /// answer is cleaned before it is printed or encoded, wherever it came from.
    public var cleaned: AgentAnswer {
        var copy = self
        copy.message = message.map { GuestSSH.sanitize($0, limit: Self.maxMessageCharacters) }
        copy.status?.helperVersion = GuestSSH.sanitize(status?.helperVersion ?? "", limit: 32)
        return copy
    }
}
