// SPDX-License-Identifier: Apache-2.0
import AppKit
import Foundation
import NidoCore
import Observation

/// The simple local chat of the AI section (spec D): one conversation with an Ollama model of the
/// VM, in memory only (privacy: nothing is written to disk and nothing leaves the Mac), one answer
/// at a time. The answer streams from the guest (`AIRuntime.chat`) off the main actor; each piece
/// is appended on the main actor for the view, at most every `flushInterval` so that a fast model
/// does not redraw the answer for every token. "Stop" cancels the stream, which stops the
/// request on the host side (the ssh process and the guest's `curl`). "Copy" is the only way an
/// answer leaves the model, and only when the user asks: it goes to the pasteboard.
@MainActor
@Observable
final class LocalChatModel {
    struct Turn: Identifiable, Equatable, Sendable {
        let id: Int
        let role: ChatMessage.Role
        var text: String
        /// The model that wrote an answer (nil for the user's messages).
        var model: String?
        /// Ollama's metrics, once the answer is complete.
        var stats: ChatStats?
    }

    /// The models installed in the VM (from the last status read), and the one chosen.
    private(set) var models: [String] = []
    var selectedModel: String?
    /// The message being typed.
    var draft = ""
    private(set) var turns: [Turn] = []
    private(set) var isAnswering = false
    /// The answer being streamed.
    private(set) var answeringID: Int?
    /// Changes whenever the conversation's content does: the view follows the answer with it.
    private(set) var revision = 0
    /// Why the last answer failed (localized).
    private(set) var error: String?
    /// Information that is not an error ("Answer stopped.").
    private(set) var note: String?
    /// Set by `AIRuntimeModel`: the chat needs a running VM.
    var isVMRunning = false

    /// The longest answer kept (Unicode scalars): past it the answer is stopped, so memory and
    /// the text's layout stay bounded.
    nonisolated static let defaultMaxAnswerCharacters = 200_000

    @ObservationIgnored private let makeRuntime: @Sendable () throws -> any AIRuntimeControlling
    @ObservationIgnored private let maxAnswerCharacters: Int
    @ObservationIgnored private let flushInterval: Duration
    @ObservationIgnored private let copyText: @MainActor (String) -> Void
    @ObservationIgnored private var answerTask: Task<(any Error)?, Never>?
    @ObservationIgnored private var nextID = 0
    /// The answer reached `maxAnswerCharacters` and was stopped by Nido.
    @ObservationIgnored private var truncated = false
    /// Characters of the answer being streamed, counted as Unicode scalars and kept as pieces
    /// arrive so that the cap check never recounts the whole text. Scalars, not `Character`s:
    /// a guest can load one Character with any number of combining marks, so only scalars bound
    /// the answer's size (4 bytes each at most).
    @ObservationIgnored private(set) var answerCharacters = 0
    /// Pieces received and not shown yet: the answer is updated at most every `flushInterval`
    /// (the first piece at once), and what is left shows when the stream ends.
    @ObservationIgnored private var pending = ""
    @ObservationIgnored private var lastFlush: ContinuousClock.Instant?
    @ObservationIgnored private var flushTask: Task<Void, Never>?

    init(
        makeRuntime: @escaping @Sendable () throws -> any AIRuntimeControlling,
        maxAnswerCharacters: Int = LocalChatModel.defaultMaxAnswerCharacters,
        flushInterval: Duration = .milliseconds(50),
        copyText: @escaping @MainActor (String) -> Void = LocalChatModel.copyToPasteboard
    ) {
        self.makeRuntime = makeRuntime
        self.maxAnswerCharacters = maxAnswerCharacters
        self.flushInterval = flushInterval
        self.copyText = copyText
    }

    /// The answer is on its way but no piece has arrived yet (the model loads or reads the prompt).
    var isWaitingForFirstPiece: Bool {
        guard let answeringID, let turn = turns.first(where: { $0.id == answeringID }) else { return false }
        return turn.text.isEmpty
    }

    var canSend: Bool {
        isVMRunning && !isAnswering && selectedModel != nil
            && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The installed models changed: keeps the choice when it is still there.
    func setModels(_ names: [String]) {
        models = names
        if let selectedModel, names.contains(selectedModel) { return }
        selectedModel = names.first
    }

    /// Sends the draft with the conversation so far; ignored while an answer is arriving.
    func send() async {
        guard !isAnswering else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let model = selectedModel else { return }
        guard isVMRunning else {
            error = String(localized: "The VM isn’t running: start it to use the chat.")
            return
        }
        error = nil
        note = nil
        draft = ""
        append(.user, text)
        let history = turns.map { ChatMessage(role: $0.role, content: $0.text) }
        let answerID = append(.assistant, "", model: model)
        isAnswering = true
        answeringID = answerID
        truncated = false
        answerCharacters = 0
        pending = ""
        lastFlush = nil
        let make = makeRuntime
        let task = Task.detached { [weak self] () -> (any Error)? in
            do {
                let stream = try make().chat(model: model, messages: history)
                for try await event in stream {
                    switch event {
                    case .piece(let piece): await self?.receive(piece, for: answerID)
                    case .finished(let stats): await self?.setStats(stats, of: answerID)
                    }
                }
                return Task.isCancelled ? CancellationError() : nil
            } catch {
                return error
            }
        }
        answerTask = task
        let failure = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        let cancelled = task.isCancelled
        flushPending(to: answerID)
        answerTask = nil
        isAnswering = false
        answeringID = nil
        // "Clear Chat" during the answer: nothing more to say about it.
        guard turns.contains(where: { $0.id == answerID }) else { return }
        if truncated {
            note = String(localized: "Answer too long: Nido stopped it at \(AIBridgeModel.grouped(maxAnswerCharacters)) characters.",
                          comment: "%@ is a number grouped with spaces (200 000).")
        } else if cancelled || failure is CancellationError || (failure as? GuestSSHError) == .cancelled {
            note = String(localized: "Answer stopped.")
        } else if let failure {
            error = AIRuntimeModel.errorState(for: failure)?.message
        }
        // An answer that never started says nothing: its empty bubble goes.
        if let index = turns.firstIndex(where: { $0.id == answerID }), turns[index].text.isEmpty {
            turns.remove(at: index)
        }
        revision += 1
    }

    /// "Stop": stops the answer being streamed.
    func cancel() {
        answerTask?.cancel()
    }

    /// "Clear": forgets the conversation (it was never written anywhere).
    func clear() {
        cancel()
        flushTask?.cancel()
        flushTask = nil
        pending = ""
        turns = []
        error = nil
        note = nil
        revision += 1
    }

    /// "Copy": the answer's text, as the model wrote it (Markdown), to the pasteboard. Not while
    /// it is still arriving.
    func copy(_ id: Int) {
        guard id != answeringID, let turn = turns.first(where: { $0.id == id }), !turn.text.isEmpty else { return }
        copyText(turn.text)
    }

    /// "4.2 s · 18.3 tokens/s" ("4,2 s · 18,3 token/s" in Italian) under an answer: what Ollama
    /// measured, nil when it gave nothing. `s` and `min` are the same symbols in every language.
    nonisolated static func statsLine(_ stats: ChatStats?) -> String? {
        guard let stats else { return nil }
        var parts: [String] = []
        if let duration = stats.totalDuration {
            let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
            if seconds < 60 {
                parts.append(seconds.formatted(.number.precision(.fractionLength(1)).locale(.current)) + " s")
            } else {
                let whole = Int(seconds.rounded())
                parts.append("\(whole / 60) min \(String(format: "%02d", whole % 60)) s")
            }
        }
        if let rate = stats.tokensPerSecond {
            let value = rate.formatted(.number.precision(.fractionLength(1)).locale(.current).grouping(.never))
            parts.append(String(localized: "\(value) tokens/s", comment: "Ollama’s generation speed: %@ is a decimal number."))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    @discardableResult
    private func append(_ role: ChatMessage.Role, _ text: String, model: String? = nil) -> Int {
        nextID += 1
        turns.append(Turn(id: nextID, role: role, text: text, model: model))
        revision += 1
        return nextID
    }

    private func receive(_ piece: String, for id: Int) {
        pending += piece
        guard flushTask == nil else { return }
        let elapsed = lastFlush.map { ContinuousClock.now - $0 }
        guard let elapsed, elapsed < flushInterval else {
            flushPending(to: id)
            return
        }
        let wait = flushInterval - elapsed
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled else { return }
            self?.flushTask = nil
            self?.flushPending(to: id)
        }
    }

    private func flushPending(to id: Int) {
        flushTask?.cancel()
        flushTask = nil
        guard !pending.isEmpty else { return }
        let pieces = pending
        pending = ""
        lastFlush = .now
        appendPiece(pieces, to: id)
    }

    private func setStats(_ stats: ChatStats, of id: Int) {
        flushPending(to: id)
        guard let index = turns.firstIndex(where: { $0.id == id }) else { return }
        turns[index].stats = stats
        revision += 1
    }

    private func appendPiece(_ piece: String, to id: Int) {
        guard !truncated, let index = turns.firstIndex(where: { $0.id == id }) else { return }
        defer { revision += 1 }
        let room = maxAnswerCharacters - answerCharacters
        let count = piece.unicodeScalars.count
        if count <= room {
            turns[index].text += piece
            answerCharacters += count
            return
        }
        turns[index].text += String(piece.unicodeScalars.prefix(max(0, room)))
        answerCharacters += max(0, room)
        truncated = true
        answerTask?.cancel()
    }
}
