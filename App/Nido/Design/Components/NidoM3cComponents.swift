// SPDX-License-Identifier: Apache-2.0
import SwiftUI

/// ScreensAI.swift Avviso: a notice inside a view or a form (attenzione · errore · informazione),
/// with an optional detail and up to two actions.
///
/// Its texts are copy (English keys); `init(kind:verbatim:…)` shows strings as given: runtime
/// text (an error's description, guest output) or text a model already localized.
struct NidoNotice: View {
    enum Kind { case warning, error, info }

    private let kind: Kind
    private let title: Text
    private let detail: Text?
    private let actionLabel: Text?
    private let action: (() -> Void)?
    private let identifier: String
    /// The second action, before the first ("Not Now" next to "Turn Off").
    private let secondaryLabel: Text?
    private let secondaryAction: (() -> Void)?

    init(kind: Kind, title: LocalizedStringKey, detail: LocalizedStringKey? = nil,
         actionLabel: LocalizedStringKey? = nil, action: (() -> Void)? = nil, identifier: String = "notice",
         secondaryLabel: LocalizedStringKey? = nil, secondaryAction: (() -> Void)? = nil) {
        self.init(kind: kind, title: Text(title), detail: detail.map { Text($0) },
                  actionLabel: actionLabel.map { Text($0) }, action: action, identifier: identifier,
                  secondaryLabel: secondaryLabel.map { Text($0) }, secondaryAction: secondaryAction)
    }

    init(kind: Kind, verbatim title: String, detail: String? = nil,
         actionLabel: String? = nil, action: (() -> Void)? = nil, identifier: String = "notice",
         secondaryLabel: String? = nil, secondaryAction: (() -> Void)? = nil) {
        self.init(kind: kind, title: Text(verbatim: title), detail: detail.map { Text(verbatim: $0) },
                  actionLabel: actionLabel.map { Text(verbatim: $0) }, action: action, identifier: identifier,
                  secondaryLabel: secondaryLabel.map { Text(verbatim: $0) }, secondaryAction: secondaryAction)
    }

    private init(kind: Kind, title: Text, detail: Text?, actionLabel: Text?, action: (() -> Void)?,
                 identifier: String, secondaryLabel: Text?, secondaryAction: (() -> Void)?) {
        self.kind = kind
        self.title = title
        self.detail = detail
        self.actionLabel = actionLabel
        self.action = action
        self.identifier = identifier
        self.secondaryLabel = secondaryLabel
        self.secondaryAction = secondaryAction
    }

    private var tint: Color {
        switch kind {
        case .warning: Theme.Color.statusPaused
        case .error: Theme.Color.statusError
        case .info: Theme.Color.accent
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.m) {
            Circle()
                .fill(tint)
                .frame(width: Theme.Layout.noticeDot, height: Theme.Layout.noticeDot)
                .frame(height: Theme.Layout.noticeDotLineHeight)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                title
                    .font(.nido(Theme.TypeSize.body, .semibold))
                    .foregroundStyle(Theme.Color.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail {
                    detail
                        .font(.nido(Theme.TypeSize.caption))
                        .foregroundStyle(Theme.Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let secondaryLabel, let secondaryAction {
                NidoButton(label: secondaryLabel, kind: .secondary, action: secondaryAction)
                    .accessibilityIdentifier("\(identifier)-secondary")
            }
            if let actionLabel, let action {
                NidoButton(label: actionLabel, action: action)
                    .accessibilityIdentifier("\(identifier)-action")
            }
        }
        .padding(.vertical, Theme.Space.m)
        .padding(.horizontal, Theme.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Color.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.m))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.m)
                .strokeBorder(kind == .info ? Theme.Color.border : tint, lineWidth: Theme.Layout.hairline)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }
}

/// Components.swift `bridgePill`: "AI bridge active" (only while the bridge is really attached).
struct NidoBridgePill: View {
    var body: some View {
        HStack(spacing: Theme.Space.xs) {
            Circle().fill(Theme.Color.accent).frame(width: Theme.Layout.pillDot, height: Theme.Layout.pillDot)
            Text("AI bridge active")
                .font(.nido(Theme.TypeSize.caption, .semibold))
                .foregroundStyle(Theme.Color.textPrimary)
        }
        .padding(.horizontal, Theme.Space.s)
        .frame(height: Theme.Layout.pillHeight)
        .background(Theme.Color.background, in: RoundedRectangle(cornerRadius: Theme.Radius.m))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.m)
            .strokeBorder(Theme.Color.accent, lineWidth: Theme.Layout.hairline))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("bridge-pill")
    }
}

/// ScreensAI.swift PassoPreparazione: one step of the provisioning, its state in shape, colour
/// and words (filled: fatto, non riuscito; thick ring: in corso; thin ring: in attesa).
struct NidoProvisioningStep: View {
    typealias State = ProvisioningModel.Row.State

    private let label: Text
    private let state: State
    private let status: Text

    init(_ label: LocalizedStringKey, state: State, status: LocalizedStringKey) {
        self.label = Text(label)
        self.state = state
        self.status = Text(status)
    }

    /// The model's rows: label and status shown as given.
    init(verbatim label: String, state: State, status: String) {
        self.label = Text(verbatim: label)
        self.state = state
        self.status = Text(verbatim: status)
    }

    private var tint: Color {
        switch state {
        case .done: Theme.Color.statusRunning
        case .running: Theme.Color.accent
        case .waiting: Theme.Color.statusStopped
        case .failed: Theme.Color.statusError
        }
    }

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            mark
                .frame(width: Theme.Layout.stepRing, height: Theme.Layout.stepRing)
                .accessibilityHidden(true)
            label
                .font(.nido(Theme.TypeSize.body, state == .running ? .semibold : .regular))
                .foregroundStyle(state == .waiting ? Theme.Color.textSecondary : Theme.Color.textPrimary)
                .lineLimit(1)
            Spacer(minLength: Theme.Space.s)
            status
                .font(.nido(Theme.TypeSize.caption, state == .failed ? .semibold : .regular))
                .foregroundStyle(state == .failed ? Theme.Color.statusError : Theme.Color.textSecondary)
                .monospacedDigit()
        }
        .frame(minHeight: Theme.Layout.stepRowHeight)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var mark: some View {
        switch state {
        case .running:
            Circle()
                .strokeBorder(tint, lineWidth: Theme.Layout.stepRingStroke)
                .overlay(Circle().fill(tint).frame(width: Theme.Layout.stepRingCentre,
                                                   height: Theme.Layout.stepRingCentre))
        case .waiting:
            Circle()
                .strokeBorder(tint, lineWidth: Theme.Layout.stepWaitingStroke)
                .frame(width: Theme.Layout.stepDot, height: Theme.Layout.stepDot)
        case .done, .failed:
            Circle().fill(tint).frame(width: Theme.Layout.stepDot, height: Theme.Layout.stepDot)
        }
    }
}

/// ScreensAI.swift `panel`: a box inside a view with a headline.
struct NidoPanel<Content: View>: View {
    private let title: Text?
    private let spacing: CGFloat
    @ViewBuilder private let content: () -> Content

    /// `title` nil: a box without a headline.
    init(title: LocalizedStringKey?, spacing: CGFloat = Theme.Space.s, @ViewBuilder content: @escaping () -> Content) {
        self.title = title.map { Text($0) }
        self.spacing = spacing
        self.content = content
    }

    init(verbatim title: String, spacing: CGFloat = Theme.Space.s, @ViewBuilder content: @escaping () -> Content) {
        self.title = Text(verbatim: title)
        self.spacing = spacing
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            if let title {
                title
                    .font(.nido(Theme.TypeSize.headline, .semibold))
                    .foregroundStyle(Theme.Color.textPrimary)
                    .accessibilityAddTraits(.isHeader)
            }
            content()
        }
        .padding(Theme.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Color.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.m))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.m)
            .strokeBorder(Theme.Color.border, lineWidth: Theme.Layout.hairline))
    }
}

/// ScreensAI.swift ProfileChoice tile (Debian Base, Debian AI Starter, From Template). `id` names
/// the tile for the UI tests (`profile-<id>`).
struct NidoProfileTile: View {
    private let title: Text
    private let detail: Text
    private let id: String
    private let isSelected: Bool
    private let action: () -> Void

    init(_ title: LocalizedStringKey, id: String, detail: LocalizedStringKey, isSelected: Bool,
         action: @escaping () -> Void) {
        self.title = Text(title)
        self.detail = Text(detail)
        self.id = id
        self.isSelected = isSelected
        self.action = action
    }

    /// Title and detail shown as given; `id` nil makes the title the tile's id.
    init(verbatim title: String, id: String? = nil, detail: String, isSelected: Bool, action: @escaping () -> Void) {
        self.title = Text(verbatim: title)
        self.detail = Text(verbatim: detail)
        self.id = id ?? title
        self.isSelected = isSelected
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                title
                    .font(.nido(Theme.TypeSize.body, .semibold))
                    .foregroundStyle(Theme.Color.textPrimary)
                detail
                    .font(.nido(Theme.TypeSize.caption))
                    .foregroundStyle(Theme.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .padding(Theme.Space.m)
            .frame(maxWidth: .infinity, minHeight: Theme.Layout.profileTileHeight,
                   maxHeight: Theme.Layout.profileTileHeight, alignment: .topLeading)
            .background(isSelected ? Theme.Color.surfaceRaised : Theme.Color.surface,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.m))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.m)
                    .strokeBorder(isSelected ? Theme.Color.accent : Theme.Color.border,
                                  lineWidth: isSelected ? Theme.Layout.selectedStroke : Theme.Layout.hairline)
            }
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.m))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("profile-\(id)")
    }
}

/// ScreensAI.swift TemplateChoice row: a radio, the template's name and its resources, shown as
/// given (the name is the row's id, `template-<name>`).
struct NidoChoiceRow: View {
    private let title: String
    private let detail: String
    private let isSelected: Bool
    private let action: () -> Void

    init(verbatim title: String, detail: String, isSelected: Bool, action: @escaping () -> Void) {
        self.title = title
        self.detail = detail
        self.isSelected = isSelected
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.m) {
                radio
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Text(verbatim: title)
                        .font(.nido(Theme.TypeSize.body, .semibold))
                        .foregroundStyle(Theme.Color.textPrimary)
                    Text(verbatim: detail)
                        .font(.nido(Theme.TypeSize.caption))
                        .foregroundStyle(Theme.Color.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, Theme.Space.m)
            .padding(.horizontal, Theme.Space.l)
            .background(isSelected ? Theme.Color.surfaceRaised : Theme.Color.surface,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.m))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.m)
                    .strokeBorder(isSelected ? Theme.Color.accent : Theme.Color.border,
                                  lineWidth: isSelected ? Theme.Layout.selectedStroke : Theme.Layout.hairline)
            }
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.m))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("template-\(title)")
    }

    @ViewBuilder private var radio: some View {
        if isSelected {
            Circle().fill(Theme.Color.accent)
                .overlay(Circle().fill(Theme.Color.accentText)
                    .frame(width: Theme.Layout.radioCentre, height: Theme.Layout.radioCentre))
                .frame(width: Theme.Layout.radio, height: Theme.Layout.radio)
        } else {
            Circle().strokeBorder(Theme.Color.statusStopped, lineWidth: Theme.Layout.radioStroke)
                .frame(width: Theme.Layout.radio, height: Theme.Layout.radio)
        }
    }
}

/// A native linear indicator in the design's colours (ProgressView; no chart library).
struct NidoMeter: View {
    let fraction: Double
    var tint: Color = Theme.Color.accent

    var body: some View {
        ProgressView(value: min(1, max(0, fraction)))
            .progressViewStyle(.linear)
            .tint(tint)
            .accessibilityValue(Text("\(Int((min(1, max(0, fraction)) * 100).rounded()))%",
                                     comment: "A meter's value in percent. [not a count]"))
    }
}
