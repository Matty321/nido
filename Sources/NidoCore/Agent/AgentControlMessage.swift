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
    /// Who sends it, for the activity log (`AgentCommand.Client`); nil from clients older than the
    /// log, recorded as `act`. Never sent when nil: an older owner reads the line as before.
    public var client: String?
    /// The client's own session id, kept across its connections (a `nido mcp` run sends each
    /// command on a connection of its own). Nil: the owner gives the connection one, or the last
    /// `act` session (see `AgentGate`).
    public var session: String?
    /// For `putFile`: the name of the staged file in `<bundle>/agent-files/` that holds the bytes
    /// (`AgentFiles`), which never travel in the line. Anything but a staged file's name is refused.
    public var staged: String?
    /// Set for a read-text request: a host-only request the owner turns into an ordinary `zoom`
    /// for the guest, which never learns of it. `action` is then only a carrier (`status`) that an
    /// owner older than read_text would answer harmlessly.
    public var readText: ReadTextRequest?

    public init(vmID: UUID, bundlePath: String, action: AgentAction, client: String? = nil, session: String? = nil,
                staged: String? = nil, readText: ReadTextRequest? = nil) {
        self.vmID = vmID
        self.bundlePath = bundlePath
        self.action = action
        self.client = client
        self.session = session
        self.staged = staged
        self.readText = readText
    }

    /// The values of `client`.
    public enum Client {
        /// `nido mcp`: an agent through MCP.
        public static let mcp = "mcp"
        /// `nido act`, and any client that names none.
        public static let act = "act"
        /// Nido's own status checks (the app's Agent pane, `nido agent status`, the setup):
        /// their `status` is not recorded.
        public static let nido = "nido"
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

/// A request to read the text on the guest's screen: `region` in pixels of the latest screenshot
/// (nil: all of it), at most `maxLines` lines back.
public struct ReadTextRequest: Codable, Equatable, Sendable {
    public var region: PixelRect?
    public var maxLines: Int

    public init(region: PixelRect?, maxLines: Int) {
        self.region = region
        self.maxLines = maxLines
    }
}

/// The owner's one-line answer to an `AgentCommand`. A screenshot never travels over the socket:
/// the owner saves it in the bundle (`AgentShots`) and `path` names the file, so a client reads
/// it only if it wants the pixels. Nor does a file got from the guest: `staged` names it in
/// `<bundle>/agent-files/` (`AgentFiles`), for the client to read and delete. `image` and `screen` are the sizes the next coordinates refer
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
    /// The controls of the frontmost app (`uiTree`); frames are in pixels of the last screenshot.
    public var tree: UITree?
    /// The agent checkpoints, newest first (`checkpoints`).
    public var checkpoints: [AgentCheckpointInfo]?
    /// The checkpoint just taken (`checkpoint`), or the one a rollback goes back to (`rollback`).
    public var checkpoint: AgentCheckpointInfo?
    /// One folder level of `~/NidoTransfer` (`listFiles`), newest first.
    public var files: [TransferEntry]?
    /// The text found on the screen, top to bottom, frames in pixels of the latest screenshot
    /// (a read-text request).
    public var lines: [TextLine]?
    /// More entries than `files` holds (`listFiles`), or more lines than asked for (read text).
    public var truncated: Bool?
    /// The size of the file written (`putFile`) or got (`getFile`), in bytes.
    public var bytes: Int?
    /// The staged file that holds what `getFile` got (`AgentFiles`).
    public var staged: String?
    /// The text on the guest's clipboard (`readClipboard`); `truncated` says the guest cut it.
    public var clipboard: String?

    public init(ok: Bool, status: AgentStatus? = nil, path: String? = nil, image: PixelSize? = nil,
                screen: ScreenSize? = nil, error: AgentErrorCode? = nil, message: String? = nil,
                tree: UITree? = nil, checkpoints: [AgentCheckpointInfo]? = nil,
                checkpoint: AgentCheckpointInfo? = nil, files: [TransferEntry]? = nil, lines: [TextLine]? = nil,
                truncated: Bool? = nil,
                bytes: Int? = nil, staged: String? = nil, clipboard: String? = nil) {
        self.ok = ok
        self.status = status
        self.path = path
        self.image = image
        self.screen = screen
        self.error = error
        self.message = message
        self.tree = tree
        self.checkpoints = checkpoints
        self.checkpoint = checkpoint
        self.files = files
        self.lines = lines
        self.truncated = truncated
        self.bytes = bytes
        self.staged = staged
        self.clipboard = clipboard
    }

    /// A refusal: `ok` false with a code and a localized message.
    public static func failure(_ code: AgentErrorCode, _ message: String) -> AgentAnswer {
        AgentAnswer(ok: false, error: code, message: message)
    }

    /// The longest `message` kept by `cleaned`, in characters.
    static let maxMessageCharacters = 2000

    /// The longest app name, role, name or value of a tree kept by `cleaned`, in characters.
    static let maxTreeTextCharacters = 200

    /// The longest file name of a `listFiles` entry kept by `cleaned`, in characters (a file
    /// name has at most 255 bytes).
    static let maxFileNameCharacters = 255

    /// This answer with the text the guest can write in it (`message`, the helper's version)
    /// made safe for a terminal, a JSON line or a model: every control character (C0, DEL, C1
    /// and format characters, also line breaks) becomes a space, and the length is bounded.
    /// JSON escapes C0 controls but not C1 ones, which some terminals read as CSI or OSC: an
    /// answer is cleaned before it is printed or encoded, wherever it came from.
    public var cleaned: AgentAnswer {
        var copy = self
        copy.message = message.map { GuestSSH.sanitize($0, limit: Self.maxMessageCharacters) }
        copy.status?.helperVersion = GuestSSH.sanitize(status?.helperVersion ?? "", limit: 32)
        // A checkpoint's name comes from a `meta.json` in the bundle: printed, it must stay one line.
        copy.checkpoint?.name = GuestSSH.sanitize(checkpoint?.name ?? "", limit: VMName.maxLength)
        copy.checkpoints = checkpoints?.map {
            AgentCheckpointInfo(name: GuestSSH.sanitize($0.name, limit: VMName.maxLength), createdAt: $0.createdAt)
        }
        if let tree {
            // Every string of a tree is written by an app in the guest. A name that is only
            // controls becomes empty: it would otherwise print as a blank name.
            copy.tree = UITree(
                app: GuestSSH.sanitize(tree.app, limit: Self.maxTreeTextCharacters),
                elements: tree.elements.map { element in
                    var e = element
                    e.role = GuestSSH.sanitize(element.role, limit: Self.maxTreeTextCharacters)
                    e.name = element.name.map { GuestSSH.sanitize($0, limit: Self.maxTreeTextCharacters) }
                    e.value = element.value.map { GuestSSH.sanitize($0, limit: Self.maxTreeTextCharacters) }
                    // A password field never shows its text, whatever the guest sent.
                    if e.role == "secureTextField" { e.value = nil }
                    return e
                },
                truncated: tree.truncated)
        }
        // A file name in the guest can hold any character but `/` and NUL: printed, each entry
        // must stay one line. A kind is only ever `file` or `folder`.
        copy.files = files?.map { entry in
            var e = entry
            e.name = GuestSSH.sanitize(entry.name, limit: Self.maxFileNameCharacters)
            e.kind = entry.kind == TransferEntry.folder ? TransferEntry.folder : TransferEntry.file
            return e
        }
        // The text on the screen is written by whatever the guest shows.
        copy.lines = lines?.map {
            TextLine(text: GuestSSH.sanitize($0.text, limit: Self.maxTreeTextCharacters), frame: $0.frame)
        }
        // The clipboard is guest text too, but a document: lines and tabs stay. The guest holds it
        // to `AgentProtocol.maxClipboardBytes`; a guest that sends more is cut here, at a
        // character boundary, and `truncated` says so.
        if let clipboard {
            let clean = GuestSSH.sanitizeMultiline(clipboard)
            let limit = AgentProtocol.maxClipboardBytes
            if clean.utf8.count > limit {
                var kept = ""
                var bytes = 0
                for character in clean {
                    bytes += character.utf8.count
                    if bytes > limit { break }
                    kept.append(character)
                }
                copy.clipboard = kept
                copy.truncated = true
            } else {
                copy.clipboard = clean
            }
        }
        return copy
    }
}

/// An agent checkpoint as the owner answers it: an agent sees only the name and when it was
/// taken, never the snapshot's id, nor any snapshot of the user's.
public struct AgentCheckpointInfo: Codable, Equatable, Sendable {
    public var name: String
    public var createdAt: Date

    public init(name: String, createdAt: Date) {
        self.name = name
        self.createdAt = createdAt
    }
}
