// SPDX-License-Identifier: Apache-2.0
#if DEBUG
    import Darwin
    import Foundation
    import NidoCore
    import Synchronization

    /// DEBUG `-NidoFakeGuest "debian-ai=values+ollama,…"` (with fake sessions): what the guest of a
    /// fake VM answers, so the screenshot tests find the M3c screens (S13 Monitor, S14 Preparazione,
    /// S15 AI) in fixed states without booting a guest. Never the network, never SSH.
    ///
    /// One monitor word (default `values`) and any number of extras, joined by `+`:
    /// - monitor: `values`, `alerts`, `waiting` (nothing listens yet), `missing` (no vsock device),
    ///   `error` (an answer that is not a status), `version` (protocol 3.0), `stale` (one answer,
    ///   then silence: "dati vecchi" after 10 s), `stops` (values, then the VM stops by itself
    ///   after 6 s: "ultimo campione");
    /// - Ollama: `ollama` (installed, two models), `phase2` (installs at once, then the model
    ///   download stays at 46 %), `phase2-done` (everything at once), `phase2-fails` (the model
    ///   download fails), `ssh-key` (the private key cannot be used); none of them: not installed;
    /// - `no-bridge`: the session could not attach the AI bridge.
    struct FakeGuest: Equatable, Sendable {
        enum Monitor: String, Sendable, CaseIterable {
            case values, alerts, waiting, missing, error, version, stale, stops
        }

        enum Ollama: String, Sendable, CaseIterable {
            case absent
            case installed = "ollama"
            case phase2
            case phase2Done = "phase2-done"
            case phase2Fails = "phase2-fails"
            case sshKey = "ssh-key"
        }

        var monitor: Monitor = .values
        var ollama: Ollama = .absent
        var bridgeAttached = true

        /// Parses `name=word+word,name=word`; nil when malformed or a word is unknown.
        nonisolated static func parse(_ text: String) -> [String: FakeGuest]? {
            var result: [String: FakeGuest] = [:]
            for item in text.split(separator: ",") {
                let parts = item.split(separator: "=", omittingEmptySubsequences: false)
                guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
                var guest = FakeGuest()
                for word in parts[1].split(separator: "+").map(String.init) {
                    if let monitor = Monitor(rawValue: word) {
                        guest.monitor = monitor
                    } else if let ollama = Ollama(rawValue: word), ollama != .absent {
                        guest.ollama = ollama
                    } else if word == "no-bridge" {
                        guest.bridgeAttached = false
                    } else {
                        return nil
                    }
                }
                result[String(parts[0])] = guest
            }
            return result.isEmpty ? nil : result
        }

        /// The design's guest (S13): 4 vCPU, 3,9 GiB, no swap, 31,3 GiB disk.
        static func statusJSON(alerts: Bool, version: String = "2.0") -> String {
            let cpu = alerts ? 94.2 : 23.4
            let diskUsed = alerts ? 29.1 : 12.1
            let warnings = alerts ? #"["CPU elevata", "Disco quasi pieno"]"# : "[]"
            return """
                {"agent": "Nido AI Monitor", "version": "\(version)", "timestamp": "2026-10-25T08:42:18+00:00",
                 "hostname": "debian-ai",
                 "system": {"hostname": "debian-ai", "architecture": "aarch64",
                            "kernel": "6.12.48+deb13-arm64", "uptime_seconds": 8040},
                 "cpu": {"vcpus": 4, "usage_percent": \(cpu), "load_1min": \(alerts ? 3.86 : 0.92),
                         "load_5min": 0.8, "load_15min": 0.7, "status": "\(alerts ? "WARNING" : "OK")"},
                 "memory": {"total_gib": 3.9, "used_gib": 2.1, "available_gib": 1.8, "usage_percent": 54.0,
                            "swap_total_gib": 0.0, "swap_used_gib": 0.0, "status": "OK"},
                 "disk": {"total_gib": 31.3, "used_gib": \(diskUsed), "available_gib": \(alerts ? 2.2 : 19.2),
                          "usage_percent": \(alerts ? 93.0 : 38.7), "status": "\(alerts ? "WARNING" : "OK")"},
                 "alerts": \(warnings), "status": "\(alerts ? "WARNING" : "OK")"}
                """
        }
    }

    /// The fake guest's vsock: a socketpair whose other end answers like the Guest Tools.
    final class FakeGuestChannel: GuestChannel {
        private let monitor: FakeGuest.Monitor
        private let answers = Mutex(0)

        init(monitor: FakeGuest.Monitor) {
            self.monitor = monitor
        }

        func connect(port: UInt32) async throws -> FileHandle {
            let count = answers.withLock { value -> Int in
                value += 1
                return value
            }
            switch monitor {
            case .waiting, .missing:
                throw MonitorError.unavailable
            case .stale where count > 1:
                throw MonitorError.timeout
            case .error:
                return try Self.pair(Self.http("{ non è uno stato"))
            case .version:
                return try Self.pair(Self.http(FakeGuest.statusJSON(alerts: false, version: "3.0")))
            case .alerts:
                return try Self.pair(Self.http(FakeGuest.statusJSON(alerts: true)))
            case .values, .stale, .stops:
                return try Self.pair(Self.http(FakeGuest.statusJSON(alerts: false)))
            }
        }

        private static func http(_ body: String) -> Data {
            Data("HTTP/1.0 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)".utf8)
        }

        /// The client end; the other end reads the request, writes `response` and closes.
        private static func pair(_ response: Data) throws -> FileHandle {
            var fds: [Int32] = [0, 0]
            guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { throw POSIXError(.EIO) }
            let server = fds[1]
            var one: Int32 = 1
            setsockopt(server, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            Thread {
                var buffer = [UInt8](repeating: 0, count: 1024)
                _ = read(server, &buffer, buffer.count)
                response.withUnsafeBytes { _ = write(server, $0.baseAddress, $0.count) }
                close(server)
            }.start()
            return FileHandle(fileDescriptor: fds[0], closeOnDealloc: true)
        }
    }

    /// The fake guest's Ollama (`AIRuntimeControlling`), as `nido-provision` would report it.
    final class FakeAIRuntime: AIRuntimeControlling {
        private struct State {
            var installed: Bool
            var models: [OllamaModel]
            var steps: [String: ProvisionStep] = [:]
        }

        private let behavior: FakeGuest.Ollama
        private let state: Mutex<State>
        private static let gib: Int64 = 1 << 30

        init(behavior: FakeGuest.Ollama) {
            self.behavior = behavior
            let installed = behavior == .installed
            state = Mutex(State(
                installed: installed,
                models: installed
                    ? [OllamaModel(name: "llama3.2:1b", sizeBytes: 1_395_864_371),
                       OllamaModel(name: "qwen3:1.7b", sizeBytes: 1_503_238_554)]
                    : []))
        }

        private func step(_ name: String, _ state: ProvisionStep.State, _ message: String, model: String? = nil,
                          completed: Int64? = nil, total: Int64? = nil) -> ProvisionStep {
            ProvisionStep(name: name, state: state, message: message,
                          updated: ISO8601DateFormatter().string(from: Date()), model: model,
                          completedBytes: completed, totalBytes: total)
        }

        func status() async throws -> AIRuntimeStatus {
            if behavior == .sshKey { throw GuestSSHError.keyUnavailable("~/.ssh/id_ed25519") }
            let current = state.withLock { $0 }
            return AIRuntimeStatus(
                installed: current.installed, version: current.installed ? "0.40.10" : nil, running: current.installed,
                models: current.models, pinnedVersion: "0.40.10", steps: current.steps)
        }

        func log() async throws -> String {
            """
            2026-10-25T08:36:02Z ollama-install: download ollama-linux-arm64.tar.zst (1,46 GiB)
            2026-10-25T08:37:30Z ollama-install: SHA-256 verificato
            2026-10-25T08:37:51Z ollama-install: Ollama 0.40.10 installato e attivo
            2026-10-25T08:38:02Z model-pull llama3.2:1b: pulling manifest
            2026-10-25T08:38:40Z model-pull llama3.2:1b: 0,6 GiB di 1,3 GiB
            """
        }

        func install(progress: @escaping @Sendable (DownloadProgress) -> Void) async throws {
            if behavior == .sshKey { throw GuestSSHError.keyUnavailable("~/.ssh/id_ed25519") }
            state.withLock {
                $0.installed = true
                $0.steps["ollama-install"] = step("ollama-install", .done, "Ollama 0.40.10 installato e attivo")
            }
        }

        func verify() async throws {
            state.withLock { $0.steps["ollama-verify"] = step("ollama-verify", .done, "Ollama 0.40.10 risponde") }
        }

        func start() async throws {}
        func stop() async throws {}
        func restart() async throws {}
        func update(progress: @escaping @Sendable (DownloadProgress) -> Void) async throws {}

        func uninstall(removeModels: Bool) async throws {
            state.withLock {
                $0.installed = false
                if removeModels { $0.models = [] }
            }
        }

        func pull(model: String, force: Bool, progress: @escaping @Sendable (PullProgress) -> Void) async throws {
            let total: Int64 = 1_395_864_371
            switch behavior {
            case .phase2Fails:
                // Coded like the real Guest Tools: the app shows it in its own language (GuestMessage).
                let message = "model_disk_space_low: not enough disk space for the model: 1.3 GiB needed, 812 MiB free"
                state.withLock { $0.steps["model-pull"] = step("model-pull", .failed, message, model: model) }
                throw AIRuntimeError.stepFailed(step: "model-pull", message: message)
            case .phase2:
                let done = total * 46 / 100
                state.withLock {
                    $0.steps["model-pull"] = step("model-pull", .running, "pulling", model: model,
                                                  completed: done, total: total)
                }
                progress(PullProgress(completedBytes: done, totalBytes: total, message: "pulling", warning: nil))
                // The download "lasts": until Nido stops waiting.
                try await Task.sleep(for: .seconds(3600))
            default:
                state.withLock {
                    $0.models.append(OllamaModel(name: model, sizeBytes: total))
                    $0.steps["model-pull"] = step("model-pull", .done, "\(model) scaricato", model: model)
                }
            }
        }

        func remove(model: String) async throws {
            state.withLock { $0.models.removeAll { $0.name == model } }
        }

        /// The design's answer (S15 chat), streamed, then the model keeps "thinking".
        func chat(model: String, messages: [ChatMessage]) -> AsyncThrowingStream<ChatEvent, Error> {
            AsyncThrowingStream { continuation in
                let task = Task {
                    let pieces = ["1. Legge la configurazione dal disco seed (NoCloud).\n",
                                  "2. Crea l'utente, mette la chiave SSH e configura la rete.\n",
                                  "3. Installa i pacchetti richiesti e "]
                    for piece in pieces {
                        try? await Task.sleep(for: .milliseconds(200))
                        continuation.yield(.piece(piece))
                    }
                    try? await Task.sleep(for: .seconds(3600))
                    continuation.finish()
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
    }
#endif
