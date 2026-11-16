// SPDX-License-Identifier: Apache-2.0
import Foundation
import NidoAgentKit

/// Starts the agent control socket in the process that owns a running macOS VM (`nido start` or
/// Nido.app), for a VM whose `agentAccess` is on.
public enum AgentHost {
    /// Serves `bundle`'s control socket, forwarding each command to Nido Agent in the guest over
    /// the session's vsock. Returns nil, starting nothing, unless the VM is a macOS guest with
    /// `agentAccess` on and the session has a socket device. A socket that cannot be made is not
    /// a failed start: `onWarning` gets one localized line and the VM runs without the socket.
    ///
    /// The command closure holds the session weakly: a command still running when the VM ends
    /// does not keep the machine alive, and gets `.notReady`. The owner calls `stop()` on the
    /// returned server when the session ends or is replaced.
    ///
    /// `onActivity` gets `true` before each forwarded command other than `status` and `false`
    /// after it (also when it fails), from any thread, so it must be thread-safe: the app shows
    /// "an agent is using this VM" from it.
    @MainActor
    public static func startIfEnabled(
        session: VMSession, bundle: VMBundle, config: VMConfig,
        root: URL = AgentControlServer.defaultRoot, onWarning: (String) -> Void = { _ in },
        onActivity: @escaping @Sendable (Bool) -> Void = { _ in }
    ) -> AgentControlServer? {
        serve(
            config: config, hasSocketDevice: session.socketDevice != nil, onWarning: onWarning,
            start: {
                try AgentControlServer.start(
                    bundle: bundle, vmID: config.id,
                    perform: reportingActivity(
                        { @Sendable [weak session] request async throws(AgentFailure) -> (AgentReply, Data?) in
                            guard let session else {
                                throw AgentFailure(code: .notReady, message: L10n.string("waiting for login or Nido Agent"))
                            }
                            return try await AgentClient(channel: VsockGuestChannel(session: session)).perform(request)
                        }, onActivity: onActivity),
                    root: root)
            })
    }

    /// How long the password stays on the guest's clipboard, in seconds.
    public static let clipboardClearSeconds = 60

    /// Puts `text` on the guest's clipboard through Nido Agent, straight over `session`'s vsock:
    /// only the VM's owner does it (the control socket refuses `setClipboard`). Nido Agent clears
    /// it after `clearAfter` seconds unless something else was copied in the guest meanwhile. The
    /// Mac's own clipboard is never touched, and the text is never logged nor put in the answer.
    /// An older Nido Agent answers `badRequest`.
    ///
    /// This path skips the agent-access check (`VMConfig.agentAccess`) on purpose: the check
    /// guards what an outside client (an MCP agent) may do through the control socket, and the
    /// owner of the VM at the Mac is not one. It still needs a running session with a vsock
    /// device; without one the answer is `notRunning`.
    @MainActor
    public static func setClipboard(_ text: String, clearAfter: Int, session: VMSession) async -> AgentAnswer {
        let client = AgentClient(channel: VsockGuestChannel(session: session))
        return await setClipboard(text, clearAfter: clearAfter, perform: { request throws(AgentFailure) in
            try await client.perform(request)
        })
    }

    /// `setClipboard` with the helper injected: every outcome is an answer, cleaned like every
    /// answer the guest can write in.
    static func setClipboard(
        _ text: String, clearAfter: Int,
        perform: @Sendable (AgentRequest) async throws(AgentFailure) -> (AgentReply, Data?)
    ) async -> AgentAnswer {
        do {
            let (reply, _) = try await perform(AgentRequest(action: .setClipboard(text: text, clearAfter: clearAfter)))
            return AgentAnswer(ok: reply.ok, error: reply.error, message: reply.message).cleaned
        } catch {
            return AgentAnswer.failure(error.code, error.message).cleaned
        }
    }

    /// `perform` with `onActivity(true)` before each request and `onActivity(false)` after it,
    /// also when it throws. `status` is not activity: Nido asks it itself (the Agent pane every
    /// 3 s, setup's wait every 2 s), and it neither sees nor touches the guest's screen.
    static func reportingActivity(
        _ perform: @escaping @Sendable (AgentRequest) async throws(AgentFailure) -> (AgentReply, Data?),
        onActivity: @escaping @Sendable (Bool) -> Void
    ) -> @Sendable (AgentRequest) async throws(AgentFailure) -> (AgentReply, Data?) {
        { @Sendable request async throws(AgentFailure) -> (AgentReply, Data?) in
            if case .status = request.action { return try await perform(request) }
            onActivity(true)
            defer { onActivity(false) }
            return try await perform(request)
        }
    }

    /// `bundle`'s `config.json` for `startIfEnabled`, read again once the VM runs. A read that
    /// fails is the usual one-line warning through `onWarning`, never a silent "no agent access".
    public static func readConfig(_ bundle: VMBundle, onWarning: (String) -> Void) -> VMConfig? {
        do {
            return try bundle.readConfig()
        } catch {
            onWarning(L10n.string("Agent access isn’t available: \(error.localizedDescription)"))
            return nil
        }
    }

    /// Whether the owner serves the socket: a macOS guest with `agentAccess` on and a vsock device.
    static func shouldServe(config: VMConfig, hasSocketDevice: Bool) -> Bool {
        config.guest == .macos && config.agentAccess == true && hasSocketDevice
    }

    /// The decision and the failure handling of `startIfEnabled`, with `start` injected.
    static func serve(
        config: VMConfig, hasSocketDevice: Bool, onWarning: (String) -> Void,
        start: () throws -> AgentControlServer
    ) -> AgentControlServer? {
        guard shouldServe(config: config, hasSocketDevice: hasSocketDevice) else { return nil }
        do {
            return try start()
        } catch {
            onWarning(L10n.string("Agent access isn’t available: \(error.localizedDescription)"))
            return nil
        }
    }
}
