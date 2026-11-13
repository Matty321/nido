// SPDX-License-Identifier: Apache-2.0
import CryptoKit
import Foundation
import Synchronization
import Testing
@_spi(Testing) @testable import NidoCore

/// Delivers stdout in the given chunks through the streaming entry point of `ProcessRunner`.
private final class ChunkedRunner: ProcessRunner, @unchecked Sendable {
    let chunks: [String]
    let status: Int32
    let stderr: String
    private let state = Mutex<[ScriptedRunner.Call]>([])
    init(_ chunks: [String], status: Int32 = 0, stderr: String = "") {
        self.chunks = chunks
        self.status = status
        self.stderr = stderr
    }
    var calls: [ScriptedRunner.Call] { state.withLock { $0 } }

    func run(executable: URL, arguments: [String]) throws -> ProcessResult {
        throw NidoError.processFailed(executable: executable.path, status: -1)
    }

    func run(
        executable: URL, arguments: [String], stdin: Data?, timeout: TimeInterval, maxOutput: Int,
        cancellation: ProcessCancellation?, onStdout: (@Sendable (Data) -> Void)?
    ) throws -> ProcessResult {
        state.withLock {
            $0.append(.init(executable: executable.path, arguments: arguments, stdin: stdin, timeout: timeout))
        }
        for chunk in chunks { onStdout?(Data(chunk.utf8)) }
        return ProcessResult(status: status, stdout: Data(), stderr: Data(stderr.utf8))
    }
}

/// The Mac download's progress reports.
private final class DownloadLog: Sendable {
    private let values = Mutex<[DownloadProgress]>([])
    func append(_ progress: DownloadProgress) { values.withLock { $0.append(progress) } }
    var all: [DownloadProgress] { values.withLock { $0 } }
}

/// The releases an archive provider was asked for.
private final class ReleaseLog: Sendable {
    private let values = Mutex<[OllamaRelease]>([])
    func append(_ release: OllamaRelease) { values.withLock { $0.append(release) } }
    var all: [OllamaRelease] { values.withLock { $0 } }
}

@Suite(.italian) struct AIRuntimeTests {
    private func runtime(_ runner: ProcessRunner, fx: GuestFixture) throws -> AIRuntime {
        AIRuntime(ssh: try fx.ssh(runner), pollInterval: .milliseconds(20))
    }

    private static let statusJSON = """
        {"version": 1, "ollama": {"installed": true, "version": "0.40.10", "running": true, "pinned": "0.40.10"},
         "models": [{"name": "qwen3:0.6b", "size": 522653277}, {"name": "gemma3:1b", "size": "806067267"}, {"size": 3}],
         "steps": {"model-pull": {"state": "running", "message": "pulling abc", "updated": "2026-10-24T12:00:00Z",
                                  "model": "qwen3:0.6b", "progress": {"completed": 100, "total": 400},
                                  "warning": "poca RAM"},
                   "ollama-install": {"state": "done", "message": "Ollama 0.40.10 installato e attivo",
                                      "updated": "2026-10-24T11:00:00Z"},
                   "future": {"state": "paused", "message": 3}}}
        """

    @Test func statusParsesOllamaList() async throws {
        let fx = try GuestFixture(); defer { fx.cleanup() }
        let runner = ScriptedRunner { _ in result(0, out: Self.statusJSON + "\n") }
        let status = try await runtime(runner, fx: fx).status()
        #expect(status.installed)
        #expect(status.version == "0.40.10")
        #expect(status.running)
        #expect(status.pinnedVersion == "0.40.10")
        #expect(status.models == [
            OllamaModel(name: "qwen3:0.6b", sizeBytes: 522_653_277),
            OllamaModel(name: "gemma3:1b", sizeBytes: 806_067_267),
        ])
        let pull = try #require(status.steps["model-pull"])
        #expect(pull.state == .running)
        #expect(pull.model == "qwen3:0.6b")
        #expect(pull.completedBytes == 100 && pull.totalBytes == 400)
        #expect(pull.warning == "poca RAM")
        #expect(status.steps["ollama-install"]?.state == .done)
        #expect(status.steps["future"]?.state == .unknown)
        let remote = try #require(runner.calls.first?.arguments.last)
        #expect(remote == "'sudo' '-n' '/opt/nido-guest-tools/bin/nido-provision' 'status'")
    }

    @Test func statusRejectsGarbage() async throws {
        let fx = try GuestFixture(); defer { fx.cleanup() }
        for out in ["", "not json", "[1,2]", "{\"version\": 1"] {
            let runner = ScriptedRunner { _ in result(0, out: out) }
            await #expect(throws: AIRuntimeError.invalidResponse) { _ = try await runtime(runner, fx: fx).status() }
        }
    }

    @Test func pullValidatesName() async throws {
        let fx = try GuestFixture(); defer { fx.cleanup() }
        let runner = ScriptedRunner { _ in result(0) }
        let rt = try runtime(runner, fx: fx)
        for bad in ["a;b", "-rf", "", "a b", "x$(id)"] {
            await #expect(throws: GuestSSHError.invalidIdentifier(bad)) {
                try await rt.pull(model: bad) { _ in }
            }
            await #expect(throws: GuestSSHError.invalidIdentifier(bad)) { try await rt.remove(model: bad) }
        }
        #expect(runner.calls.isEmpty)
    }

    @Test func pullRunsTheFixedStepAndReportsProgress() async throws {
        let fx = try GuestFixture(); defer { fx.cleanup() }
        let polls = Mutex(0)
        // The pull lasts until the poller has delivered one progress report: a signal, not a
        // guess at how long the polls take (a fixed 0.2 s failed under load). The long timeout
        // only keeps a broken poller from hanging the suite; the expectations below then fail.
        let delivered = DispatchSemaphore(value: 0)
        let runner = ScriptedRunner { call in
            let remote = call.arguments.last ?? ""
            if remote.hasSuffix("'status'") {
                polls.withLock { $0 += 1 }
                return result(0, out: Self.statusJSON)
            }
            _ = delivered.wait(timeout: .now() + 30)
            return result(0)
        }
        let seen = Mutex<[PullProgress]>([])
        try await runtime(runner, fx: fx).pull(model: "qwen3:0.6b", force: true) { p in
            seen.withLock { $0.append(p) }
            delivered.signal()
        }
        let remotes = runner.calls.map { $0.arguments.last ?? "" }
        #expect(remotes.contains("'sudo' '-n' '/opt/nido-guest-tools/bin/nido-provision' 'model-pull' 'qwen3:0.6b' '--force'"))
        #expect(polls.withLock { $0 } >= 1)
        let first = try #require(seen.withLock { $0.first })
        #expect(first == PullProgress(completedBytes: 100, totalBytes: 400, message: "pulling abc", warning: "poca RAM"))
    }

    @Test func actionsRunFixedSteps() async throws {
        let fx = try GuestFixture(); defer { fx.cleanup() }
        // Ollama already at the pinned version: install and update need no archive.
        let runner = ScriptedRunner { call in
            (call.arguments.last ?? "").hasSuffix("'status'") ? result(0, out: Self.statusJSON) : result(0)
        }
        let rt = try runtime(runner, fx: fx)
        try await rt.install()
        try await rt.verify()
        try await rt.start()
        try await rt.stop()
        try await rt.restart()
        try await rt.update()
        try await rt.uninstall(removeModels: false)
        try await rt.uninstall(removeModels: true)
        try await rt.remove(model: "gemma3:1b")
        _ = try await rt.log()
        let prefix = "'sudo' '-n' '/opt/nido-guest-tools/bin/nido-provision' "
        #expect(runner.calls.map { $0.arguments.last ?? "" } == [
            "'status'", "'ollama-install'", "'ollama-verify'", "'ollama-start'", "'ollama-stop'", "'ollama-restart'",
            "'status'", "'ollama-update'", "'ollama-uninstall' '--keep-models'", "'ollama-uninstall' '--remove-models'",
            "'model-remove' 'gemma3:1b'", "'log'",
        ].map { prefix + $0 })
    }

    /// A test release of `payload` and a provider that hands out `file`, counting its calls.
    private func archiveFixture(_ fx: GuestFixture, payload: Data) throws
        -> (release: OllamaRelease, file: URL, calls: ReleaseLog)
    {
        let file = fx.root.appendingPathComponent("ollama-archive")
        try payload.write(to: file)
        let digest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let json = #"{"version": "0.40.10", "file": "ollama-linux-arm64.tar.zst", "size": \#(payload.count), "#
            + #""url": "https://github.com/ollama/ollama/releases/download/v0.40.10/ollama-linux-arm64.tar.zst", "#
            + #""sha256": "\#(digest)"}"#
        return (try OllamaRelease.parse(Data(json.utf8)), file, ReleaseLog())
    }

    private static func statusJSON(installed: Bool, version: String?, pinned: String) -> String {
        let v = version.map { "\"\($0)\"" } ?? "null"
        return #"{"version": 1, "ollama": {"installed": \#(installed), "version": \#(v), "running": \#(installed), "#
            + #""pinned": "\#(pinned)"}, "models": [], "steps": {}}"#
    }

    /// The guest's answer to `status`, to the Guest Tools version and to every other step.
    private static func guest(status: String, tools: String? = GuestToolsPayload.version,
                              step: @escaping @Sendable () -> ProcessResult = { result(0) })
        -> @Sendable (ScriptedRunner.Call) -> ProcessResult
    {
        { call in
            let remote = call.arguments.last ?? ""
            if remote.hasSuffix("'status'") { return result(0, out: status) }
            if remote == "'cat' '/opt/nido-guest-tools/VERSION'" {
                return tools.map { result(0, out: "\($0)\n") }
                    ?? result(1, err: "cat: /opt/nido-guest-tools/VERSION: No such file or directory\n")
            }
            return step()
        }
    }

    /// Ollama missing or older: the Mac's verified archive goes in on stdin of
    /// `--archive-stdin`, for install and update alike, copied from the file (never mapped). The
    /// guest never downloads it.
    @Test func installSendsTheMacsArchiveOnStdin() async throws {
        let fx = try GuestFixture(); defer { fx.cleanup() }
        let payload = Data(repeating: 0x42, count: 70_000)
        let (release, file, calls) = try archiveFixture(fx, payload: payload)
        for (installed, version) in [(false, nil), (true, "0.30.0")] as [(Bool, String?)] {
            let status = Self.statusJSON(installed: installed, version: version, pinned: "0.40.10")
            let runner = ScriptedRunner(Self.guest(status: status))
            let rt = AIRuntime(ssh: try fx.ssh(runner), release: release, archive: { wanted, _ in
                calls.append(wanted)
                return file
            })
            try await rt.install()
            try await rt.update()
            let prefix = "'sudo' '-n' '/opt/nido-guest-tools/bin/nido-provision' "
            let tools = "'cat' '/opt/nido-guest-tools/VERSION'"
            #expect(runner.calls.map { $0.arguments.last ?? "" } == [
                prefix + "'status'", tools, prefix + "'ollama-install' '--archive-stdin'",
                prefix + "'status'", tools, prefix + "'ollama-update' '--archive-stdin'",
            ])
            #expect(runner.calls[2].stdin == payload)
            #expect(runner.calls[5].stdin == payload)
            #expect(runner.calls[0].stdin == nil)
        }
        #expect(calls.all == Array(repeating: release, count: 4))
    }

    /// The Mac's download reports its progress through `install(progress:)`.
    @Test func installReportsTheMacsDownload() async throws {
        let fx = try GuestFixture(); defer { fx.cleanup() }
        let (release, file, _) = try archiveFixture(fx, payload: Data(repeating: 1, count: 10))
        let runner = ScriptedRunner(Self.guest(status: Self.statusJSON(installed: false, version: nil, pinned: "0.40.10")))
        let rt = AIRuntime(ssh: try fx.ssh(runner), release: release, archive: { _, progress in
            progress(DownloadProgress(receivedBytes: 4, expectedBytes: 10))
            progress(DownloadProgress(receivedBytes: 10, expectedBytes: 10))
            return file
        })
        let log = DownloadLog()
        try await rt.install { log.append($0) }
        #expect(log.all.map(\.receivedBytes) == [4, 10])
    }

    /// A file of another size than the release (damaged after the check) is never sent.
    @Test func archiveOfAnotherSizeIsNotSent() async throws {
        let fx = try GuestFixture(); defer { fx.cleanup() }
        let (release, file, _) = try archiveFixture(fx, payload: Data(repeating: 1, count: 10))
        try Data(repeating: 1, count: 4).write(to: file)
        let runner = ScriptedRunner(Self.guest(status: Self.statusJSON(installed: false, version: nil, pinned: "0.40.10")))
        let rt = AIRuntime(ssh: try fx.ssh(runner), release: release, archive: { _, _ in file })
        await #expect(throws: NidoError.self) { try await rt.install() }
        #expect(!runner.calls.contains { ($0.arguments.last ?? "").contains("--archive-stdin") })
    }

    @Test func installNeedsTheGuestToolsOfThisNido() async throws {
        let fx = try GuestFixture(); defer { fx.cleanup() }
        let (release, file, calls) = try archiveFixture(fx, payload: Data("x".utf8))
        // Guest Tools pinning another release: update them first; nothing is downloaded.
        let other = Self.statusJSON(installed: false, version: nil, pinned: "0.30.0")
        let runner = ScriptedRunner(Self.guest(status: other))
        let rt = AIRuntime(ssh: try fx.ssh(runner), release: release, archive: { r, _ in
            calls.append(r)
            return file
        })
        await #expect(throws: AIRuntimeError.guestToolsOutdated) { try await rt.install() }
        #expect(runner.calls.count == 1)
        #expect(calls.all.isEmpty)

        // Older Guest Tools that pin the same Ollama (1.3.0 does not know `--archive-stdin`), or
        // none at all: refused before the download, which never starts.
        let fresh = Self.statusJSON(installed: false, version: nil, pinned: "0.40.10")
        for tools in ["1.3.0", nil] as [String?] {
            let old = ScriptedRunner(Self.guest(status: fresh, tools: tools))
            let rtOld = AIRuntime(ssh: try fx.ssh(old), release: release, archive: { r, _ in
                calls.append(r)
                return file
            })
            await #expect(throws: AIRuntimeError.guestToolsOutdated) { try await rtOld.install() }
            await #expect(throws: AIRuntimeError.guestToolsOutdated) { try await rtOld.update() }
            #expect(!old.calls.contains { ($0.arguments.last ?? "").contains("--archive-stdin") })
        }
        #expect(calls.all.isEmpty)

        // Guest Tools 1.4.0 and later take the archive on stdin: 1.4.0 (Italian messages) still
        // installs, without reinstalling the Guest Tools first.
        for tools in ["1.4.0", "1.10.0"] {
            let ok = ScriptedRunner(Self.guest(status: fresh, tools: tools))
            let rtOK = AIRuntime(ssh: try fx.ssh(ok), release: release, archive: { r, _ in
                calls.append(r)
                return file
            })
            try await rtOK.install()
            #expect(ok.calls.contains { ($0.arguments.last ?? "").contains("--archive-stdin") }, "\(tools)")
        }
        #expect(calls.all.count == 2)

        // Belt and braces: a usage error of `--archive-stdin` still means outdated.
        let usage = ScriptedRunner(Self.guest(status: fresh, step: {
            result(2, err: "uso: nido-provision ollama-install|ollama-verify|ollama-start\n")
        }))
        let rtUsage = AIRuntime(ssh: try fx.ssh(usage), release: release, archive: { _, _ in file })
        await #expect(throws: AIRuntimeError.guestToolsOutdated) { try await rtUsage.install() }
    }

    /// Guest Tools releases that take the archive on stdin: three numbers, 1.4.0 or later.
    @Test func archiveOnStdinNeedsGuestTools140OrLater() {
        for version in ["1.4.0", "1.10.0", "2.0.0", "1.4.1"] {
            #expect(AIRuntime.takesArchiveOnStdin(version), "\(version)")
        }
        // Older, or not three plain numbers (no VERSION Nido ever wrote): refused as out of date.
        for version in ["1.3.9", "1.4", "1.4.0-beta", "", "1..0", "-1.4.0", "1.4.0.1"] {
            #expect(!AIRuntime.takesArchiveOnStdin(version), "\(version)")
        }
    }

    @Test func failedStepSurfacesMessage() async throws {
        let fx = try GuestFixture(); defer { fx.cleanup() }
        let runner = ScriptedRunner { _ in
            result(1, err: "nido-provision: checksum di Ollama non valido: file scartato, usa Riprova\n")
        }
        let rt = try runtime(runner, fx: fx)
        await #expect(throws: AIRuntimeError.stepFailed(
            step: "ollama-install", message: "checksum di Ollama non valido: file scartato, usa Riprova")) {
            try await rt.install()
        }
        #expect(AIRuntimeError.stepFailed(step: "ollama-install", message: "x").errorDescription
            == "installazione di Ollama non riuscita: x")
        // Each step is its own sentence, so the Italian agrees with the step's gender.
        #expect(AIRuntimeError.stepFailed(step: "ollama-start", message: "x").errorDescription
            == "avvio di Ollama non riuscito: x")
        #expect(AIRuntimeError.stepFailed(step: "model-pull", message: "x").errorDescription
            == "scaricamento del modello non riuscito: x")
        #expect(AIRuntimeError.stepFailed(step: "model-remove", message: "x").errorDescription
            == "rimozione del modello non riuscita: x")

        let busy = ScriptedRunner { _ in result(3, err: "nido-provision: un altro passo è in corso, riprova tra poco") }
        await #expect(throws: AIRuntimeError.busy) { try await runtime(busy, fx: fx).start() }

        let old = ScriptedRunner { _ in result(1, err: "sudo: /opt/nido-guest-tools/bin/nido-provision: command not found") }
        await #expect(throws: AIRuntimeError.guestToolsOutdated) { try await runtime(old, fx: fx).install() }

        let ssh = ScriptedRunner { _ in result(255, err: "ssh: connect to host 192.168.64.9 port 22: Operation timed out") }
        await #expect(throws: GuestSSHError.unreachable) { try await runtime(ssh, fx: fx).install() }
    }

    /// Guest Tools 1.5.0 and later: "nido-provision: <code>: <English message>"; Nido shows its own
    /// text for the code, in the UI language, inside the step's sentence.
    @Test func codedMessageIsLocalized() async throws {
        let fx = try GuestFixture(); defer { fx.cleanup() }
        let coded = "archive_checksum_mismatch: the Ollama archive’s checksum doesn’t match: file discarded, click Try Again"
        let runner = ScriptedRunner { _ in result(1, err: "nido-provision: \(coded)\n") }
        let rt = try runtime(runner, fx: fx)
        await #expect(throws: AIRuntimeError.stepFailed(step: "ollama-install", message: coded)) {
            try await rt.install()
        }
        let error = AIRuntimeError.stepFailed(step: "ollama-install", message: coded)
        // Italian: today's guest message, in today's sentence.
        #expect(error.errorDescription
            == "installazione di Ollama non riuscita: checksum di Ollama non valido: file scartato, usa Riprova")
        #expect(error.localizedDescription(language: "de")
            == "Ollama konnte nicht installiert werden: Die Prüfsumme des Ollama-Archivs stimmt nicht überein: Datei verworfen, klicke auf „Erneut versuchen“")
        #expect(error.localizedDescription(language: "en")
            == "couldn’t install Ollama: the Ollama archive’s checksum doesn’t match: file discarded, click Try Again")
        #expect(error.localizedDescription(language: "fr")
            == "impossible d’installer Ollama\u{00A0}: la somme de contrôle de l’archive d’Ollama ne correspond pas\u{00A0}: fichier supprimé, cliquez sur Réessayer")

        // Values come from the message: sizes in the language's number format, names as sent.
        #expect(GuestMessage.text("disk_space_low: not enough disk space: 5.2 GiB needed, 812 MiB free", language: "it")
            == "spazio su disco insufficiente: servono 5,2 GiB liberi, ce ne sono 812 MiB")
        let separator = L10n.locale(for: "en").decimalSeparator ?? "."
        #expect(GuestMessage.text("disk_space_low: not enough disk space: 5.2 GiB needed, 812 MiB free", language: "en")
            == "not enough disk space: 5\(separator)2 GiB needed, 812 MiB free")
        #expect(GuestMessage.text("model_missing_after_pull: the model qwen3:0.6b is missing after the download", language: "de")
            == "Das Modell qwen3:0.6b fehlt nach dem Download")
        #expect(GuestMessage.text("unexpected_error: unexpected error (KeyError: 'models': x)", language: "es")
            == "error inesperado (KeyError: 'models': x)")
        // The memory warning of a download (the AI view shows it by its code).
        #expect(GuestMessage.text(
            "model_memory_low: the VM has 2.0 GiB of RAM and the model takes 4.1 GiB: it may be slow or fail to start",
            language: "it") == "la VM ha 2,0 GiB di RAM, il modello occupa 4,1 GiB: potrebbe essere lento o non avviarsi")
    }

    /// Guest Tools before 1.5.0 (existing VMs) write Italian free text and an Italian usage line:
    /// the text is shown as it arrives, and "Guest Tools out of date" is still recognized.
    @Test func legacyItalianGuestMessages() async throws {
        let fx = try GuestFixture(); defer { fx.cleanup() }
        let legacy = "checksum di Ollama non valido: file scartato, usa Riprova"
        for language in ["en", "it", "de", "es", "fr"] {
            #expect(GuestMessage.text(legacy, language: language) == legacy)
            // One word before the colon, like a code, but not a code.
            #expect(GuestMessage.text("interrotto: usa Riprova", language: language) == "interrotto: usa Riprova")
        }
        #expect(AIRuntimeError.stepFailed(step: "model-pull", message: "spazio su disco insufficiente: liberi 1.0 GiB")
            .localizedDescription(language: "de")
            == "Das Modell konnte nicht heruntergeladen werden: spazio su disco insufficiente: liberi 1.0 GiB")
        // A code this Nido doesn't know (newer Guest Tools): as it arrives. A known code whose
        // message has another shape (cut, reworded): the guest's message, without its code.
        #expect(GuestMessage.text("future_code: something new", language: "de") == "future_code: something new")
        #expect(GuestMessage.text("archive_wrong_version: something else", language: "de") == "something else")
        #expect(GuestMessage.text("unexpected_error: unexpected error (RuntimeError: boom", language: "it")
            == "unexpected error (RuntimeError: boom")
        #expect(AIRuntimeError.stepFailed(step: "model-pull", message: "unexpected_error: unexpected error (KeyError")
            .localizedDescription(language: "en") == "couldn’t download the model: unexpected error (KeyError")

        let runner = ScriptedRunner { _ in result(1, err: "nido-provision: \(legacy)\n") }
        await #expect(throws: AIRuntimeError.stepFailed(step: "ollama-start", message: legacy)) {
            try await runtime(runner, fx: fx).start()
        }
        for line in ["uso: nido-provision ollama-install|ollama-verify|ollama-start\n",
                     "usage: nido-provision ollama-install [--archive-stdin]|ollama-verify|ollama-start\n"] {
            let usage = ScriptedRunner { _ in result(2, err: line) }
            await #expect(throws: AIRuntimeError.guestToolsOutdated) { try await runtime(usage, fx: fx).verify() }
        }
        for line in ["nido-provision: un altro passo è in corso, riprova tra poco\n",
                     "nido-provision: busy: another step is running, try again shortly\n"] {
            let busy = ScriptedRunner { _ in result(3, err: line) }
            await #expect(throws: AIRuntimeError.busy) { try await runtime(busy, fx: fx).start() }
        }
    }

    @Test func chatStreamsChunks() async throws {
        let fx = try GuestFixture(); defer { fx.cleanup() }
        let runner = ChunkedRunner([
            #"{"message":{"role":"assistant","content":"Ciao"},"done":false}"# + "\n" + #"{"message":{"role":"assi"#,
            #"stant","content":" mondo"},"done":false}"# + "\n",
            #"{"message":{"role":"assistant","content":""},"done":true,"total_duration":2500000000,"#
                + #""eval_count":40,"eval_duration":2000000000}"# + "\n",
        ])
        var parts: [String] = []
        var stats: [ChatStats] = []
        let messages = [ChatMessage(role: .system, content: "Sii breve"), ChatMessage(role: .user, content: "Ciao 'a'; $(rm -rf /)")]
        for try await event in try runtime(runner, fx: fx).chat(model: "qwen3:0.6b", messages: messages) {
            switch event {
            case .piece(let part): parts.append(part)
            case .finished(let final): stats.append(final)
            }
        }
        #expect(parts == ["Ciao", " mondo"])
        #expect(stats == [ChatStats(totalDuration: .milliseconds(2500), evalCount: 40, evalDuration: .seconds(2))])
        #expect(stats.first?.tokensPerSecond == 20)
        let call = try #require(runner.calls.first)
        #expect(call.arguments.last
            == "'curl' '-sN' '--noproxy' '*' '--max-time' '900' '--data-binary' '@-' 'http://127.0.0.1:11434/api/chat'")
        let stdin = try #require(call.stdin)
        let body = try #require(try JSONSerialization.jsonObject(with: stdin) as? [String: Any])
        #expect(body["model"] as? String == "qwen3:0.6b")
        #expect(body["stream"] as? Bool == true)
        let sent = try #require(body["messages"] as? [[String: String]])
        #expect(sent == [["role": "system", "content": "Sii breve"], ["role": "user", "content": "Ciao 'a'; $(rm -rf /)"]])
    }

    @Test func chatStatsAreOptional() async throws {
        let fx = try GuestFixture(); defer { fx.cleanup() }
        // No metrics, then metrics that make no rate (zero duration, negative, wrong types).
        for line in [
            #"{"done":true}"#,
            #"{"done":true,"total_duration":-5,"eval_count":"x","eval_duration":0}"#,
        ] {
            var stats: [ChatStats] = []
            for try await event in try runtime(ChunkedRunner([line + "\n"]), fx: fx).chat(model: "qwen3:0.6b", messages: []) {
                if case .finished(let final) = event { stats.append(final) }
            }
            #expect(stats.count == 1)
            #expect(stats.first?.tokensPerSecond == nil)
            #expect(stats.first?.totalDuration == nil)
        }
    }

    @Test func chatErrorsAreReported() async throws {
        let fx = try GuestFixture(); defer { fx.cleanup() }
        let ollamaError = ChunkedRunner([#"{"error":"model 'nope' not found"}"# + "\n"])
        await #expect(throws: AIRuntimeError.ollama("model 'nope' not found")) {
            for try await _ in try runtime(ollamaError, fx: fx).chat(model: "nope", messages: []) {}
        }
        let refused = ChunkedRunner([], status: 7)
        await #expect(throws: AIRuntimeError.notRunning) {
            for try await _ in try runtime(refused, fx: fx).chat(model: "qwen3:0.6b", messages: []) {}
        }
        await #expect(throws: GuestSSHError.invalidIdentifier("-x")) {
            for try await _ in try runtime(refused, fx: fx).chat(model: "-x", messages: []) {}
        }
    }

    @Test func suggestionsAreValidModelNames() throws {
        #expect(AIRuntime.suggestedModels.count >= 2 && AIRuntime.suggestedModels.count <= 3)
        for model in AIRuntime.suggestedModels {
            #expect(try GuestCommand.validateModelName(model.name) == model.name)
            #expect(model.sizeBytes > 0)
        }
    }
}

@Suite struct StreamingRunnerTests {
    @Test func streamsChunksAsTheyArrive() throws {
        let chunks = Mutex<[String]>([])
        let r = try SystemProcessRunner().run(
            executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "printf a; sleep 0.3; printf b"],
            stdin: nil, timeout: 10, maxOutput: 1 << 20, cancellation: nil,
            onStdout: { data in chunks.withLock { $0.append(String(decoding: data, as: UTF8.self)) } })
        #expect(r.status == 0)
        #expect(chunks.withLock { $0 } == ["a", "b"])
    }

    @Test func cancellationKillsTheChild() throws {
        let cancellation = ProcessCancellation()
        let start = Date()
        Thread { Thread.sleep(forTimeInterval: 0.2); cancellation.cancel() }.start()
        _ = try SystemProcessRunner().run(
            executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], stdin: nil, timeout: 60,
            maxOutput: 1 << 20, cancellation: cancellation, onStdout: { _ in })
        #expect(Date().timeIntervalSince(start) < 5)
        #expect(cancellation.isCancelled)
    }

    /// A child's stdin copied from a file in chunks: every byte arrives, in order, also when the
    /// file is several chunks long.
    @Test func stdinFromAFileIsCopiedWhole() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nido-stdin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("payload")
        var payload = Data()
        for i in 0..<(SystemProcessRunner.stdinChunkSize * 3 + 12_345) / 4 {
            withUnsafeBytes(of: UInt32(i).bigEndian) { payload.append(contentsOf: $0) }
        }
        try payload.write(to: file)
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let r = try SystemProcessRunner().run(
            executable: URL(fileURLWithPath: "/usr/bin/shasum"), arguments: ["-a", "256"], stdinFile: handle,
            timeout: 30, maxOutput: 1 << 20, cancellation: nil)
        #expect(r.status == 0)
        let digest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        #expect(String(decoding: r.stdout, as: UTF8.self).hasPrefix(digest))
    }

    /// A child that exits without reading ends the copy: no hang, no SIGPIPE.
    @Test func stdinFromAFileStopsWhenTheChildExits() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nido-stdin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("payload")
        try Data(repeating: 7, count: SystemProcessRunner.stdinChunkSize * 4).write(to: file)
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let start = Date()
        let r = try SystemProcessRunner().run(
            executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: [], stdinFile: handle,
            timeout: 30, maxOutput: 1 << 20, cancellation: nil)
        #expect(r.status == 0)
        // The copy ends at EPIPE, not at the timeout nor at the join's bound.
        #expect(Date().timeIntervalSince(start) < 5)
    }

    @Test func outputIsBounded() throws {
        let total = Mutex(0)
        _ = try SystemProcessRunner().run(
            executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "head -c 300000 /dev/zero"],
            stdin: nil, timeout: 10, maxOutput: 1000, cancellation: nil,
            onStdout: { data in total.withLock { $0 += data.count } })
        #expect(total.withLock { $0 } == 1000)
    }

    @Test func guestSSHRunIsCancellable() async throws {
        let fx = try GuestFixture(); defer { fx.cleanup() }
        final class Blocking: ProcessRunner, @unchecked Sendable {
            func run(executable: URL, arguments: [String]) throws -> ProcessResult { throw NidoError.pidUnknown }
            func run(
                executable: URL, arguments: [String], stdin: Data?, timeout: TimeInterval, maxOutput: Int,
                cancellation: ProcessCancellation?, onStdout: (@Sendable (Data) -> Void)?
            ) throws -> ProcessResult {
                let done = DispatchSemaphore(value: 0)
                cancellation?.onCancel { done.signal() }
                _ = done.wait(timeout: .now() + 30)
                return ProcessResult(status: 143, stdout: Data(), stderr: Data())
            }
        }
        let ssh = try fx.ssh(Blocking())
        let task = Task { try await ssh.run(.ollama(.install), timeout: .seconds(60)) }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        await #expect(throws: GuestSSHError.cancelled) { _ = try await task.value }
    }
}
