// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Argument vector for `/usr/bin/ssh` connecting to a guest (as `nido`, or the macOS guest's
/// account for `make`).
public enum SSHArguments {
    /// Characters ssh would reinterpret inside a quoted `UserKnownHostsFile` value
    /// (quote, escape, `%` tokens, line breaks).
    private static let forbiddenInKnownHostsPath: Set<Character> = ["\"", "\\", "%", "\n", "\r"]

    /// `argv` (including `argv[0]`): host keys are trusted on first use and pinned in the
    /// bundle's own `known_hosts`, never in the user's or the system's global one, under the VM's
    /// id (`HostKeyAlias=nido-<id>`), not its address: when DHCP gives the VM another address
    /// the same key is still required. Agent and X11 forwarding are disabled.
    ///
    /// ssh splits `UserKnownHostsFile` on whitespace and expands `%` tokens, so the path is
    /// wrapped in double quotes inside the single argument; paths containing characters that
    /// would break that quoting are refused with `.unsafePath`.
    ///
    /// `user` is the guest account (`VMConfig.sshUser`, `nido` on Linux), checked again with
    /// `VMConfig.validateSSHUser` (the config may have been edited by hand).
    ///
    /// With `controlledNetwork` every forward is cleared (`forwardsOff`): a `RemoteForward` or
    /// `Tunnel` in the user's ssh config would otherwise give the guest a path out through the
    /// Mac's ssh client, past the relay. Options placed before `extra` win over the config (ssh
    /// keeps the first value); forwards the user types on the command line are cleared too.
    ///
    /// `identity` is the key the VM was created with (`interactiveIdentity`): passed with `-i` and
    /// `IdentitiesOnly=yes`, so ssh offers that key first and not every key of the agent (a
    /// server stops after `MaxAuthTries`). An `-i` in `extra` is still offered.
    public static func make(
        endpoint: SSHEndpoint, vmID: UUID, knownHosts: URL, user: String = "nido",
        identity: String? = nil, controlledNetwork: Bool = false, extra: [String]
    ) throws -> [String] {
        try VMConfig.validateSSHUser(user)
        return ["ssh"] + (try identityOptions(identity)) + (try commonOptions(vmID: vmID, knownHosts: knownHosts))
            + (controlledNetwork ? forwardsOff : []) + portOption(endpoint) + ["\(user)@\(endpoint.host)"] + extra
    }

    /// The identity `nido ssh` passes for a VM whose public key is recorded
    /// (`VMConfig.sshPublicKeyPath`): the private key next to it when it exists, otherwise the
    /// `.pub` file itself (ssh then signs with the agent's matching key, e.g. a key kept in a
    /// password manager). nil when neither exists: ssh falls back to the user's default keys.
    public static func interactiveIdentity(
        publicKeyPath: String?, fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> String? {
        guard let publicKeyPath, !publicKeyPath.isEmpty else { return nil }
        if publicKeyPath.hasSuffix(".pub"), publicKeyPath.count > 4 {
            let privatePath = String(publicKeyPath.dropLast(4))
            if fileExists(privatePath) { return privatePath }
        }
        return fileExists(publicKeyPath) ? publicKeyPath : nil
    }

    private static func identityOptions(_ identity: String?) throws -> [String] {
        guard let identity else { return [] }
        // ssh expands `%` tokens and `~` in the identity path.
        guard !identity.contains("%"), !identity.hasPrefix("~") else { throw NidoError.unsafePath(identity) }
        return ["-i", identity, "-o", "IdentitiesOnly=yes"]
    }

    /// `-p <port>` for a port other than 22 (the `gvproxy` forward), nothing otherwise.
    private static func portOption(_ endpoint: SSHEndpoint) -> [String] {
        endpoint.port == 22 ? [] : ["-p", String(endpoint.port)]
    }

    /// Clears every port forward and tunnel, including those from the user's ssh config, and
    /// refuses remote-forward opens.
    static let forwardsOff = [
        "-o", "ClearAllForwardings=yes", "-o", "Tunnel=no", "-o", "PermitRemoteOpen=none",
    ]

    /// `argv` (including `argv[0]`) for a background command run with the user's key: only that
    /// key (`IdentitiesOnly`), never a prompt (`BatchMode`), 5 s to connect, then `--` and the one
    /// remote command string. The remote command must be built from constants (see `GuestCommand`).
    /// Options given here win over the user's `~/.ssh/config` (ssh keeps the first value), so a
    /// `Host *` there cannot replace the command (`RemoteCommand`), ask for a terminal
    /// (`RequestTTY`) or share a master connection (`ControlMaster`, `ControlPath`). The config is
    /// still read (no `-F /dev/null`), so `IdentityAgent` and the like keep working. Forwards
    /// are always cleared (`forwardsOff`): no background command needs one.
    ///
    /// `user` is `nido` on Linux and the account given at creation on macOS (`VMConfig.sshUser`,
    /// validated again). `identity` is nil only for a macOS guest reached with the user's default
    /// keys or agent, as `nido ssh` does when it finds no key: no `-i`, no `IdentitiesOnly`.
    public static func background(
        identity: String?, endpoint: SSHEndpoint, vmID: UUID, knownHosts: URL, remoteCommand: String,
        user: String = "nido"
    ) throws -> [String] {
        try VMConfig.validateSSHUser(user)
        return ["ssh"] + (try identityOptions(identity)) + ["-o", "BatchMode=yes",
         "-o", "ConnectTimeout=5", "-o", "RemoteCommand=none", "-o", "RequestTTY=no",
         "-o", "ControlMaster=no", "-o", "ControlPath=none"]
            + (try commonOptions(vmID: vmID, knownHosts: knownHosts))
            + forwardsOff
            + portOption(endpoint) + ["\(user)@\(endpoint.host)", "--", remoteCommand]
    }

    /// `argv` (including `argv[0]`) for the one command run with the guest account's password
    /// (`GuestCommand.authorizeNidoKey`): the same host key pinning, forwards off and overrides
    /// of the user's config as `background`, but no key at all (`PubkeyAuthentication=no`, no
    /// `-i`), password prompts allowed (`BatchMode=no`, answered by `SSH_ASKPASS`) and at most
    /// one (`NumberOfPasswordPrompts=1`): a wrong password fails at once instead of asking again.
    ///
    /// Unlike every other SSH use, the user's and the system's ssh config are not read at all
    /// (`-F /dev/null`): nothing there (`ProxyCommand`, `ProxyJump`, `Match exec`,
    /// `LocalCommand`, `KbdInteractiveDevices`…) can touch the login that carries the password.
    /// Everything this login needs is on the command line, keyboard-interactive and password
    /// authentication included.
    public static func passwordOnce(
        endpoint: SSHEndpoint, vmID: UUID, knownHosts: URL, remoteCommand: String, user: String
    ) throws -> [String] {
        try VMConfig.validateSSHUser(user)
        return ["ssh", "-F", "/dev/null", "-o", "BatchMode=no", "-o", "PubkeyAuthentication=no",
         "-o", "PreferredAuthentications=keyboard-interactive,password",
         "-o", "NumberOfPasswordPrompts=1",
         "-o", "KbdInteractiveAuthentication=yes", "-o", "PasswordAuthentication=yes",
         "-o", "ConnectTimeout=5", "-o", "RemoteCommand=none", "-o", "RequestTTY=no",
         "-o", "ControlMaster=no", "-o", "ControlPath=none"]
            + (try commonOptions(vmID: vmID, knownHosts: knownHosts))
            + forwardsOff
            + portOption(endpoint) + ["\(user)@\(endpoint.host)", "--", remoteCommand]
    }

    private static func commonOptions(vmID: UUID, knownHosts: URL) throws -> [String] {
        let path = knownHosts.path
        guard !path.contains(where: forbiddenInKnownHostsPath.contains) else {
            throw NidoError.unsafePath(path)
        }
        return [
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "HostKeyAlias=nido-\(vmID.uuidString.lowercased())",
            "-o", "UserKnownHostsFile=\"\(path)\"",
            "-o", "GlobalKnownHostsFile=/dev/null",
            "-o", "ForwardAgent=no",
            "-o", "ForwardX11=no",
        ]
    }
}
