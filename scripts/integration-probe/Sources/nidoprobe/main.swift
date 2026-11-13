// SPDX-License-Identifier: Apache-2.0
// Helper of scripts/integration-linux.sh (not shipped): drives the NidoCore paths the app uses,
// on a VM of a temporary root, where the CLI has no command for them.
//
//   nidoprobe run <root> <vm> [--real-router]
//       Runs the VM as the app does: `app` lock, interactive SerialConsole, VMSession, the AI
//       bridge attached on vsock 7701 with DebugFakeRouter + an in-memory token (no network, never
//       the Keychain). `--real-router` (only for NIDO_TEST_HF=1, after the user's confirmation):
//       the app's real services, router.huggingface.co with the token of the user's Keychain.
//       Then reads commands on stdin, one per line:
//         monitor <seconds>   polls the guest monitor (vsock 7700) until it answers
//         enable <model…>     writes aiBridge {enabled, allowedModels} into the VM's config
//         disable             writes aiBridge {enabled: false}
//         stop                graceful stop, then exit
//   nidoprobe guest-tools <root> <vm>     GuestToolsInstaller over SSH (VM run by `nido start`)
//   nidoprobe panic-settings <root> <vm>  GuestCommand.applyPanicSettings over SSH
//   nidoprobe ollama <root> <vm> install|verify|status|pull <model>|chat <model> <prompt>
//       AIRuntime over SSH (phase 2; downloads in the guest: only with NIDO_TEST_OLLAMA=1)
// Every output line starts with "nidoprobe:"; the exit status is 0 only on success.
import Foundation
import NidoCore
import Synchronization

let started = Date()

func say(_ text: String) {
    print(String(format: "nidoprobe: [%7.2f s] ", Date().timeIntervalSince(started)) + text)
    fflush(stdout)
}

func fail(_ text: String) -> Never {
    say("ERROR " + text)
    exit(1)
}

func describe(_ error: any Error) -> String {
    let localized = (error as? LocalizedError)?.errorDescription ?? ""
    return "\(error)" + (localized.isEmpty ? "" : " :: \(localized)")
}

let args = CommandLine.arguments
guard args.count >= 4 else {
    fail("usage: nidoprobe run|guest-tools|panic-settings|ollama <root> <vm> [...]")
}
let paths = NidoPaths(root: URL(fileURLWithPath: args[2], isDirectory: true))
let name: VMName
do { name = try VMName(args[3]) } catch { fail("invalid name: \(args[3])") }

/// stdin lines, read on a thread of their own (readLine blocks).
func stdinLines() -> AsyncStream<String> {
    AsyncStream { continuation in
        Thread {
            while let line = readLine() { continuation.yield(line) }
            continuation.finish()
        }.start()
    }
}

func summary(_ status: GuestStatus) -> String {
    let cpu = status.cpu.map { "cpu=\($0.usagePercent.map { String($0) } ?? "?")% vcpus=\($0.vcpus ?? 0)" } ?? "cpu=?"
    let memory = status.memory.map { "ram=\($0.totalGiB ?? 0)GiB" } ?? "ram=?"
    let steps = (status.provisioning?.steps ?? [:]).keys.sorted().joined(separator: ",")
    return "agent=\(status.agent ?? "?") version=\(status.version ?? "?") hostname=\(status.hostname ?? "?") "
        + "\(cpu) \(memory) status=\(status.status) arch=\(status.system?.architecture ?? "?") steps=[\(steps)]"
}

@MainActor
func runVM() async throws {
    let bundle = try VMBundle.open(name, paths: paths)
    let lock = try BundleLock.acquire(bundle, owner: .app)
    defer { lock.release() }
    let console = try SerialConsole(logURL: bundle.consoleLogURL)
    let session = try VMSession(
        bundle: bundle, serialConsole: console, display: nil, imageCache: ImageStore.defaultCacheRoot())
    let services = args.contains("--real-router")
        ? AIBridgeServices(router: URLSessionRouterClient(), tokenStore: KeychainTokenStore())
        : AIBridgeServices(router: DebugFakeRouter(), tokenStore: DebugMemoryTokenStore())
    say("router: \(args.contains("--real-router") ? "router.huggingface.co (real)" : "fake (DebugFakeRouter)")")
    let host = try services.makeHost(for: bundle)
    say("bridge attached: \(session.attachAIBridge(host))")
    let outcome = try await session.startOrResume()
    say("started: \(outcome) state=\(session.state)")
    let client = GuestMonitorClient(channel: VsockGuestChannel(session: session))
    for await line in stdinLines() {
        let parts = line.split(separator: " ").map(String.init)
        switch parts.first {
        case "monitor":
            let limit = TimeInterval(parts.dropFirst().first ?? "") ?? 300
            let begin = Date()
            var lastError = "nessun tentativo"
            var answered = false
            while Date().timeIntervalSince(begin) < limit {
                do {
                    let status = try await client.fetch()
                    say("monitor ok after \(String(format: "%.1f", Date().timeIntervalSince(begin))) s: \(summary(status))")
                    answered = true
                    break
                } catch {
                    lastError = describe(error)
                    try await Task.sleep(for: .seconds(1))
                }
            }
            if !answered { say("ERROR monitor gave no answer within \(Int(limit)) s: \(lastError)") }
        case "enable":
            let models = Array(parts.dropFirst())
            try bundle.updateConfig {
                $0.aiBridge = AIBridgePolicy(enabled: true, allowedModels: models, privacyAcknowledged: true)
            }
            say("bridge on for \(models)")
        case "disable":
            try bundle.updateConfig { $0.aiBridge = AIBridgePolicy(enabled: false) }
            say("bridge off")
        case "stop":
            await session.stop(gracePeriod: .seconds(60))
            say("stopped: \(session.state)")
            return
        default:
            say("unknown command: \(line)")
        }
    }
    await session.stop(gracePeriod: .seconds(60))
    say("stdin closed: stopped (\(session.state))")
}

func guestTools() async throws {
    let bundle = try VMBundle.open(name, paths: paths)
    let outcome = try await GuestToolsInstaller().install(on: bundle)
    let config = try bundle.readConfig()
    say("Guest Tools: \(outcome), guestToolsVersion=\(config.guestToolsVersion ?? "nil")")
    let ssh = GuestSSH(bundle: bundle, config: config, runner: SystemProcessRunner())
    let active = try await ssh.run(.isServiceActive("nido-guest-tools"), timeout: .seconds(30))
    say("nido-guest-tools: \(active.stdout.trimmingCharacters(in: .whitespacesAndNewlines))")
}

func panicSettings() async throws {
    let bundle = try VMBundle.open(name, paths: paths)
    let ssh = GuestSSH(bundle: bundle, config: try bundle.readConfig(), runner: SystemProcessRunner())
    _ = try await ssh.run(.applyPanicSettings, timeout: .seconds(180))
    say("panic settings applied")
}

func ollama(_ action: [String]) async throws {
    let runtime = try AIRuntime(bundle: VMBundle.open(name, paths: paths))
    switch action.first {
    case "install":
        try await runtime.install()
        say("ollama installed")
    case "verify":
        try await runtime.verify()
        say("ollama verified")
    case "status":
        let status = try await runtime.status()
        say("installed=\(status.installed) version=\(status.version ?? "-") running=\(status.running) "
            + "pinned=\(status.pinnedVersion ?? "-") models=\(status.models.map { "\($0.name) \($0.sizeBytes)" })")
    case "pull" where action.count == 2:
        let last = Mutex(Date.distantPast)
        try await runtime.pull(model: action[1]) { progress in
            // One line every 10 s at most: enough to see it move.
            let due = last.withLock { last in
                guard Date().timeIntervalSince(last) >= 10 else { return false }
                last = Date()
                return true
            }
            if due {
                say("downloading \(progress.completedBytes)/\(progress.totalBytes) \(progress.message)")
            }
        }
        say("model \(action[1]) downloaded")
    case "chat" where action.count == 3:
        var answer = ""
        for try await event in runtime.chat(model: action[1], messages: [ChatMessage(role: .user, content: action[2])]) {
            if case .piece(let piece) = event { answer += piece }
        }
        let flat = answer.replacingOccurrences(of: "\n", with: " ")
        say("answer (\(answer.count) characters): \(flat.prefix(200))")
        if answer.isEmpty { fail("empty answer") }
    default:
        fail("unknown ollama action: \(action)")
    }
}

do {
    switch args[1] {
    case "run": try await runVM()
    case "guest-tools": try await guestTools()
    case "panic-settings": try await panicSettings()
    case "ollama": try await ollama(Array(args.dropFirst(4)))
    default: fail("unknown mode: \(args[1])")
    }
} catch {
    fail(describe(error))
}
exit(0)
