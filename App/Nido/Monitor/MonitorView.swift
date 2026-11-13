// SPDX-License-Identifier: Apache-2.0
import AppKit
import NidoCore
import SwiftUI

/// S13: the Monitor view of a VM window. Polling runs only while this view is on screen
/// (`MonitorModel.setVisible`); the values come from the guest's own verdicts.
struct MonitorView: View {
    let monitor: MonitorModel
    let name: String
    /// The Guest Tools' version from the VM's config ("1.0.0"), for the Sistema panel.
    let guestToolsVersion: String?
    /// The VM runs in another process (`nido start`): the monitor is not available here; nil
    /// while not known yet.
    let runsElsewhere: Bool?
    let guestTools: GuestToolsModel?
    let onOpenTerminal: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        Group {
            if runsElsewhere == nil, monitor.state == .vmStopped {
                // The lock is being read: say nothing yet.
                Color.clear
            } else if runsElsewhere == true, monitor.state == .vmStopped {
                message(title: String(localized: "Monitor not available"),
                        body: String(localized: "The monitor is available for VMs started by Nido. This VM is running from Terminal (nido start)."),
                        egg: Theme.Color.statusRunning, identifier: "monitor-elsewhere")
            } else {
                switch monitor.state {
                case .vmStopped:
                    message(title: MonitorModel.State.vmStopped.title ?? "",
                            body: String(localized: "Start \(name) to see CPU, memory and disk. The monitor reads the data from the guest over vsock, without going through the network."),
                            egg: Theme.Color.statusStopped, identifier: "monitor-stopped")
                case .waitingForGuest:
                    message(title: MonitorModel.State.waitingForGuest.title ?? "",
                            body: String(localized: "\(name) is still starting. On the first boot cloud-init installs packages and Guest Tools: this can take a few minutes."),
                            egg: Theme.Color.accent, identifier: "monitor-waiting", waiting: true)
                case .guestToolsMissing:
                    message(title: MonitorModel.State.guestToolsMissing.title ?? "",
                            body: String(localized: "\(name) has no guest monitor: it was created without Guest Tools or with an earlier version of Nido. Nido installs them over SSH without touching packages, files and models; the monitor starts responding after the next restart."),
                            egg: Theme.Color.statusPaused, identifier: "monitor-missing",
                            action: guestTools.map { tools in
                                (tools.isBusy ? String(localized: "Installing…") : String(localized: "Install Guest Tools"),
                                 { Task { await tools.install() } })
                            })
                case .unsupported(let version):
                    message(title: MonitorModel.State.unsupported(version).title ?? "",
                            body: version.isEmpty
                                ? String(localized: "The Guest Tools of \(name) report an unknown version. Update Nido, or reinstall the Guest Tools that come with your version of Nido.")
                                : String(localized: "The Guest Tools of \(name) report version \(version), which this version of Nido doesn’t recognize. Update Nido, or reinstall the Guest Tools that come with your version of Nido."),
                            egg: Theme.Color.statusPaused, identifier: "monitor-unsupported",
                            action: guestTools.map { tools in
                                (tools.isBusy ? String(localized: "Installing…") : String(localized: "Reinstall Guest Tools"),
                                 { Task { await tools.install() } })
                            })
                case .error(let text):
                    message(title: MonitorModel.State.error(text).title ?? "",
                            body: String(localized: "\(WizardModel.sentence(MonitorText(text))) Nido retries automatically every 3 seconds: the VM keeps working normally."),
                            egg: Theme.Color.statusError, identifier: "monitor-error",
                            action: (Self.retryNow, { Task { await monitor.refresh() } }))
                case .live(let status, _), .stale(let status, _), .lastKnown(let status, _):
                    // Redrawn every second: "nessuna risposta da N secondi".
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        values(status, now: context.date)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Color.background)
        .onAppear { monitor.setVisible(true) }
        .onDisappear { monitor.setVisible(false) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("monitor-view")
    }

    /// A text that `WizardModel.sentence` can capitalise and end with a full stop.
    private struct MonitorText: LocalizedError {
        let text: String
        init(_ text: String) { self.text = text }
        var errorDescription: String? { text }
    }

    // MARK: - States without values

    /// The error state's own action: it stays enabled while the Guest Tools are busy.
    private static var retryNow: String { String(localized: "Try Again Now") }

    private func message(
        title: String, body: String, egg: Color, identifier: String, waiting: Bool = false,
        action: (String, () -> Void)? = nil
    ) -> some View {
        ScrollView {
            VStack(spacing: Theme.Space.l) {
                NidoEmptyState(verbatim: title, message: body, eggColor: egg, identifier: identifier,
                               buttonLabel: action?.0 ?? "", buttonIdentifier: "\(identifier)-action",
                               onCreate: action?.1)
                    .disabled(guestTools?.isBusy == true && action?.0 != Self.retryNow)
                if waiting {
                    VStack(spacing: Theme.Space.s) {
                        NidoIndeterminateBar().frame(width: Theme.Layout.emptyStateWidth / 2)
                        Text("Nido asks the guest every 3 seconds")
                            .font(.nido(Theme.TypeSize.caption))
                            .foregroundStyle(Theme.Color.textSecondary)
                    }
                }
                if action != nil, action?.0 != Self.retryNow, let guestTools { GuestToolsFeedback(tools: guestTools,
                    onOpenTerminal: onOpenTerminal, onOpenSettings: onOpenSettings)
                    .frame(width: Theme.Layout.emptyStateWidth) }
            }
            .padding(Theme.Space.xl)
            .frame(maxWidth: .infinity)
        }
        .defaultScrollAnchor(.center)
    }

    // MARK: - Values

    private func values(_ status: GuestStatus, now: Date) -> some View {
        let state = monitor.state
        let old: Bool = switch state {
        case .stale, .lastKnown: true
        default: false
        }
        return ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                if case .lastKnown(let sample, let stoppedAt) = state {
                    NidoNotice(kind: .info, title: "Last sample before the VM stopped",
                               detail: "\(name) stopped on its own at \(Self.clock(stoppedAt)). These are the values from \(Self.clock(sample.timestamp ?? stoppedAt)); the monitor resumes at the next start.",
                               identifier: "monitor-last-known")
                }
                HStack(spacing: Theme.Space.m) {
                    Text(verbatim: caption(now: now))
                        .font(.nido(Theme.TypeSize.caption))
                        .foregroundStyle(Theme.Color.textSecondary)
                        .monospacedDigit()
                        .accessibilityIdentifier("monitor-caption")
                    Spacer(minLength: 0)
                    if !isLastKnown {
                        NidoButton("Refresh") { Task { await monitor.refresh() } }
                            .accessibilityIdentifier("monitor-refresh")
                    }
                }
                HStack(alignment: .top, spacing: Theme.Space.l) {
                    VStack(spacing: 0) {
                        cpuRow(status, old: old)
                        divider
                        memoryRow(status, old: old)
                        divider
                        swapRow(status, old: old)
                        divider
                        diskRow(status, old: old)
                    }
                    .background(Theme.Color.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.m))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.m)
                        .strokeBorder(Theme.Color.border, lineWidth: Theme.Layout.hairline))
                    .frame(maxWidth: .infinity)
                    VStack(spacing: Theme.Space.l) {
                        warningsPanel
                        systemPanel(status)
                    }
                    .frame(width: Theme.Layout.monitorSideColumn)
                }
            }
            .padding(Theme.Space.xl)
        }
    }

    private var isLastKnown: Bool {
        if case .lastKnown = monitor.state { true } else { false }
    }

    private func caption(now: Date) -> String {
        switch monitor.state {
        case .live(_, let updated):
            String(localized: "Updated at \(Self.clock(updated)) · every 3 seconds, only while this view is open")
        case .stale(_, let since):
            String(localized: "Last sample at \(Self.clock(since)) · no response for \(max(0, Int(now.timeIntervalSince(since)))) seconds")
        case .lastKnown(let sample, let stoppedAt):
            String(localized: "Sample from \(Self.clock(sample.timestamp ?? stoppedAt)) · the VM is stopped")
        default:
            ""
        }
    }

    private var divider: some View {
        Rectangle().fill(Theme.Color.border).frame(height: Theme.Layout.hairline)
    }

    private func cpuRow(_ status: GuestStatus, old: Bool) -> some View {
        let cpu = status.cpu
        let warning = cpu?.status == .warning ? MonitorModel.Warning.cpuHigh.text : nil
        return measure(
            "CPU", id: "CPU", sub: cpu?.vcpus.map { String(localized: "\($0) vCPUs") } ?? String(localized: "vCPUs unknown"),
            fraction: cpu?.usagePercent.map { $0 / 100 },
            detail: cpu?.load1Min.map { String(localized: "1-minute load average \(Self.decimal($0, digits: 2))") }
                ?? String(localized: "load not available"),
            value: Self.percent(cpu?.usagePercent), warning: warning, old: old)
    }

    private func memoryRow(_ status: GuestStatus, old: Bool) -> some View {
        let memory = status.memory
        let warning = memory?.status == .warning ? MonitorModel.Warning.memoryLow.text : nil
        var parts: [String] = []
        if let used = memory?.usedGiB { parts.append(String(localized: "\(Self.gib(used)) used")) }
        if let available = memory?.availableGiB { parts.append(String(localized: "\(Self.gib(available)) available")) }
        return measure(
            String(localized: "Memory"), id: "Memoria", sub: memory?.totalGiB.map(Self.gib) ?? String(localized: "total unknown"),
            fraction: memory?.usagePercent.map { $0 / 100 },
            detail: parts.isEmpty ? String(localized: "values not available") : parts.joined(separator: " · "),
            value: Self.percent(memory?.usagePercent), warning: warning, old: old)
    }

    private func swapRow(_ status: GuestStatus, old: Bool) -> some View {
        let memory = status.memory
        guard let total = memory?.swapTotalGiB, total > 0 else {
            return measure("Swap", id: "Swap", sub: String(localized: "Not set up"), fraction: nil,
                           detail: String(localized: "The VM has no swap area"), value: "–", warning: nil, old: old)
        }
        return measure(
            "Swap", id: "Swap", sub: Self.gib(total), fraction: memory?.swapUsagePercent.map { $0 / 100 },
            detail: memory?.swapUsedGiB.map { String(localized: "\(Self.gib($0)) used") } ?? String(localized: "usage not available"),
            value: Self.percent(memory?.swapUsagePercent), warning: nil, old: old)
    }

    private func diskRow(_ status: GuestStatus, old: Bool) -> some View {
        let disk = status.disk
        let warning = disk?.status == .warning ? MonitorModel.Warning.diskFull.text : nil
        var parts: [String] = []
        if let used = disk?.usedGiB { parts.append(String(localized: "\(Self.gib(used)) used")) }
        if let available = disk?.availableGiB { parts.append(String(localized: "\(Self.gib(available)) free")) }
        return measure(
            String(localized: "Disk"), id: "Disco", sub: disk?.totalGiB.map { "\(Self.gib($0)) · /" } ?? "/",
            fraction: disk?.usagePercent.map { $0 / 100 },
            detail: parts.isEmpty ? String(localized: "values not available") : parts.joined(separator: " · "),
            value: Self.percent(disk?.usagePercent), warning: warning, old: old)
    }

    private func measure(
        _ label: String, id: String, sub: String, fraction: Double?, detail: String, value: String, warning: String?,
        old: Bool
    ) -> some View {
        HStack(spacing: Theme.Space.l) {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text(verbatim: label)
                    .font(.nido(Theme.TypeSize.body, .semibold))
                    .foregroundStyle(Theme.Color.textPrimary)
                Text(verbatim: sub)
                    .font(.nido(Theme.TypeSize.caption))
                    .foregroundStyle(Theme.Color.textSecondary)
            }
            .frame(width: Theme.Layout.monitorNameColumn, alignment: .leading)
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                if let fraction {
                    NidoMeter(fraction: fraction,
                              tint: old ? Theme.Color.statusStopped
                                  : warning == nil ? Theme.Color.accent : Theme.Color.statusPaused)
                }
                HStack(spacing: Theme.Space.s) {
                    if let warning {
                        Circle().fill(Theme.Color.statusPaused)
                            .frame(width: Theme.Layout.warningDot, height: Theme.Layout.warningDot)
                        Text(verbatim: warning)
                            .font(.nido(Theme.TypeSize.caption, .semibold))
                            .foregroundStyle(Theme.Color.textPrimary)
                    }
                    Text(verbatim: detail)
                        .font(.nido(Theme.TypeSize.caption))
                        .foregroundStyle(Theme.Color.textSecondary)
                        .monospacedDigit()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(verbatim: value)
                .font(.nido(Theme.TypeSize.title, .semibold))
                .foregroundStyle(old ? Theme.Color.textSecondary : Theme.Color.textPrimary)
                .monospacedDigit()
                .frame(width: Theme.Layout.monitorValueColumn, alignment: .trailing)
        }
        .padding(.vertical, Theme.Space.m)
        .padding(.horizontal, Theme.Space.l)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("monitor-\(id)")
    }

    private var warningsPanel: some View {
        NidoPanel(title: "Warnings") {
            let warnings = monitor.warnings
            if warnings.isEmpty {
                Text(isLastKnown ? "No warnings in the last sample."
                     : "No warnings: CPU, memory and disk are within the Guest Tools’ thresholds.")
                    .font(.nido(Theme.TypeSize.caption))
                    .foregroundStyle(Theme.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(warnings, id: \.self) { warning in
                HStack(alignment: .top, spacing: Theme.Space.s) {
                    Circle().fill(Theme.Color.statusPaused)
                        .frame(width: Theme.Layout.warningDot, height: Theme.Layout.warningDot)
                        .frame(height: Theme.Layout.noticeDotLineHeight)
                    Text(verbatim: warning.text)
                        .font(.nido(Theme.TypeSize.body))
                        .foregroundStyle(Theme.Color.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("monitor-warnings")
    }

    private func systemPanel(_ status: GuestStatus) -> some View {
        NidoPanel(title: "System", spacing: 0) {
            keyValue("Host name", status.system?.hostname ?? status.hostname ?? "–")
            keyValue("Architecture", status.system?.architecture ?? "–")
            keyValue("Kernel", status.system?.kernel ?? "–")
            keyValue("Uptime", status.system?.uptimeSeconds.map(Self.uptime) ?? "–")
            keyValue("Guest Tools", [guestToolsVersion, status.version.map { String(localized: "protocol \($0)") }]
                .compactMap(\.self).joined(separator: " · "), last: true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("monitor-system")
    }

    private func keyValue(_ key: LocalizedStringKey, _ value: String, last: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.m) {
            Text(key)
                .font(.nido(Theme.TypeSize.caption))
                .foregroundStyle(Theme.Color.textSecondary)
                .frame(width: Theme.Layout.keyColumnWidth, alignment: .leading)
            Text(verbatim: value.isEmpty ? "–" : value)
                .font(.nido(Theme.TypeSize.body))
                .foregroundStyle(Theme.Color.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, Theme.Space.xs)
        .overlay(alignment: .bottom) {
            if !last { Rectangle().fill(Theme.Color.border).frame(height: Theme.Layout.hairline) }
        }
    }

    // MARK: - Formatting (the app's language)

    /// "23 %" (a space before the % in Italian), or "–" when unknown. The guest sends the value, so it is clamped to 0…100
    /// before it becomes an Int: an out-of-range Double would trap the app and every VM in it.
    nonisolated static func percent(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "–" }
        let percent = Int(min(max(value, 0), 100).rounded())
        return String(localized: "\(percent)%", comment: "A meter's value in percent. [not a count]")
    }

    /// "3,9 GiB" (Italian), "3.9 GiB" (English).
    nonisolated static func gib(_ value: Double) -> String {
        "\(decimal(value, digits: 1)) GiB"
    }

    /// A number with the decimal separator of the app's language.
    nonisolated static func decimal(_ value: Double, digits: Int) -> String {
        value.formatted(.number.precision(.fractionLength(digits)).locale(.current).grouping(.never))
    }

    /// "2 h 14 min", "3 min", "1 g 4 h" (Italian): abbreviated units, the same for any number.
    nonisolated static func uptime(_ seconds: Int) -> String {
        let minutes = max(0, seconds) / 60
        let (days, hours, mins) = (minutes / 1440, (minutes % 1440) / 60, minutes % 60)
        if days > 0 {
            return String(localized: "\(days) d \(hours) h", comment: "Uptime: days and hours, abbreviated. [not a count]")
        }
        if hours > 0 {
            return String(localized: "\(hours) h \(mins) min", comment: "Uptime: hours and minutes, abbreviated. [not a count]")
        }
        return String(localized: "\(mins) min", comment: "Uptime: minutes, abbreviated. [not a count]")
    }

    /// "10:42:18".
    nonisolated static func clock(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .omitted, time: .standard).locale(.current))
    }
}

/// What "Installa Guest Tools" did, under the action: the result, or the error with the way out
/// (the Terminal for the key, the manual installer, the settings to choose the key).
struct GuestToolsFeedback: View {
    let tools: GuestToolsModel
    let onOpenTerminal: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            if let message = tools.message {
                NidoNotice(kind: .info, verbatim: message, identifier: "guest-tools-message")
            }
            if let failure = tools.failure {
                NidoNotice(
                    kind: .error, verbatim: failure.title, detail: failure.detail,
                    actionLabel: failure.offersTerminal ? String(localized: "Open Terminal")
                        : tools.needsKey ? String(localized: "Settings…") : failure.offersManual ? String(localized: "Copy Commands") : nil,
                    action: failure.offersTerminal ? onOpenTerminal
                        : tools.needsKey ? onOpenSettings
                        : failure.offersManual ? { copyManual() } : nil,
                    identifier: "guest-tools-failure")
            }
        }
    }

    private func copyManual() {
        guard let command = tools.manualCommand else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
    }
}
