// SPDX-License-Identifier: Apache-2.0
import SwiftUI

/// Components.swift WizardStep: step indicator, title and description, the page's content, an
/// optional error line and the navigation (Back · Cancel · Next).
///
/// Title, subtitle, message and the next button are copy (English keys); `init(…verbatim:…)`
/// shows the model's strings as given.
struct NidoWizardStep<Content: View>: View {
    private let step: Int
    private let stepCount: Int
    private let title: Text
    private let subtitle: Text
    /// Shown above the navigation in statusError (the "errore" variant), e.g. why Next is disabled.
    private let message: Text?
    /// Hidden on the first step.
    private let showsBack: Bool
    private let backEnabled: Bool
    private let cancelEnabled: Bool
    private let nextLabel: Text
    private let nextEnabled: Bool
    private let onBack: () -> Void
    private let onCancel: () -> Void
    private let onNext: () -> Void
    @ViewBuilder private let content: () -> Content

    init(step: Int, stepCount: Int, title: LocalizedStringKey, subtitle: LocalizedStringKey,
         message: LocalizedStringKey? = nil, showsBack: Bool, backEnabled: Bool, cancelEnabled: Bool,
         nextLabel: LocalizedStringKey, nextEnabled: Bool, onBack: @escaping () -> Void,
         onCancel: @escaping () -> Void, onNext: @escaping () -> Void, @ViewBuilder content: @escaping () -> Content) {
        self.init(step: step, stepCount: stepCount, title: Text(title), subtitle: Text(subtitle),
                  message: message.map { Text($0) }, showsBack: showsBack, backEnabled: backEnabled,
                  cancelEnabled: cancelEnabled, nextLabel: Text(nextLabel), nextEnabled: nextEnabled,
                  onBack: onBack, onCancel: onCancel, onNext: onNext, content: content)
    }

    init(step: Int, stepCount: Int, verbatim title: String, subtitle: String,
         message: String? = nil, showsBack: Bool, backEnabled: Bool, cancelEnabled: Bool,
         nextLabel: String, nextEnabled: Bool, onBack: @escaping () -> Void,
         onCancel: @escaping () -> Void, onNext: @escaping () -> Void, @ViewBuilder content: @escaping () -> Content) {
        self.init(step: step, stepCount: stepCount, title: Text(verbatim: title), subtitle: Text(verbatim: subtitle),
                  message: message.map { Text(verbatim: $0) }, showsBack: showsBack, backEnabled: backEnabled,
                  cancelEnabled: cancelEnabled, nextLabel: Text(verbatim: nextLabel), nextEnabled: nextEnabled,
                  onBack: onBack, onCancel: onCancel, onNext: onNext, content: content)
    }

    private init(step: Int, stepCount: Int, title: Text, subtitle: Text, message: Text?, showsBack: Bool,
                 backEnabled: Bool, cancelEnabled: Bool, nextLabel: Text, nextEnabled: Bool,
                 onBack: @escaping () -> Void, onCancel: @escaping () -> Void, onNext: @escaping () -> Void,
                 content: @escaping () -> Content) {
        self.step = step
        self.stepCount = stepCount
        self.title = title
        self.subtitle = subtitle
        self.message = message
        self.showsBack = showsBack
        self.backEnabled = backEnabled
        self.cancelEnabled = cancelEnabled
        self.nextLabel = nextLabel
        self.nextEnabled = nextEnabled
        self.onBack = onBack
        self.onCancel = onCancel
        self.onNext = onNext
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            HStack(spacing: Theme.Space.s) {
                ForEach(1...stepCount, id: \.self) { index in
                    RoundedRectangle(cornerRadius: Theme.Layout.wizardStepSegmentHeight / 2)
                        .fill(index <= step ? Theme.Color.accent : Theme.Color.border)
                        .frame(width: Theme.Layout.wizardStepSegmentWidth, height: Theme.Layout.wizardStepSegmentHeight)
                }
                Text("Step \(step) of \(stepCount)", comment: "The wizard's progress. [not a count]")
                    .font(.nido(Theme.TypeSize.caption))
                    .foregroundStyle(Theme.Color.textSecondary)
                    .accessibilityIdentifier("wizard-step-label")
            }
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                title
                    .font(.nido(Theme.TypeSize.title, .semibold))
                    .foregroundStyle(Theme.Color.textPrimary)
                    .accessibilityIdentifier("wizard-title")
                subtitle
                    .font(.nido(Theme.TypeSize.body))
                    .foregroundStyle(Theme.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: Theme.Space.s, content: content)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let message {
                message
                    .font(.nido(Theme.TypeSize.caption, .semibold))
                    .foregroundStyle(Theme.Color.statusError)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("wizard-message")
            }
            HStack(spacing: Theme.Space.s) {
                if showsBack {
                    NidoButton("Back", action: onBack)
                        .disabled(!backEnabled)
                        .accessibilityIdentifier("wizard-back")
                }
                Spacer(minLength: 0)
                NidoButton("Cancel", action: onCancel)
                    .disabled(!cancelEnabled)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("wizard-cancel")
                NidoButton(label: nextLabel, kind: .primary, action: onNext)
                    .disabled(!nextEnabled)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("wizard-next")
            }
        }
        .padding(Theme.Space.xl)
        .frame(width: Theme.Layout.wizardWidth)
        .background(Theme.Color.surface)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wizard")
    }
}

/// Components.swift OSTile: normale · selezionato · disattivato. `name` is the system's name, never
/// translated; `detail` is copy (`verbatim:` for the model's text).
struct NidoOSTile: View {
    enum State { case normal, selected, disabled }

    private let glyph: String
    private let name: String
    private let detail: Text
    private let state: State

    init(glyph: String, name: String, detail: LocalizedStringKey, state: State = .normal) {
        self.glyph = glyph
        self.name = name
        self.detail = Text(detail)
        self.state = state
    }

    init(glyph: String, name: String, verbatim detail: String, state: State = .normal) {
        self.glyph = glyph
        self.name = name
        self.detail = Text(verbatim: detail)
        self.state = state
    }

    var body: some View {
        VStack(spacing: Theme.Space.s) {
            NidoSystemMark(system: .init(glyph: glyph), size: Theme.Layout.osTileGlyph,
                           fill: state == .selected ? Theme.Color.accent : Theme.Color.background,
                           mark: state == .selected ? Theme.Color.accentText : Theme.Color.textSecondary)
            Text(verbatim: name)
                .font(.nido(Theme.TypeSize.body, .semibold))
                .foregroundStyle(Theme.Color.textPrimary)
            detail
                .font(.nido(Theme.TypeSize.caption))
                .foregroundStyle(Theme.Color.textSecondary)
        }
        // A name or detail that wraps ("Ubuntu Server", a long translation) stays centred, and the
        // tile fills the row's height: the row gives every tile the tallest one's (see the wizard).
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(Theme.Space.l)
        .background(state == .selected ? Theme.Color.surfaceRaised : Theme.Color.surface,
                    in: RoundedRectangle(cornerRadius: Theme.Radius.m))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.m)
                .strokeBorder(state == .selected ? Theme.Color.accent : Theme.Color.border,
                              lineWidth: state == .selected ? Theme.Layout.selectedStroke : Theme.Layout.hairline)
        }
        .opacity(state == .disabled ? Theme.Layout.disabledOpacity : 1)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(state == .selected ? .isSelected : [])
        .accessibilityIdentifier("os-tile-\(name)")
    }
}

/// The row look shared by InfoRow, PickerRow, ResourceStepper and ToggleRow.
private struct NidoRowBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.vertical, Theme.Space.m)
            .padding(.horizontal, Theme.Space.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.Color.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.m))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.m)
                    .strokeBorder(Theme.Color.border, lineWidth: Theme.Layout.hairline)
            }
    }
}

extension View {
    func nidoRow() -> some View { modifier(NidoRowBackground()) }
}

/// Screens.swift InfoRow: a read-only value, with or without a note. `trailing` replaces the value
/// (the editable name of the summary). Label and note are copy (English keys); `verbatim:` shows
/// strings as given.
struct NidoInfoRow<Trailing: View>: View {
    private let label: Text
    private let note: Text?
    @ViewBuilder private let trailing: () -> Trailing

    init(label: LocalizedStringKey, note: LocalizedStringKey? = nil, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.label = Text(label)
        self.note = note.map { Text($0) }
        self.trailing = trailing
    }

    init(verbatim label: String, note: String? = nil, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.label = Text(verbatim: label)
        self.note = note.map { Text(verbatim: $0) }
        self.trailing = trailing
    }

    var body: some View {
        // A text value (NidoRowValue) never cuts the label: NidoInfoRowLayout wraps a long value.
        // Fields and buttons keep the plain row.
        if Trailing.self == NidoRowValue.self {
            NidoInfoRowLayout(spacing: Theme.Space.m) {
                labelColumn(fixedLabel: true)
                trailing()
            }
            .nidoRow()
        } else {
            HStack(spacing: Theme.Space.m) {
                labelColumn(fixedLabel: false)
                trailing()
            }
            .nidoRow()
        }
    }

    private func labelColumn(fixedLabel: Bool) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            label
                .font(.nido(Theme.TypeSize.body, .semibold))
                .foregroundStyle(Theme.Color.textPrimary)
                .fixedSize(horizontal: fixedLabel, vertical: false)
            if let note {
                note
                    .font(.nido(Theme.TypeSize.caption))
                    .foregroundStyle(Theme.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A label and a value. The value is data (a name, a size, a version), shown as given.
extension NidoInfoRow where Trailing == NidoRowValue {
    init(_ label: LocalizedStringKey, _ value: String, note: LocalizedStringKey? = nil) {
        self.init(label: label, note: note) { NidoRowValue(text: value) }
    }

    init(verbatim label: String, _ value: String, note: String? = nil) {
        self.init(verbatim: label, note: note) { NidoRowValue(text: value) }
    }
}

/// The row of `NidoInfoRow`: the label's column and the value. A value that fits next to the label
/// gets its whole width on one line, as in the design, and the label's column (whose note wraps)
/// takes the rest, if a note keeps at least half the row. A value too long for that (a long
/// translation) gets half the row and wraps, so the label is never cut.
struct NidoInfoRowLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 2 else { return subviews.first?.sizeThatFits(proposal) ?? .zero }
        let widths = columnWidths(proposal.width, subviews)
        let leading = subviews[0].sizeThatFits(ProposedViewSize(width: widths.leading, height: nil))
        let trailing = subviews[1].sizeThatFits(ProposedViewSize(width: widths.trailing, height: nil))
        return CGSize(width: widths.leading + spacing + widths.trailing, height: max(leading.height, trailing.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else {
            subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
            return
        }
        let widths = columnWidths(bounds.width, subviews)
        subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading,
                          proposal: ProposedViewSize(width: widths.leading, height: nil))
        subviews[1].place(at: CGPoint(x: bounds.maxX, y: bounds.midY), anchor: .trailing,
                          proposal: ProposedViewSize(width: widths.trailing, height: nil))
    }

    private func columnWidths(_ width: CGFloat?, _ subviews: Subviews) -> (leading: CGFloat, trailing: CGFloat) {
        let value = subviews[1].sizeThatFits(.unspecified).width
        guard let width else { return (subviews[0].sizeThatFits(.unspecified).width, value) }
        let available = max(0, width - spacing)
        // The narrowest the label's column can be: the label on one line, the note wrapped.
        let label = subviews[0].sizeThatFits(ProposedViewSize(width: 0, height: nil)).width
        // A note keeps at least half the row (it is not squeezed into a narrow column), unless it
        // is shorter than that.
        let ideal = subviews[0].sizeThatFits(.unspecified).width
        let half = max(label, available / 2)
        if value + min(ideal, half) <= available { return (available - value, value) }
        let leading = min(available, half)
        return (leading, available - leading)
    }
}

struct NidoRowValue: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(.nido(Theme.TypeSize.body))
            .foregroundStyle(Theme.Color.textSecondary)
            // One line whenever it fits next to the label (NidoInfoRowLayout); a longer value wraps.
            .lineLimit(3)
            .multilineTextAlignment(.trailing)
            .truncationMode(.middle)
    }
}

/// Screens.swift PickerRow: the chosen file and "Choose…". Label and button are copy (English
/// keys); the path is shown as given.
struct NidoPickerRow: View {
    private let label: Text
    private let path: String
    /// "Choose…" for a file picker, "Show in Finder" for a read-only folder.
    private let buttonLabel: Text
    private let onChoose: () -> Void

    init(label: LocalizedStringKey, path: String, buttonLabel: LocalizedStringKey = "Choose…",
         onChoose: @escaping () -> Void) {
        self.label = Text(label)
        self.path = path
        self.buttonLabel = Text(buttonLabel)
        self.onChoose = onChoose
    }

    /// `buttonLabel` nil is Choose….
    init(verbatim label: String, path: String, buttonLabel: String? = nil, onChoose: @escaping () -> Void) {
        self.label = Text(verbatim: label)
        self.path = path
        self.buttonLabel = buttonLabel.map { Text(verbatim: $0) } ?? Text("Choose…")
        self.onChoose = onChoose
    }

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                label
                    .font(.nido(Theme.TypeSize.body, .semibold))
                    .foregroundStyle(Theme.Color.textPrimary)
                Text(verbatim: path)
                    .font(.nido(Theme.TypeSize.caption))
                    .foregroundStyle(Theme.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("picker-path")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            NidoButton(label: buttonLabel, action: onChoose)
                .accessibilityIdentifier("picker-choose")
        }
        .nidoRow()
    }
}

/// ScreensMac.swift TextFieldRow: the row look of InfoRow, a label and its note, with a bordered
/// field in place of the value. Label, note and placeholder are copy (English keys); `verbatim:`
/// shows strings as given.
struct NidoTextFieldRow: View {
    private let label: Text
    private let note: Text
    private let placeholder: Text
    @Binding var text: String
    /// The field's border turns statusError (the value is refused).
    private let isInvalid: Bool
    private let identifier: String

    init(label: LocalizedStringKey, note: LocalizedStringKey, placeholder: LocalizedStringKey,
         text: Binding<String>, isInvalid: Bool = false, identifier: String = "text-field-row") {
        self.init(label: Text(label), note: Text(note), placeholder: Text(placeholder), text: text,
                  isInvalid: isInvalid, identifier: identifier)
    }

    init(verbatim label: String, note: String, placeholder: String,
         text: Binding<String>, isInvalid: Bool = false, identifier: String = "text-field-row") {
        self.init(label: Text(verbatim: label), note: Text(verbatim: note), placeholder: Text(verbatim: placeholder),
                  text: text, isInvalid: isInvalid, identifier: identifier)
    }

    private init(label: Text, note: Text, placeholder: Text, text: Binding<String>, isInvalid: Bool,
                 identifier: String) {
        self.label = label
        self.note = note
        self.placeholder = placeholder
        self._text = text
        self.isInvalid = isInvalid
        self.identifier = identifier
    }

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                label
                    .font(.nido(Theme.TypeSize.body, .semibold))
                    .foregroundStyle(Theme.Color.textPrimary)
                note
                    .font(.nido(Theme.TypeSize.caption))
                    .foregroundStyle(Theme.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            TextField(text: $text) { placeholder }
                .textFieldStyle(.plain)
                .font(.nido(Theme.TypeSize.body))
                .foregroundStyle(Theme.Color.textPrimary)
                .padding(.horizontal, Theme.Space.s)
                .frame(width: Theme.Layout.textFieldRowFieldWidth, height: Theme.Layout.textFieldHeight)
                .background(Theme.Color.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.s))
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.Radius.s)
                        .strokeBorder(isInvalid ? Theme.Color.statusError : Theme.Color.border,
                                      lineWidth: isInvalid ? Theme.Layout.selectedStroke : Theme.Layout.hairline)
                }
                .accessibilityIdentifier(identifier)
        }
        .nidoRow()
    }
}

/// Components.swift ResourceStepper: entro i limiti · fuori limite (`error` replaces the detail).
/// The label is copy (an English key); detail, error and unit come from the model, shown as given.
/// `id` names the row for the UI tests (`stepper-<id>`).
struct NidoResourceStepper: View {
    private let label: Text
    private let id: String
    private let detail: String
    private let error: String?
    @Binding var value: Int
    /// "GiB", or empty for a plain count.
    private let unit: String
    private let onDecrement: () -> Void
    private let onIncrement: () -> Void

    init(label: LocalizedStringKey, id: String, detail: String, error: String? = nil, value: Binding<Int>,
         unit: String = "", onDecrement: @escaping () -> Void, onIncrement: @escaping () -> Void) {
        self.init(label: Text(label), id: id, detail: detail, error: error, value: value, unit: unit,
                  onDecrement: onDecrement, onIncrement: onIncrement)
    }

    /// The label shown as given, and the row's id.
    init(verbatim label: String, detail: String, error: String? = nil, value: Binding<Int>,
         unit: String = "", onDecrement: @escaping () -> Void, onIncrement: @escaping () -> Void) {
        self.init(label: Text(verbatim: label), id: label, detail: detail, error: error, value: value, unit: unit,
                  onDecrement: onDecrement, onIncrement: onIncrement)
    }

    private init(label: Text, id: String, detail: String, error: String?, value: Binding<Int>, unit: String,
                 onDecrement: @escaping () -> Void, onIncrement: @escaping () -> Void) {
        self.label = label
        self.id = id
        self.detail = detail
        self.error = error
        self._value = value
        self.unit = unit
        self.onDecrement = onDecrement
        self.onIncrement = onIncrement
    }

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                label
                    .font(.nido(Theme.TypeSize.body, .semibold))
                    .foregroundStyle(Theme.Color.textPrimary)
                Text(verbatim: error ?? detail)
                    .font(.nido(Theme.TypeSize.caption, error == nil ? .regular : .semibold))
                    .foregroundStyle(error == nil ? Theme.Color.textSecondary : Theme.Color.statusError)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("stepper-detail-\(id)")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: Theme.Space.xs) {
                TextField(value: $value, format: .number) { label }
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .accessibilityIdentifier("stepper-value-\(id)")
                if !unit.isEmpty { Text(verbatim: unit) }
            }
            .font(.nido(Theme.TypeSize.body))
            .foregroundStyle(Theme.Color.textPrimary)
            .padding(.horizontal, Theme.Space.s)
            .frame(width: Theme.Layout.stepperValueWidth, height: Theme.Layout.stepperHeight)
            .background(Theme.Color.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.s))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.s)
                    .strokeBorder(error == nil ? Theme.Color.border : Theme.Color.statusError,
                                  lineWidth: error == nil ? Theme.Layout.hairline : Theme.Layout.selectedStroke)
            }
            HStack(spacing: 0) {
                arrow("−", name: Text("Decrease \(label)", comment: "A stepper's button; the value's name."),
                      action: onDecrement)
                Rectangle().fill(Theme.Color.border).frame(width: Theme.Layout.hairline)
                arrow("+", name: Text("Increase \(label)", comment: "A stepper's button; the value's name."),
                      action: onIncrement)
            }
            .frame(height: Theme.Layout.stepperHeight)
            .background(Theme.Color.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.s))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.s)
                    .strokeBorder(Theme.Color.border, lineWidth: Theme.Layout.hairline)
            }
        }
        .nidoRow()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("stepper-\(id)")
    }

    private func arrow(_ symbol: String, name: Text, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(verbatim: symbol)
                .font(.nido(Theme.TypeSize.body, .semibold))
                .foregroundStyle(Theme.Color.textPrimary)
                .frame(width: Theme.Layout.stepperArrowWidth, height: Theme.Layout.stepperHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
    }
}

/// The ProgressPanel bar when the fraction is not known: a segment sweeping the track (still,
/// with Reduce Motion).
struct NidoIndeterminateBar: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            GeometryReader { proxy in
                let width = proxy.size.width
                let segment = width * Theme.Layout.indeterminateSegment
                let period = Theme.Layout.indeterminatePeriod
                let phase = reduceMotion ? 0
                    : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.Color.border)
                    Capsule().fill(Theme.Color.accent)
                        .frame(width: segment)
                        .offset(x: reduceMotion ? 0 : (width + segment) * phase - segment)
                }
                .clipShape(Capsule())
            }
        }
        .frame(height: Theme.Layout.progressBarHeight)
        .accessibilityElement()
        .accessibilityLabel(Text("In progress"))
        .accessibilityAddTraits(.updatesFrequently)
    }
}

/// Components.swift ProgressPanel: download · verifica · creazione · errore. The wizard has the
/// buttons, so the panel shows none. `fraction` nil with no error: an indeterminate bar.
/// Title and detail are copy (English keys); `verbatim:` shows strings as given.
struct NidoProgressPanel: View {
    private let title: Text
    private let detail: Text
    private let fraction: Double?
    private let isError: Bool
    /// False for a step of unknown length shown without a bar (S03 macOS "controllo").
    private let showsBar: Bool
    /// The panel's own buttons (S09 errore: Close, Try Again); the wizard shows none.
    private let onClose: (() -> Void)?
    private let onRetry: (() -> Void)?

    init(title: LocalizedStringKey, detail: LocalizedStringKey, fraction: Double? = nil, isError: Bool = false,
         showsBar: Bool = true, onClose: (() -> Void)? = nil, onRetry: (() -> Void)? = nil) {
        self.init(title: Text(title), detail: Text(detail), fraction: fraction, isError: isError,
                  showsBar: showsBar, onClose: onClose, onRetry: onRetry)
    }

    init(verbatim title: String, detail: String, fraction: Double? = nil, isError: Bool = false,
         showsBar: Bool = true, onClose: (() -> Void)? = nil, onRetry: (() -> Void)? = nil) {
        self.init(title: Text(verbatim: title), detail: Text(verbatim: detail), fraction: fraction,
                  isError: isError, showsBar: showsBar, onClose: onClose, onRetry: onRetry)
    }

    private init(title: Text, detail: Text, fraction: Double?, isError: Bool, showsBar: Bool,
                 onClose: (() -> Void)?, onRetry: (() -> Void)?) {
        self.title = title
        self.detail = detail
        self.fraction = fraction
        self.isError = isError
        self.showsBar = showsBar
        self.onClose = onClose
        self.onRetry = onRetry
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            title
                .font(.nido(Theme.TypeSize.headline, .semibold))
                .foregroundStyle(Theme.Color.textPrimary)
            detail
                .font(.nido(Theme.TypeSize.caption, isError ? .semibold : .regular))
                .foregroundStyle(isError ? Theme.Color.statusError : Theme.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("progress-detail")
            if !isError, showsBar {
                if let fraction {
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Theme.Color.border)
                            Capsule().fill(Theme.Color.accent).frame(width: proxy.size.width * fraction)
                        }
                    }
                    .frame(height: Theme.Layout.progressBarHeight)
                } else {
                    // The design's 6 pt bar, not the taller system one: the panel keeps the
                    // render's height in every phase (S03 verifica, S06 creazione).
                    NidoIndeterminateBar()
                }
            }
            if onClose != nil || onRetry != nil {
                HStack(spacing: Theme.Space.s) {
                    Spacer(minLength: 0)
                    if let onClose {
                        NidoButton("Close", action: onClose)
                            .accessibilityIdentifier("progress-close")
                    }
                    if let onRetry {
                        NidoButton("Try Again", kind: .primary, action: onRetry)
                            .accessibilityIdentifier("progress-retry")
                    }
                }
            }
        }
        .padding(Theme.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Color.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.m))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.m)
                .strokeBorder(Theme.Color.border, lineWidth: Theme.Layout.hairline)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("progress-panel")
    }
}
