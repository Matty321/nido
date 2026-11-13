// SPDX-License-Identifier: Apache-2.0
import Foundation
import NidoCore
import Observation

/// The rate of a progress value (bytes, a fraction) as a moving average over `window`, for the
/// time left: the wizard's download and the macOS installation share it.
struct ProgressRate: Sendable {
    struct Sample: Sendable {
        let time: ContinuousClock.Instant
        let value: Double
    }

    let window: Duration
    /// The samples of the last `window` (and the newest one before it), oldest first.
    private(set) var samples: [Sample]

    init(window: Duration, samples: [Sample] = []) {
        self.window = window
        self.samples = samples
    }

    /// Keeps the samples of the last `window`, plus the newest one before it so the window is
    /// covered whole when updates are sparse.
    mutating func record(_ value: Double, at time: ContinuousClock.Instant) {
        samples.append(Sample(time: time, value: value))
        let start = time - window
        while samples.count > 2, samples[1].time <= start {
            samples.removeFirst()
        }
    }

    mutating func reset() {
        samples = []
    }

    /// Time to cover `left` at the average rate of the window; nil when the rate is not known
    /// (fewer than two samples, no progress in the window) or nothing arrived for a whole window
    /// (a stall).
    func remaining(left: Double, now: ContinuousClock.Instant) -> Duration? {
        guard let first = samples.first, let last = samples.last, last.time >= now - window else { return nil }
        let elapsed = (last.time - first.time) / .seconds(1)
        guard elapsed > 0, last.value > first.value else { return nil }
        let rate = (last.value - first.value) / elapsed
        return .seconds(max(0, left) / rate)
    }
}

/// One macOS installation started by the wizard. It lives in `MacInstallStore`, not in the wizard:
/// it goes on when the wizard is closed ("Continua nella libreria"), its card shows the progress,
/// and "Mostra" brings the same wizard back.
@MainActor
@Observable
final class MacInstallation: Identifiable {
    enum State: Equatable, Sendable {
        case installing, finished, cancelled
        case failed(String)
    }

    /// How the installation ended, for the wizard and the library.
    enum Outcome {
        case finished
        case cancelled
        case failed(any Error)
    }

    /// The installer's updates are sparse (about one per percent): a longer window than the
    /// download's, so the estimate does not come and go between two updates.
    nonisolated static let rateWindow: Duration = .seconds(60)

    nonisolated let id = UUID()
    let name: VMName
    /// "26.6".
    let version: String
    let cpuCount: Int
    let memoryBytes: UInt64
    let diskBytes: UInt64
    /// 0…1, never going back.
    private(set) var fraction: Double = 0
    private(set) var state: State = .installing
    /// "Cancel Installation" was chosen: the installer is cleaning up (the card and the wizard
    /// say so, and nothing asks to cancel again).
    private(set) var isCancelling = false
    /// The wizard that started it ("Mostra" shows it again); dropped when the installation ends.
    @ObservationIgnored var wizard: WizardModel?
    /// The clock of the time left; injected by the tests.
    @ObservationIgnored var now: @MainActor () -> ContinuousClock.Instant = { .now }
    @ObservationIgnored private var rate = ProgressRate(window: MacInstallation.rateWindow)
    @ObservationIgnored fileprivate var task: Task<Void, Never>?

    init(name: VMName, version: String, cpuCount: Int, memoryBytes: UInt64, diskBytes: UInt64) {
        self.name = name
        self.version = version
        self.cpuCount = cpuCount
        self.memoryBytes = memoryBytes
        self.diskBytes = diskBytes
    }

    var isInstalling: Bool { state == .installing }
    /// "Annulla…" is offered: installing and not already cancelling.
    var canBeCancelled: Bool { isInstalling && !isCancelling }
    /// Its card is shown: while it installs, and once finished until the library lists the VM.
    var hasCard: Bool { state == .installing || state == .finished }

    /// A progress update of the installer: a smaller value than the one shown is ignored.
    func receive(_ value: Double, at time: ContinuousClock.Instant = .now) {
        guard state == .installing else { return }
        let value = min(1, max(0, value))
        guard value >= fraction else { return }
        fraction = value
        rate.record(value, at: time)
    }

    /// The time left at the average rate of the last `rateWindow`; nil when it is not known.
    var remainingTime: Duration? {
        rate.remaining(left: 1 - fraction, now: now())
    }

    /// "42%" ("42 %" in Italian).
    var percentText: String { Self.percentText(fraction) }

    /// `fraction` (0…1) in whole percent, rounded down.
    nonisolated static func percentText(_ fraction: Double) -> String {
        let percent = Int((fraction * 100).rounded(.down))
        return String(localized: "\(percent)%", comment: "A meter's value in percent. [not a count]")
    }

    /// The wizard's detail: "42% · about 9 min left".
    var detailText: String {
        if isCancelling { return String(localized: "Canceling…") }
        let left = remainingTime.map {
            String(localized: "\(WizardModel.remainingText($0)) left", comment: "%@ is the time left: about 9 min.")
        }
        return ([percentText] + (left.map { [$0] } ?? [])).joined(separator: " · ")
    }

    /// The library card: "Installing macOS 26.6 · 42% · about 9 min".
    var cardText: String {
        if isCancelling {
            return String(localized: "Canceling the macOS \(version) installation…", comment: "%@ is the macOS version.")
        }
        let installing = String(localized: "Installing macOS \(version)", comment: "%@ is the macOS version (26.6).")
        return ([installing, percentText] + (remainingTime.map { [WizardModel.remainingText($0)] } ?? []))
            .joined(separator: " · ")
    }

    /// Stops the installation and returns once the installer has removed what it created, however
    /// long that takes (the caller's task waits; the main actor is never held).
    func cancel() async {
        requestCancel()
        await task?.value
    }

    /// Asks the installer to stop; returns at once.
    func requestCancel() {
        guard isInstalling else { return }
        isCancelling = true
        task?.cancel()
    }

    /// Waits at most `limit` for the installation to end: true if it ended in time.
    func waitForEnd(atMost limit: Duration) async -> Bool {
        guard let task else { return true }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let gate = ResumeOnce(continuation)
            let timer = Task { @MainActor in
                try? await Task.sleep(for: limit)
                gate.resume(false)
            }
            Task { @MainActor in
                await task.value
                gate.resume(true)
                timer.cancel()
            }
        }
    }

    /// The wizard's text for a failed installation: the reason, and what is left.
    nonisolated static func failureText(_ error: any Error) -> String {
        let reason = WizardModel.sentence(error)
        return String(localized: "\(reason) Nido deleted the files it created; the IPSW stays where it is.",
                      comment: "%@ is why the installation failed, a sentence.")
    }

    fileprivate func end(_ outcome: Outcome) {
        switch outcome {
        case .finished:
            fraction = 1
            state = .finished
        case .cancelled: state = .cancelled
        case .failed(let error): state = .failed(Self.failureText(error))
        }
    }
}

/// The macOS installations of this app (one per `AppEnvironment`): the library shows them, quitting
/// asks first and cancels them.
@MainActor
@Observable
final class MacInstallStore {
    /// The installations with a card: running, or finished and not yet listed by the library.
    private(set) var installations: [MacInstallation] = []
    /// A failure nobody saw in a wizard (closed with "Continua nella libreria"). Kept here, not in a
    /// library model, so it waits for a library to show it; dismissing it there clears it.
    var lastFailure: String?

    init() {}

    var isInstalling: Bool { installations.contains(where: \.isInstalling) }

    /// Starts installing `request` (the version of the checked image is `version`).
    @discardableResult
    func start(_ request: MacVMRequest, version: String, installer: any MacVMInstalling,
               wizard: WizardModel? = nil) -> MacInstallation {
        let job = MacInstallation(
            name: request.name, version: version, cpuCount: request.cpuCount, memoryBytes: request.memoryBytes,
            diskBytes: request.diskBytes)
        job.wizard = wizard
        installations.append(job)
        job.task = Task { [weak self] in
            let outcome: MacInstallation.Outcome
            do {
                try await installer.install(request) { value in
                    Task { @MainActor in job.receive(value) }
                }
                outcome = .finished
            } catch is CancellationError {
                outcome = .cancelled
            } catch {
                outcome = .failed(error)
            }
            self?.end(job, outcome)
        }
        return job
    }

    private func end(_ job: MacInstallation, _ outcome: MacInstallation.Outcome) {
        // A finished one keeps its card until the library lists the new VM (`prune`): never a
        // moment with neither card.
        if case .finished = outcome {} else { installations.removeAll { $0 === job } }
        job.end(outcome)
        let wizard = job.wizard
        job.wizard = nil
        switch outcome {
        case .finished:
            wizard?.installationFinished(job)
        case .cancelled:
            wizard?.installationCancelled()
        case .failed(let error):
            let shown = wizard?.installationFailed(error) ?? false
            if !shown {
                let name = job.name.rawValue
                let failure = MacInstallation.failureText(error)
                lastFailure = String(localized: "Couldn’t install \(name). \(failure)",
                                     comment: "%1$@: the VM's name; %2$@: why, and what is left.")
            }
        }
    }

    /// Drops the finished installations whose VM the library now lists (`names`, any case).
    func prune(listed names: [String]) {
        let listed = Set(names.map { $0.lowercased() })
        installations.removeAll { $0.state == .finished && listed.contains($0.name.rawValue.lowercased()) }
    }

    // MARK: - Quitting

    /// The quit alert while an installation runs: "Continue Installation" (the default, keeps the
    /// app open) or "Cancel Installation and Quit".
    var quitPrompt: VMSessionStore.QuitPrompt? {
        let names = installations.filter(\.isInstalling).map(\.name.rawValue)
        guard !names.isEmpty else { return nil }
        let list = Self.nameList(names)
        return VMSessionStore.QuitPrompt(
            question: String(localized: "Cancel the installation and quit?"),
            message: String(localized: "Nido stops installing \(list) and deletes the files created so far. The IPSW stays where it is.",
                            comment: "%@ is one or more VM names."),
            buttons: [String(localized: "Continue Installation"), String(localized: "Cancel Installation and Quit")])
    }

    /// The VMs' names as a list of the UI's language: "a, b and c" ("a, b e c" in Italian).
    nonisolated static func nameList(_ names: [String], locale: Locale = .current) -> String {
        names.formatted(.list(type: .and).locale(locale))
    }

    /// The alert's button index (0 = first): true for "Cancel Installation and Quit".
    nonisolated static func cancelsAtQuit(buttonIndex: Int) -> Bool { buttonIndex == 1 }

    /// How long quitting waits for the cancelled installations. The cancel of a real
    /// `VZMacOSInstaller` goes through its `progress`; should its completion handler be late, the quit
    /// goes on anyway: the staging lock is a `flock` released at exit, and the next listing of the
    /// root (`VMRegistry`, `sweepOrphanTombstones`) removes the `.creating-*` folder once it is
    /// 2 minutes old.
    nonisolated static let quitCancelLimit: Duration = .seconds(30)

    /// "Cancel Installation and Quit": cancels every installation and returns once each has
    /// removed what it created, or after `limit` in all. Returns the installations still running
    /// then.
    @discardableResult
    func cancelAllForQuit(limit: Duration = MacInstallStore.quitCancelLimit) async -> [VMName] {
        let jobs = installations.filter(\.isInstalling)
        for job in jobs { job.requestCancel() }
        let deadline = ContinuousClock.now + limit
        var late: [VMName] = []
        for job in jobs {
            let left = max(.zero, deadline - ContinuousClock.now)
            if await !job.waitForEnd(atMost: left) { late.append(job.name) }
        }
        return late
    }

    #if DEBUG
        /// DEBUG `-NidoWizardFixture`: an installation at 42 % with "circa 9 min" left, frozen (no
        /// installer behind it).
        func addFixture(name: VMName, version: String, wizard: WizardModel?) -> MacInstallation {
            let job = MacInstallation(name: name, version: version, cpuCount: 4, memoryBytes: 8 << 30,
                                      diskBytes: 64 << 30)
            job.wizard = wizard
            let instant = ContinuousClock.now
            job.now = { instant }
            // 0,58 left at 0,064 per minute: about 9 minutes.
            job.receive(0.356, at: instant - .seconds(60))
            job.receive(0.42, at: instant)
            installations.append(job)
            return job
        }
    #endif
}

/// Resumes a continuation once: the first of several racing callers wins.
@MainActor
private final class ResumeOnce<Value: Sendable> {
    private var continuation: CheckedContinuation<Value, Never>?

    init(_ continuation: CheckedContinuation<Value, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: Value) {
        continuation?.resume(returning: value)
        continuation = nil
    }
}
