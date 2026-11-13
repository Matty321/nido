// SPDX-License-Identifier: Apache-2.0
import NidoCore
import SwiftUI

/// The local chat (ScreensAI.swift `localeMode` "chat"): the model, the conversation with the
/// answer arriving in pieces (Markdown), the message field and Stop. Kept in memory only.
///
/// The conversation follows the answer while it is at its end; scrolling up stops that until
/// the user goes back to the end (or "Go to End").
struct ChatView: View {
    @Bindable var chat: LocalChatModel
    let vmName: String
    @State private var position = ScrollPosition(edge: .bottom)
    @State private var followsAnswer = true
    /// The answer just copied, for the "Copied" feedback.
    @State private var copiedID: Int?
    /// "Clear Chat" asks first when there is a conversation to lose.
    @State private var confirmingClear = false

    /// What the scroll view reports: its content's height and whether the end is in sight.
    private struct ScrollEnd: Equatable {
        var contentHeight: CGFloat
        var atEnd: Bool
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            if chat.models.isEmpty {
                Text("No models in the VM: download one from the Models view to use the chat.")
                    .font(.nido(Theme.TypeSize.body))
                    .foregroundStyle(Theme.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                picker
                conversation
                input
            }
            Text("The chat stays in \(vmName): nothing leaves the Mac and Nido doesn’t save it.")
                .font(.nido(Theme.TypeSize.caption))
                .foregroundStyle(Theme.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ai-chat")
        .sheet(isPresented: $confirmingClear) {
            NidoConfirmSheet(
                verbatim: String(localized: "Clear the chat?"), message: clearMessage,
                actionLabel: String(localized: "Clear", comment: "Clears the chat."), actionKind: .destructive,
                onCancel: { confirmingClear = false },
                onConfirm: {
                    confirmingClear = false
                    chat.clear()
                })
        }
    }

    private var clearMessage: String {
        chat.isAnswering
            ? String(localized: "The conversation with \(vmName) will be cleared: Nido keeps no copy. The answer in progress is stopped.",
                     comment: "%@ is the VM’s name.")
            : String(localized: "The conversation with \(vmName) will be cleared: Nido keeps no copy.", comment: "%@ is the VM’s name.")
    }

    private var picker: some View {
        HStack(spacing: Theme.Space.s) {
            AIGroupLabel("Model")
            Picker("Model", selection: $chat.selectedModel) {
                ForEach(chat.models, id: \.self) { Text($0).tag(Optional($0)) }
            }
            .labelsHidden()
            .frame(width: Theme.Layout.chatModelPickerWidth)
            .disabled(chat.isAnswering)
            .accessibilityIdentifier("ai-chat-model")
            Spacer(minLength: 0)
            NidoButton("Clear Chat") {
                if chat.turns.isEmpty { chat.clear() } else { confirmingClear = true }
            }
                .disabled(chat.turns.isEmpty && chat.error == nil && chat.note == nil)
                .accessibilityIdentifier("ai-chat-clear")
        }
    }

    private var conversation: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                ForEach(chat.turns) { turn in
                    bubble(turn).id(turn.id)
                }
                if chat.isAnswering, !chat.isWaitingForFirstPiece, let model = chat.selectedModel {
                    HStack(spacing: Theme.Space.s) {
                        ProgressView().controlSize(.mini)
                        Text(verbatim: [String(localized: "\(model) is answering", comment: "%@ is a model’s name."),
                                        String(localized: "on \(vmName)’s CPU", comment: "%@ is the VM’s name.")]
                            .joined(separator: " · "))
                            .font(.nido(Theme.TypeSize.caption))
                            .foregroundStyle(Theme.Color.textSecondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("ai-chat-answering")
                }
                if let error = chat.error {
                    Text(error)
                        .font(.nido(Theme.TypeSize.caption, .semibold))
                        .foregroundStyle(Theme.Color.statusError)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("ai-chat-error")
                }
                if let note = chat.note {
                    Text(note)
                        .font(.nido(Theme.TypeSize.caption))
                        .foregroundStyle(Theme.Color.textSecondary)
                        .accessibilityIdentifier("ai-chat-note")
                }
            }
            .padding(Theme.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollPosition($position)
        .defaultScrollAnchor(.bottom)
        .frame(minHeight: Theme.Layout.chatMinHeight)
        .background(Theme.Color.background, in: RoundedRectangle(cornerRadius: Theme.Radius.m))
        .onScrollGeometryChange(for: ScrollEnd.self) { geometry in
            ScrollEnd(
                contentHeight: geometry.contentSize.height,
                atEnd: geometry.contentOffset.y + geometry.containerSize.height
                    >= geometry.contentSize.height - Theme.Layout.chatFollowSlack)
        } action: { old, new in
            // The answer growing is not the user scrolling: only a move over the same content
            // (or reaching the end) decides whether the conversation follows the answer.
            if new.contentHeight == old.contentHeight || new.atEnd { followsAnswer = new.atEnd }
        }
        .onChange(of: chat.revision) {
            if followsAnswer { position.scrollTo(edge: .bottom) }
        }
        .overlay(alignment: .bottomTrailing) {
            if !followsAnswer, chat.isAnswering {
                NidoButton("Go to End") {
                    followsAnswer = true
                    position.scrollTo(edge: .bottom)
                }
                .padding(Theme.Space.s)
                .accessibilityIdentifier("ai-chat-follow")
            }
        }
        .accessibilityIdentifier("ai-chat-conversation")
    }

    @ViewBuilder private func bubble(_ turn: LocalChatModel.Turn) -> some View {
        if turn.role == .user {
            HStack {
                Spacer(minLength: 0)
                Text(turn.text)
                    .font(.nido(Theme.TypeSize.body))
                    .foregroundStyle(Theme.Color.accentText)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, Theme.Space.s)
                    .padding(.horizontal, Theme.Space.m)
                    .background(Theme.Color.accent, in: RoundedRectangle(cornerRadius: Theme.Radius.m))
                    .frame(maxWidth: Theme.Layout.chatBubbleWidth, alignment: .trailing)
            }
        } else if turn.id == chat.answeringID, turn.text.isEmpty {
            HStack(spacing: Theme.Space.s) {
                ProgressView().controlSize(.small)
                Text(verbatim: chat.selectedModel.map {
                    String(localized: "\($0) is preparing the answer…", comment: "%@ is a model’s name.")
                } ?? String(localized: "The model is preparing the answer…"))
                    .font(.nido(Theme.TypeSize.body))
                    .foregroundStyle(Theme.Color.textSecondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("ai-chat-waiting")
        } else {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                NidoMarkdown(turn.text)
                if turn.id != chat.answeringID, !turn.text.isEmpty {
                    answerFooter(turn)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("ai-chat-answer")
        }
    }

    /// Under a complete answer: Copy, the model that wrote it and, when Ollama gave them, its
    /// duration and speed.
    private func answerFooter(_ turn: LocalChatModel.Turn) -> some View {
        HStack(spacing: Theme.Space.m) {
            let copied = copiedID == turn.id
            Button {
                chat.copy(turn.id)
                copiedID = turn.id
            } label: {
                Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                    .font(.nido(Theme.TypeSize.caption, .semibold))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(copied ? Theme.Color.accent : Theme.Color.textSecondary)
            .help("Copy the answer to the clipboard")
            .accessibilityIdentifier("ai-chat-copy")
            if let model = turn.model {
                Text(model)
                    .font(.nido(Theme.TypeSize.caption, .semibold))
                    .foregroundStyle(Theme.Color.textSecondary)
                    .accessibilityLabel("Model \(model)")
                    .accessibilityIdentifier("ai-chat-answer-model")
            }
            if let line = LocalChatModel.statsLine(turn.stats) {
                Text(line)
                    .font(.nido(Theme.TypeSize.caption))
                    .foregroundStyle(Theme.Color.textSecondary)
                    .monospacedDigit()
                    .accessibilityLabel("Generated in \(line)")
                    .accessibilityIdentifier("ai-chat-stats")
            }
        }
        .task(id: copiedID) {
            guard copiedID == turn.id else { return }
            try? await Task.sleep(for: .seconds(2))
            if copiedID == turn.id { copiedID = nil }
        }
    }

    private var input: some View {
        HStack(spacing: Theme.Space.s) {
            TextField("Write a message", text: $chat.draft)
                .textFieldStyle(.roundedBorder)
                .font(.nido(Theme.TypeSize.body))
                .onSubmit(send)
                .accessibilityIdentifier("ai-chat-input")
            if chat.isAnswering {
                NidoButton(label: Text("Stop (answer)", comment: "Stops the answer the model is writing.")) { chat.cancel() }
                    .keyboardShortcut(.cancelAction)
                    .help("Stop generating (Esc)")
                    .accessibilityIdentifier("ai-chat-stop")
            } else {
                NidoButton("Send", kind: .primary, action: send)
                    .disabled(!chat.canSend)
                    .accessibilityIdentifier("ai-chat-send")
            }
        }
    }

    private func send() {
        followsAnswer = true
        position.scrollTo(edge: .bottom)
        Task { await chat.send() }
    }
}
