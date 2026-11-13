// SPDX-License-Identifier: Apache-2.0
import Foundation
import NidoCore
import Observation

/// Where the monitor's samples come from: `GuestMonitorClient` over the session's vsock in the
/// app, fakes in the tests. A status of an unknown protocol version is returned too (check
/// `isSupportedVersion`); `CancellationError` when the calling task is cancelled.
protocol GuestStatusSource: Sendable {
    func fetchStatus() async throws -> GuestStatus
}

extension GuestMonitorClient: GuestStatusSource {
    func fetchStatus() async throws -> GuestStatus {
        try await fetchAllowingUnsupportedVersion()
    }
}

/// The guest monitor of one VM window (spec B), owned by its `VMWindowModel`: polls the guest's
/// `/api/status` every 3 s, only while the VM runs **and** the panel is visible, one request at a
/// time (the client gives up after 2 s), I/O off the main actor (the client's). The last values
/// are kept and marked stale after 10 s without a good sample.
///
/// Warnings come from the guest's own verdicts (`status` of CPU, memory and disk, thresholds of
/// the Guest Tools): the app never computes a threshold of its own.
@MainActor
@Observable
final class MonitorModel {
    nonisolated static let defaultInterval: Duration = .seconds(3)
    nonisolated static let defaultStaleAfter: TimeInterval = 10
    /// How long a running VM whose config says it has Guest Tools may stay silent on its first
    /// boot before the panel says they are missing (cloud-init installs packages first).
    nonisolated static let defaultGuestStartGrace: TimeInterval = 300
    /// The same on any later boot: the Guest Tools start with the system.
    nonisolated static let defaultBootGrace: TimeInterval = 60

    enum State: Equatable {
        /// "La VM non è in esecuzione".
        case vmStopped
        /// Starting, or running with Guest Tools that have not answered yet.
        case waitingForGuest
        case live(GuestStatus, updated: Date)
        /// The last good sample, older than 10 s.
        case stale(GuestStatus, since: Date)
        /// Nothing listens on the guest's monitor port ("Installa Guest Tools").
        case guestToolsMissing
        /// The VM stopped without being asked: polling ended, this was the last sample.
        case lastKnown(GuestStatus, stoppedAt: Date)
        /// A protocol version this app does not know (the payload); `status` keeps what it sent.
        case unsupported(String)
        /// No good sample yet and the monitor fails (timeout, invalid answer), localized.
        case error(String)

        /// The panel's heading for the states without values.
        var title: String? {
            switch self {
            case .vmStopped: String(localized: "The VM isn’t running")
            case .waitingForGuest: String(localized: "Waiting for the guest monitor")
            case .guestToolsMissing: String(localized: "Guest Tools not installed")
            case .unsupported: String(localized: "Guest Tools version not recognized")
            case .error: String(localized: "Monitor can’t be reached")
            case .lastKnown: String(localized: "Last sample before the VM stopped")
            case .stale: String(localized: "Stale data")
            case .live: nil
            }
        }
    }

    enum Warning: Equatable, Hashable {
        case cpuHigh, memoryLow, diskFull
        case monitorMissing
        case staleData
        /// The last request failed (values still shown, younger than 10 s).
        case connection(String)
        case unsupportedVersion(String)

        var text: String {
            switch self {
            // The Guest Tools' own alert texts (compatibility with the original API).
            case .cpuHigh: String(localized: "High CPU")
            case .memoryLow: String(localized: "Low available RAM")
            case .diskFull: String(localized: "Disk almost full")
            case .monitorMissing: String(localized: "No guest monitor: install the Guest Tools")
            case .staleData: String(localized: "Stale data: the guest hasn’t responded for more than 10 seconds")
            case .connection(let why): String(localized: "Can’t connect to the monitor: \(why)")
            case .unsupportedVersion(let v):
                v.isEmpty ? String(localized: "Guest Tools version not recognized (unknown)")
                    : String(localized: "Guest Tools version not recognized (\(v))")
            }
        }
    }

    private(set) var state: State = .vmStopped {
        didSet { if state != oldValue { onStateChange?(state) } }
    }
    /// Called when the state changes (the window tells the provisioning the guest never answered).
    @ObservationIgnored var onStateChange: (@MainActor (State) -> Void)?
    /// The latest status received, also one of an unknown version (`.unsupported`); nil before
    /// the first and after a normal stop.
    private(set) var status: GuestStatus?
    /// Why the last request failed (localized), nil after a good one.
    private(set) var lastError: String?
    private(set) var isVisible = false
    /// Polls while the VM runs even with the panel hidden: the provisioning progress follows the
    /// guest's answers (its first one ends phase 1) and its `provisioning` field.
    var keepsPolling = false {
        didSet { if keepsPolling != oldValue { updatePolling() } }
    }
    /// True while a polling loop runs.
    private(set) var isPolling = false

    /// The VM's config says it has Guest Tools (set by the window once read off the main actor).
    /// Until known, a silent guest is "in attesa", not "assente".
    var guestToolsExpected = true

    /// Called with every good sample (the window feeds the provisioning steps to the AI model).
    @ObservationIgnored var onSample: (@MainActor (GuestStatus) -> Void)?

    @ObservationIgnored private let interval: Duration
    @ObservationIgnored private let staleAfter: TimeInterval
    @ObservationIgnored private let guestStartGrace: TimeInterval
    @ObservationIgnored private let bootGrace: TimeInterval
    /// The grace of the current boot: `guestStartGrace` on a first boot, `bootGrace` otherwise.
    @ObservationIgnored private var currentGrace: TimeInterval
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private var source: (any GuestStatusSource)?
    @ObservationIgnored private var machineRunning = false
    @ObservationIgnored private var runningSince: Date?
    @ObservationIgnored private var lastSuccess: Date?
    @ObservationIgnored private var pollTask: Task<Void, Never>? {
        didSet { if isPolling != (pollTask != nil) { isPolling = pollTask != nil } }
    }
    @ObservationIgnored private var fetching = false
    /// Bumped on every start and stop: a sample of an earlier run is dropped.
    @ObservationIgnored private var generation = 0

    init(
        interval: Duration = MonitorModel.defaultInterval, staleAfter: TimeInterval = MonitorModel.defaultStaleAfter,
        guestStartGrace: TimeInterval = MonitorModel.defaultGuestStartGrace,
        bootGrace: TimeInterval = MonitorModel.defaultBootGrace,
        now: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.interval = interval
        self.staleAfter = staleAfter
        self.guestStartGrace = guestStartGrace
        self.bootGrace = bootGrace
        currentGrace = bootGrace
        self.now = now
    }

    isolated deinit {
        pollTask?.cancel()
    }

    // MARK: - VM lifecycle (from the window)

    /// A session was created: `source` is its monitor (nil for a session without vsock).
    /// `firstBoot`: the VM was just created with Guest Tools (cloud-init installs packages before
    /// they start), so a silent guest is "in attesa" for longer.
    func vmStarting(source: (any GuestStatusSource)?, guestToolsExpected: Bool, firstBoot: Bool = false) {
        stopPolling()
        generation += 1
        self.source = source
        self.guestToolsExpected = guestToolsExpected
        currentGrace = firstBoot ? guestStartGrace : bootGrace
        machineRunning = false
        runningSince = nil
        lastSuccess = nil
        lastError = nil
        status = nil
        state = .waitingForGuest
    }

    /// The VM runs (booted or resumed): polling starts if the panel is visible.
    func vmRunning() {
        guard !machineRunning else { return }
        machineRunning = true
        if runningSince == nil { runningSince = now() }
        if source == nil {
            state = .guestToolsMissing
            return
        }
        updatePolling()
    }

    /// Paused (or saving its state, stopping): no polling; the values age.
    func vmPaused() {
        machineRunning = false
        stopPolling()
        if case .live(let status, let updated) = state { state = .stale(status, since: updated) }
    }

    /// The VM is gone. `unexpectedly` (it stopped without being asked): the last sample stays,
    /// labelled as such; otherwise the panel says the VM is not running.
    func vmStopped(unexpectedly: Bool) {
        stopPolling()
        generation += 1
        machineRunning = false
        runningSince = nil
        source = nil
        lastError = nil
        if unexpectedly, let status {
            state = .lastKnown(status, stoppedAt: now())
        } else {
            status = nil
            state = .vmStopped
        }
        lastSuccess = nil
    }

    /// The window learnt (from the config, off the main actor) that this boot still prepares the
    /// guest: a silent guest is "in attesa" for the first-boot grace.
    func useFirstBootGrace() {
        currentGrace = guestStartGrace
    }

    /// The panel appeared or went away: polling follows.
    func setVisible(_ visible: Bool) {
        isVisible = visible
        if visible { markStaleIfOld() }
        updatePolling()
    }

    // MARK: - Polling

    private func updatePolling() {
        guard isVisible || keepsPolling, machineRunning, source != nil else {
            stopPolling()
            return
        }
        guard pollTask == nil else { return }
        let interval = interval
        // The loop holds the model only during one request: a model dropped without a stop goes
        // (its isolated deinit cancels the loop), and an iteration that finds it gone ends.
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let model = self else { return }
                await model.refresh()
                do { try await Task.sleep(for: interval) } catch { return }
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// One request now (the loop's step; also "Aggiorna"). Ignored while one is in flight.
    func refresh() async {
        guard machineRunning, let source, !fetching else { return }
        fetching = true
        defer { fetching = false }
        let run = generation
        let result: Result<GuestStatus, any Error>
        do {
            result = .success(try await source.fetchStatus())
        } catch is CancellationError {
            return
        } catch {
            result = .failure(error)
        }
        guard run == generation, machineRunning else { return }
        switch result {
        case .success(let sample): received(sample)
        case .failure(let error): failed(error)
        }
    }

    private func received(_ sample: GuestStatus) {
        status = sample
        lastError = nil
        let at = now()
        lastSuccess = at
        state = sample.isSupportedVersion ? .live(sample, updated: at) : .unsupported(sample.version ?? "")
        onSample?(sample)
    }

    private func failed(_ error: any Error) {
        let monitorError = error as? MonitorError
        if case .unsupportedVersion(let version) = monitorError {
            state = .unsupported(version)
            return
        }
        let text = Self.describe(error)
        lastError = text
        if status != nil, lastSuccess != nil {
            // Values to show: kept (also an unknown version's), stale after 10 s.
            markStaleIfOld()
            return
        }
        if monitorError == .unavailable {
            let silentFor = runningSince.map { now().timeIntervalSince($0) } ?? 0
            state = guestToolsExpected && silentFor < currentGrace ? .waitingForGuest : .guestToolsMissing
            return
        }
        state = .error(text)
    }

    /// `.live` older than `staleAfter` becomes `.stale`. True when the state is now stale.
    @discardableResult
    private func markStaleIfOld() -> Bool {
        switch state {
        case .live(let status, let updated):
            guard now().timeIntervalSince(updated) >= staleAfter else { return false }
            state = .stale(status, since: updated)
            return true
        case .stale:
            return true
        case .unsupported:
            // An unknown version's partial status ages too.
            guard let status, let lastSuccess, now().timeIntervalSince(lastSuccess) >= staleAfter else { return false }
            state = .stale(status, since: lastSuccess)
            return true
        default:
            return false
        }
    }

    nonisolated static func describe(_ error: any Error) -> String {
        switch error as? MonitorError {
        case .unavailable: String(localized: "the guest monitor doesn’t respond")
        case .timeout: String(localized: "no response within 2 seconds")
        case .invalidResponse: String(localized: "invalid response")
        case .unsupportedVersion(let v): String(localized: "version \(v) not recognized")
        case nil: error.localizedDescription
        }
    }

    // MARK: - Presentation

    /// What the panel lists under "Avvisi", most important first.
    var warnings: [Warning] {
        var list: [Warning] = []
        switch state {
        case .guestToolsMissing: return [.monitorMissing]
        case .unsupported(let version): return [.unsupportedVersion(version)]
        case .stale: list.append(.staleData)
        case .live: if let lastError { list.append(.connection(lastError)) }
        default: break
        }
        guard let status = state.sample else { return list }
        var verdicts: [Warning] = []
        if status.cpu?.status == .warning { verdicts.append(.cpuHigh) }
        if status.memory?.status == .warning { verdicts.append(.memoryLow) }
        if status.disk?.status == .warning { verdicts.append(.diskFull) }
        return verdicts + list
    }
}

extension MonitorModel.State {
    /// The values the panel shows in this state, if any.
    var sample: GuestStatus? {
        switch self {
        case .live(let status, _), .stale(let status, _), .lastKnown(let status, _): status
        default: nil
        }
    }

    /// The guest answers (now or until recently): phase 1 is done.
    var guestResponded: Bool {
        switch self {
        case .live, .stale, .lastKnown, .unsupported: true
        default: false
        }
    }
}
