// SPDX-License-Identifier: Apache-2.0
import AppKit
import NidoCore
import SwiftUI

/// The Remote mode (ScreensAI.swift `remoteMode`): the AI bridge of this VM to Hugging Face. The
/// switch is the VM's policy; "AI bridge active" (window strip, library) says whether it works now.
/// The first activation shows the privacy sheet; then the allowed models from the router's
/// catalog, the limits, today's usage, the last calls and what to set in the guest.
struct AIBridgeView: View {
    let bridge: AIBridgeModel
    let vmName: String
    /// The VM runs in another process (`nido start`): the bridge is not there.
    let runsElsewhere: Bool?

    private enum Mode: CaseIterable {
        case limits, usage

        var title: LocalizedStringKey {
            switch self {
            case .limits: "Models and Limits"
            case .usage: "Usage and Log"
            }
        }
    }

    @Environment(\.openSettings) private var openSettings
    @State private var mode = Mode.limits
    @State private var showsCatalog = false
    @State private var tokensPerDay = ""
    @State private var requestsPerMinute = ""
    @State private var maxTokens = ""

    var body: some View {
        AIColumn(
            title: "Remote", subtitle: "Hugging Face through Nido’s bridge: the text leaves the Mac.",
            identifier: "ai-remoto", accessory: { toggle }
        ) {
            if bridge.policy.enabled { enabledContent } else { offContent }
        }
        .task {
            await bridge.load()
            syncLimitFields()
            // Usage and calls while the view is shown (cancelled with it).
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { break }
                await bridge.refreshUsage()
            }
        }
        .onChange(of: bridge.policy) { syncLimitFields() }
        .sheet(isPresented: privacyShown) { privacySheet }
        .sheet(isPresented: $showsCatalog) {
            AICatalogSheet(bridge: bridge, vmName: vmName, onClose: { showsCatalog = false })
        }
    }

    // MARK: - Header

    private var toggle: some View {
        HStack(spacing: Theme.Space.s) {
            (bridge.policy.enabled
                ? Text("On", comment: "The AI bridge’s switch state (the bridge: masculine in it, es, fr).")
                : Text("Off", comment: "The AI bridge’s switch state (the bridge: masculine in it, es, fr)."))
                .font(.nido(Theme.TypeSize.body, .semibold))
                .foregroundStyle(bridge.policy.enabled ? Theme.Color.textPrimary : Theme.Color.textSecondary)
            Toggle("AI bridge", isOn: Binding(
                get: { bridge.policy.enabled }, set: { value in Task { await bridge.setEnabled(value) } }))
                .toggleStyle(.switch)
                .labelsHidden()
                .tint(Theme.Color.accent)
                .disabled(!bridge.isLoaded)
                .accessibilityIdentifier("ai-bridge-switch")
        }
    }

    // MARK: - Off

    private var offContent: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            if runsElsewhere == true {
                NidoNotice(kind: .info, verbatim: AIBridgeModel.elsewhereNotice(vmName: vmName), identifier: "ai-bridge-elsewhere")
            }
            if let error = bridge.saveError { NidoNotice(kind: .error, verbatim: error, identifier: "ai-bridge-save-error") }
            Text("With the bridge, programs in \(vmName) use models from Hugging Face Inference Providers as an OpenAI-compatible API. Your token stays on the Mac: the VM never receives it.")
                .font(.nido(Theme.TypeSize.body))
                .foregroundStyle(Theme.Color.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 0) {
                keyValue("Token", tokenState)
                keyValue("Default limits", Text(verbatim: [
                    String(localized: "200 000 tokens per day", comment: "The number is grouped with spaces, as the limit fields show it."),
                    String(localized: "20 requests per minute"),
                ].joined(separator: " · ")))
                keyValue("Log", "Time, model, tokens and outcome; never prompts or answers", last: true)
            }
            Text("The first time you turn it on, Nido shows you what leaves the Mac. Local mode is always available.")
                .font(.nido(Theme.TypeSize.caption))
                .foregroundStyle(Theme.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            NidoButton("Turn On the Bridge…", kind: .primary) { Task { await bridge.setEnabled(true) } }
                .disabled(!bridge.isLoaded)
                .accessibilityIdentifier("ai-bridge-enable")
        }
    }

    private var tokenState: Text {
        switch bridge.hasToken {
        case true?: Text("Saved in the Mac’s Keychain")
        case false?: Text("Not added yet: add it in Nido Settings")
        case nil: Text("Keychain status not available")
        }
    }

    private func keyValue(_ key: LocalizedStringKey, _ value: LocalizedStringKey, last: Bool = false) -> some View {
        keyValue(key, Text(value), last: last)
    }

    private func keyValue(_ key: LocalizedStringKey, _ value: Text, last: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.m) {
            Text(key)
                .font(.nido(Theme.TypeSize.caption))
                .foregroundStyle(Theme.Color.textSecondary)
                .frame(width: Theme.Layout.keyColumnWidth, alignment: .leading)
            value
                .font(.nido(Theme.TypeSize.body))
                .foregroundStyle(Theme.Color.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, Theme.Space.xs)
        .overlay(alignment: .bottom) {
            if !last { Rectangle().fill(Theme.Color.border).frame(height: Theme.Layout.hairline) }
        }
    }

    // MARK: - On

    @ViewBuilder private var enabledContent: some View {
        warnings
        Picker("View", selection: $mode) {
            ForEach(Mode.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        // The brand's green for the selected segment (the design), not the system accent.
        .tint(Theme.Color.accent)
        .accessibilityIdentifier("ai-remoto-mode")
        switch mode {
        case .limits: limitsContent
        case .usage: usageContent
        }
    }

    /// Why the bridge, though on, does not answer now.
    @ViewBuilder private var warnings: some View {
        if runsElsewhere == true {
            NidoNotice(kind: .info, verbatim: AIBridgeModel.elsewhereNotice(vmName: vmName), identifier: "ai-bridge-elsewhere")
        }
        if let warning = bridge.attachWarning {
            NidoNotice(kind: .error, verbatim: String(localized: "The AI bridge isn’t available in this session"), detail: warning,
                       identifier: "ai-bridge-attach-warning")
        }
        if let notice = bridge.notice {
            NidoNotice(kind: .warning, verbatim: String(localized: "The Hugging Face token is missing"), detail: notice,
                       actionLabel: String(localized: "Open Settings", comment: "Opens Nido Settings."), action: { openSettings() }, identifier: "ai-bridge-no-token")
        }
        if let error = bridge.saveError {
            NidoNotice(kind: .error, verbatim: error, identifier: "ai-bridge-save-error")
        }
    }

    @ViewBuilder private var limitsContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            AIGroupLabel("Allowed models · provider prices per million tokens, for reference")
                .padding(.bottom, Theme.Space.xs)
            if bridge.policy.allowedModels.isEmpty {
                Text("No models allowed: while the list is empty, the VM can’t use any model.")
                    .font(.nido(Theme.TypeSize.caption))
                    .foregroundStyle(Theme.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, Theme.Space.s)
            }
            let allowed = bridge.policy.allowedModels
            ForEach(Array(allowed.enumerated()), id: \.element) { index, id in
                AIListRow(title: id, detail: detail(for: id), last: index == allowed.count - 1) {
                    NidoButton("Remove") { Task { await bridge.setAllowed(id, false) } }
                        .accessibilityIdentifier("ai-bridge-remove-\(id)")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ai-bridge-allowed")
        NidoButton("Choose from Catalog…") { showsCatalog = true }
            .accessibilityIdentifier("ai-bridge-catalog")
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            AIGroupLabel("Limits for \(vmName)")
            HStack(alignment: .bottom, spacing: Theme.Space.s) {
                limitField("Tokens per day", $tokensPerDay, "ai-limit-tokens")
                limitField("Requests per minute", $requestsPerMinute, "ai-limit-requests")
                // The API's parameter name: never translated.
                limitField("max_tokens", $maxTokens, "ai-limit-max-tokens")
            }
            HStack(spacing: Theme.Space.s) {
                if let error = bridge.limitsError {
                    Text(error)
                        .font(.nido(Theme.TypeSize.caption, .semibold))
                        .foregroundStyle(Theme.Color.statusError)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("ai-limits-error")
                }
                Spacer(minLength: 0)
                NidoButton("Apply Limits", action: applyLimits)
                    .disabled(!limitsChanged)
                    .accessibilityIdentifier("ai-limits-apply")
            }
        }
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            AIGroupLabel("In the VM, with any API key")
            HStack(spacing: Theme.Space.s) {
                Text(Self.guestSetting)
                    .font(.system(size: Theme.TypeSize.body, design: .monospaced))
                    .foregroundStyle(Theme.Color.textPrimary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .padding(.horizontal, Theme.Space.s)
                    .frame(maxWidth: .infinity, minHeight: Theme.Layout.textFieldHeight, alignment: .leading)
                    .background(Theme.Color.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.s))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.s)
                        .strokeBorder(Theme.Color.border, lineWidth: Theme.Layout.hairline))
                    .accessibilityIdentifier("ai-bridge-guest-setting")
                NidoButton("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(Self.guestSetting, forType: .string)
                }
                .accessibilityIdentifier("ai-bridge-copy")
            }
            Text("The bridge answers only while \(vmName) is running in Nido. The token stays on the Mac.")
                .font(.nido(Theme.TypeSize.caption))
                .foregroundStyle(Theme.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    nonisolated static let guestSetting = "OPENAI_BASE_URL=\(AIBridgeModel.guestBaseURL)"

    private func detail(for id: String) -> String? {
        bridge.catalogModels.first { $0.id == id }.map(AIBridgeModel.catalogDetail)
    }

    private func limitField(_ label: LocalizedStringKey, _ text: Binding<String>, _ identifier: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text(label)
                .font(.nido(Theme.TypeSize.caption))
                .foregroundStyle(Theme.Color.textSecondary)
            TextField(label, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.nido(Theme.TypeSize.body))
                .monospacedDigit()
                .onSubmit(applyLimits)
                .accessibilityIdentifier(identifier)
        }
        .frame(maxWidth: .infinity)
    }

    private var limitsChanged: Bool {
        AIBridgeModel.parseLimit(tokensPerDay) != bridge.policy.tokensPerDay
            || AIBridgeModel.parseLimit(requestsPerMinute) != bridge.policy.requestsPerMinute
            || AIBridgeModel.parseLimit(maxTokens) != bridge.policy.maxTokensPerRequest
    }

    private func syncLimitFields() {
        tokensPerDay = AIBridgeModel.grouped(bridge.policy.tokensPerDay)
        requestsPerMinute = AIBridgeModel.grouped(bridge.policy.requestsPerMinute)
        maxTokens = AIBridgeModel.grouped(bridge.policy.maxTokensPerRequest)
    }

    private func applyLimits() {
        guard limitsChanged else { return }
        // Text that is not a number is out of range: the model says which limit and writes nothing.
        let day = AIBridgeModel.parseLimit(tokensPerDay) ?? 0
        let minute = AIBridgeModel.parseLimit(requestsPerMinute) ?? 0
        let request = AIBridgeModel.parseLimit(maxTokens) ?? 0
        Task { await bridge.setLimits(tokensPerDay: day, requestsPerMinute: minute, maxTokensPerRequest: request) }
    }

    // MARK: - Usage and log

    @ViewBuilder private var usageContent: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            AIGroupLabel("Today’s usage")
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                Text(AIBridgeModel.grouped(bridge.tokensUsedToday))
                    .font(.nido(Theme.TypeSize.title, .semibold))
                    .foregroundStyle(Theme.Color.textPrimary)
                    .monospacedDigit()
                Text("of \(AIBridgeModel.grouped(bridge.policy.tokensPerDay)) tokens · resets at midnight",
                     comment: "%@ is the daily token limit, grouped with spaces (200 000).")
                    .font(.nido(Theme.TypeSize.caption))
                    .foregroundStyle(Theme.Color.textSecondary)
            }
            NidoMeter(fraction: bridge.policy.tokensPerDay > 0
                      ? Double(bridge.tokensUsedToday) / Double(bridge.policy.tokensPerDay) : 0)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ai-bridge-usage")
        VStack(alignment: .leading, spacing: 0) {
            AIGroupLabel("Recent calls").padding(.bottom, Theme.Space.xs)
            if bridge.recentCalls.isEmpty {
                Text("No calls logged.")
                    .font(.nido(Theme.TypeSize.caption))
                    .foregroundStyle(Theme.Color.textSecondary)
                    .padding(.vertical, Theme.Space.s)
            } else {
                logRow([String(localized: "Time"), String(localized: "Model and Provider"), String(localized: "Tokens"),
                        String(localized: "Outcome"), String(localized: "Duration")], detail: nil, header: true)
                ForEach(Array(bridge.recentCalls.enumerated()), id: \.offset) { index, entry in
                    logRow(
                        [Self.timeText(entry.time), entry.model,
                         "\(AIBridgeModel.grouped(entry.inputTokens)) / \(AIBridgeModel.grouped(entry.outputTokens))",
                         AIBridgeModel.outcome(entry.status), AIBridgeModel.durationText(entry.durationMs)],
                        detail: entry.provider, last: index == bridge.recentCalls.count - 1)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ai-bridge-log")
        Text("The log never contains prompts or answers.")
            .font(.nido(Theme.TypeSize.caption))
            .foregroundStyle(Theme.Color.textSecondary)
    }

    private func logRow(_ cells: [String], detail: String?, header: Bool = false, last: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
            sizedCell(cells[0], header: header, fitting: Self.timeColumnTexts, minWidth: Theme.Layout.logTimeColumn,
                      alignment: .leading)
            VStack(alignment: .leading, spacing: 0) {
                cell(cells[1], header: header, tabular: false)
                if let detail { cell(detail, header: true, tabular: false) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            cell(cells[2], header: header).frame(width: Theme.Layout.logTokensColumn, alignment: .trailing)
            sizedCell(cells[3], header: header, fitting: Self.outcomeColumnTexts, minWidth: Theme.Layout.logOutcomeColumn,
                      alignment: .leading)
            sizedCell(cells[4], header: header, fitting: Self.durationColumnTexts, minWidth: Theme.Layout.logDurationColumn,
                      alignment: .trailing)
        }
        .padding(.vertical, Theme.Space.xs)
        .overlay(alignment: .bottom) {
            if !last { Rectangle().fill(Theme.Color.border).frame(height: Theme.Layout.hairline) }
        }
        .accessibilityElement(children: .combine)
    }

    /// The header and the fixed outcomes, in the app's language: the outcome column is never
    /// narrower than they are.
    private static let outcomeColumnTexts = Set([String(localized: "Outcome")]
        + [200, 429, 401, 403, 500].map(AIBridgeModel.outcome)).sorted()
    /// The header and the widest times (two-digit hours, morning and afternoon): English
    /// 12-hour times ("10:58:58 PM") do not fit the design's 60 pt.
    private static let timeColumnTexts: [String] = {
        let times = [23, 11].compactMap { Calendar.current.date(from: DateComponents(year: 2026, month: 12, day: 27,
                                                                                    hour: $0, minute: 58, second: 58)) }
        return Set([String(localized: "Time")] + times.map(timeText)).sorted()
    }()
    /// The header ("Duration" does not fit the design's 44 pt in English) and a value of 100 s or more.
    private static let durationColumnTexts = Set([String(localized: "Duration"),
                                                  AIBridgeModel.durationText(999_900)]).sorted()

    /// A column as wide as the widest of `texts` (hidden, in the header's semibold), and at least
    /// `minWidth`: every row gets the same width, so the columns stay aligned in every language.
    private func sizedCell(_ text: String, header: Bool, fitting texts: [String], minWidth: CGFloat,
                           alignment: Alignment) -> some View {
        ZStack(alignment: alignment) {
            ForEach(texts, id: \.self) { cell($0, header: true).hidden() }
            cell(text, header: header)
        }
        .fixedSize()
        .frame(minWidth: minWidth, alignment: alignment)
    }

    private func cell(_ text: String, header: Bool, tabular: Bool = true) -> some View {
        Text(text)
            .font(.nido(Theme.TypeSize.caption, header ? .semibold : .regular))
            .foregroundStyle(header ? Theme.Color.textSecondary : Theme.Color.textPrimary)
            .lineLimit(1)
            .truncationMode(.middle)
            .monospacedDigit()
    }

    nonisolated static func timeText(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .omitted, time: .standard).locale(.current))
    }

    // MARK: - Privacy

    private var privacyShown: Binding<Bool> {
        Binding(get: { bridge.isShowingPrivacyNotice }, set: { if !$0 { bridge.declinePrivacyNotice() } })
    }

    private var privacySheet: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text(AIBridgeModel.privacyTitle(vmName: vmName))
                .font(.nido(Theme.TypeSize.headline, .semibold))
                .foregroundStyle(Theme.Color.textPrimary)
            Text(AIBridgeModel.privacyNotice)
                .font(.nido(Theme.TypeSize.body))
                .foregroundStyle(Theme.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(AIBridgeModel.privacyLimits)
                .font(.nido(Theme.TypeSize.caption))
                .foregroundStyle(Theme.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Theme.Space.s) {
                Spacer(minLength: 0)
                NidoButton("Cancel") { bridge.declinePrivacyNotice() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("confirm-cancel")
                NidoButton("Turn On the Bridge", kind: .primary) { Task { await bridge.acknowledgePrivacy() } }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("confirm-action")
            }
        }
        .padding(Theme.Space.xl)
        .frame(width: Theme.Layout.confirmSheetWidth)
        .background(Theme.Color.surfaceRaised)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ai-bridge-privacy")
    }
}

/// ScreensAI.swift `catalogSheet`: the router's catalog, to choose the models the VM may use.
/// The choice is written only by "Save"; the models already allowed stay valid if the catalog
/// cannot be reached.
struct AICatalogSheet: View {
    let bridge: AIBridgeModel
    let vmName: String
    let onClose: () -> Void

    @State private var search = ""
    @State private var selection: Set<String> = []
    @State private var isSaving = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text("Allowed Models for \(vmName)")
                .font(.nido(Theme.TypeSize.headline, .semibold))
                .foregroundStyle(Theme.Color.textPrimary)
            Text("From the Hugging Face Inference Providers catalog. The VM sees only the models you choose; prices are the providers’, per million input / output tokens, for reference only.")
                .font(.nido(Theme.TypeSize.body))
                .foregroundStyle(Theme.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Theme.Space.s) {
                TextField("Search the catalog", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .font(.nido(Theme.TypeSize.body))
                    .accessibilityIdentifier("ai-catalog-search")
                NidoButton(bridge.catalogError == nil ? "Refresh" : "Try Again",
                           kind: bridge.catalogError == nil ? .secondary : .primary) {
                    Task { await bridge.loadCatalog(forceRefresh: true) }
                }
                .disabled(bridge.isLoadingCatalog)
                .accessibilityIdentifier("ai-catalog-refresh")
            }
            if let error = bridge.catalogError {
                NidoNotice(kind: .error, verbatim: error,
                           detail: String(localized: "The models already allowed stay valid: the VM keeps using them."),
                           identifier: "ai-catalog-error")
            } else if bridge.isLoadingCatalog, bridge.catalogModels.isEmpty {
                NidoIndeterminateBar()
            } else {
                Text("\(filtered.count) of \(bridge.catalogModels.count) models",
                     comment: "Models shown by the search, of all the catalog’s models: the plural follows the second number.")
                    .font(.nido(Theme.TypeSize.caption))
                    .foregroundStyle(Theme.Color.textSecondary)
                    .monospacedDigit()
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(filtered.enumerated()), id: \.element.id) { index, model in
                            row(model, last: index == filtered.count - 1)
                        }
                    }
                }
                .frame(height: Theme.Layout.catalogListHeight)
                .accessibilityIdentifier("ai-catalog-list")
            }
            HStack(spacing: Theme.Space.s) {
                Spacer(minLength: 0)
                NidoButton("Cancel", action: onClose)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("confirm-cancel")
                NidoButton("Save", kind: .primary, action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSaving || bridge.catalogModels.isEmpty)
                    .accessibilityIdentifier("confirm-action")
            }
        }
        .padding(Theme.Space.xl)
        .frame(width: Theme.Layout.catalogSheetWidth)
        .background(Theme.Color.surfaceRaised)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ai-catalog-sheet")
        .task {
            selection = Set(bridge.policy.allowedModels)
            await bridge.loadCatalog()
        }
    }

    private var filtered: [CatalogModel] {
        let needle = search.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return bridge.catalogModels }
        return bridge.catalogModels.filter { $0.id.localizedCaseInsensitiveContains(needle) }
    }

    private func row(_ model: CatalogModel, last: Bool) -> some View {
        HStack(spacing: Theme.Space.m) {
            Toggle(model.id, isOn: Binding(
                get: { selection.contains(model.id) },
                set: { on in if on { selection.insert(model.id) } else { selection.remove(model.id) } }))
                .toggleStyle(.checkbox)
                .labelsHidden()
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text(model.id)
                    .font(.nido(Theme.TypeSize.body, .semibold))
                    .foregroundStyle(Theme.Color.textPrimary)
                Text(AIBridgeModel.catalogDetail(model))
                    .font(.nido(Theme.TypeSize.caption))
                    .foregroundStyle(Theme.Color.textSecondary)
                    .monospacedDigit()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, Theme.Space.s)
        .overlay(alignment: .bottom) {
            if !last { Rectangle().fill(Theme.Color.border).frame(height: Theme.Layout.hairline) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("ai-catalog-\(model.id)")
    }

    /// Writes the difference: new models allowed, unchecked catalog models removed.
    private func save() {
        let chosen = selection
        isSaving = true
        Task {
            let catalogIDs = Set(bridge.catalogModels.map(\.id))
            for id in bridge.policy.allowedModels where catalogIDs.contains(id) && !chosen.contains(id) {
                await bridge.setAllowed(id, false)
            }
            for id in chosen.sorted() where !bridge.policy.allowedModels.contains(id) {
                await bridge.setAllowed(id, true)
            }
            isSaving = false
            if bridge.saveError == nil { onClose() }
        }
    }
}
