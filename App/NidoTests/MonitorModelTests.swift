// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation
import NidoCore
import Synchronization
import Testing

@testable import Nido

/// A guest's monitor over a socketpair: answers `GET /api/status` with the current document, or
/// refuses the connection (nothing listens: Guest Tools missing). Counts the connections.
final class ScriptedGuestChannel: GuestChannel {
    enum Mode: Sendable {
        case answer(String)
        case refuse
    }

    private let state: Mutex<(mode: Mode, connects: Int)>

    init(_ mode: Mode) {
        state = Mutex((mode, 0))
    }

    var connects: Int { state.withLock { $0.connects } }

    func set(_ mode: Mode) {
        state.withLock { $0.mode = mode }
    }

    func connect(port: UInt32) async throws -> FileHandle {
        let mode = state.withLock { s -> Mode in
            s.connects += 1
            return s.mode
        }
        switch mode {
        case .refuse:
            throw POSIXError(.ECONNREFUSED)
        case .answer(let body):
            let http = "HTTP/1.0 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
            return try Self.pair(response: Data(http.utf8))
        }
    }

    private static func pair(response: Data) throws -> FileHandle {
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

/// A status document as the Guest Tools send it.
func guestDocument(
    hostname: String, version: String = "2.0", cpu: String = "OK", memory: String = "OK", disk: String = "OK"
) -> String {
    #"{"agent":"Nido AI Monitor","version":"\#(version)","hostname":"\#(hostname)","system":{"hostname":"\#(hostname)"},"cpu":{"vcpus":2,"usage_percent":12.5,"status":"\#(cpu)"},"memory":{"total_gib":4,"usage_percent":30,"status":"\#(memory)"},"disk":{"total_gib":20,"usage_percent":40,"status":"\#(disk)"},"alerts":[],"status":"OK"}"#
}

/// A source whose every fetch takes `delay`: records how many run at the same time.
final class SlowStatusSource: GuestStatusSource {
    private let counters = Mutex<(inFlight: Int, maxInFlight: Int, calls: Int)>((0, 0, 0))
    private let delay: Duration

    init(delay: Duration) {
        self.delay = delay
    }

    var maxInFlight: Int { counters.withLock { $0.maxInFlight } }
    var calls: Int { counters.withLock { $0.calls } }

    func fetchStatus() async throws -> GuestStatus {
        counters.withLock {
            $0.inFlight += 1
            $0.calls += 1
            $0.maxInFlight = max($0.maxInFlight, $0.inFlight)
        }
        defer { counters.withLock { $0.inFlight -= 1 } }
        try await Task.sleep(for: delay)
        return try GuestStatus.decode(Data(guestDocument(hostname: "slow").utf8))
    }
}

@MainActor
final class ManualClock {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

/// Waits (real time) until `condition` holds, at most `timeout`.
@MainActor
func waitUntil(_ timeout: Duration = .seconds(3), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while !condition() {
        if ContinuousClock.now >= deadline { return false }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return true
}

@MainActor
struct MonitorModelTests {
    private func model(clock: ManualClock, interval: Duration = .seconds(3)) -> MonitorModel {
        MonitorModel(interval: interval, now: { clock.now })
    }

    private func client(_ channel: ScriptedGuestChannel) -> GuestMonitorClient {
        GuestMonitorClient(channel: channel)
    }

    @Test func stoppedVMShowsNotRunning() async {
        let clock = ManualClock()
        let monitor = model(clock: clock)
        #expect(monitor.state == .vmStopped)
        monitor.setVisible(true)
        #expect(!monitor.isPolling)
        #expect(monitor.state.title == "La VM non è in esecuzione")
        monitor.vmStopped(unexpectedly: false)
        #expect(monitor.state == .vmStopped)
        #expect(monitor.warnings.isEmpty)
    }

    @Test func startingWaitsForGuest() async {
        let clock = ManualClock()
        let channel = ScriptedGuestChannel(.refuse)
        let monitor = model(clock: clock)
        monitor.setVisible(true)
        monitor.vmStarting(source: client(channel), guestToolsExpected: true)
        #expect(monitor.state == .waitingForGuest)
        #expect(monitor.state.title == "In attesa del monitor del guest")
        // No request while the VM is only starting.
        #expect(!monitor.isPolling)
        #expect(channel.connects == 0)
        // Running, Guest Tools expected but not answering yet (first boot): still waiting.
        monitor.vmRunning()
        await monitor.refresh()
        #expect(channel.connects >= 1)
        #expect(monitor.state == .waitingForGuest)
        monitor.setVisible(false)
    }

    @Test func liveThenStaleAfter10s() async throws {
        let clock = ManualClock()
        let channel = ScriptedGuestChannel(.answer(guestDocument(hostname: "alfa")))
        let monitor = model(clock: clock)
        monitor.vmStarting(source: client(channel), guestToolsExpected: true)
        monitor.vmRunning()
        let t0 = clock.now
        await monitor.refresh()
        guard case .live(let status, let updated) = monitor.state else {
            Issue.record("expected live, got \(monitor.state)")
            return
        }
        #expect(status.hostname == "alfa")
        #expect(updated == t0)

        channel.set(.refuse)
        clock.advance(5)
        await monitor.refresh()
        // Under 10 s: the values stay, the connection error is a warning.
        if case .live(_, let at) = monitor.state { #expect(at == t0) } else { Issue.record("\(monitor.state)") }
        #expect(monitor.warnings.contains { if case .connection = $0 { true } else { false } })

        clock.advance(6)
        await monitor.refresh()
        #expect(monitor.state == .stale(status, since: t0))
        #expect(monitor.warnings.contains(.staleData))

        channel.set(.answer(guestDocument(hostname: "alfa", cpu: "WARNING")))
        await monitor.refresh()
        if case .live(_, let at) = monitor.state { #expect(at == clock.now) } else { Issue.record("\(monitor.state)") }
        // The guest's own verdict, not a threshold of the app.
        #expect(monitor.warnings == [.cpuHigh])
        #expect(MonitorModel.Warning.cpuHigh.text == "CPU elevata")
    }

    @Test func unavailableMeansGuestToolsMissing() async {
        let clock = ManualClock()
        let channel = ScriptedGuestChannel(.refuse)
        // A VM without Guest Tools in its config: missing at the first refusal.
        let monitor = model(clock: clock)
        monitor.vmStarting(source: client(channel), guestToolsExpected: false)
        monitor.vmRunning()
        await monitor.refresh()
        #expect(monitor.state == .guestToolsMissing)
        #expect(monitor.warnings == [.monitorMissing])

        // With Guest Tools expected: missing once the boot grace is over.
        let expecting = model(clock: clock)
        expecting.vmStarting(source: client(channel), guestToolsExpected: true)
        expecting.vmRunning()
        await expecting.refresh()
        #expect(expecting.state == .waitingForGuest)
        clock.advance(MonitorModel.defaultGuestStartGrace + 1)
        await expecting.refresh()
        #expect(expecting.state == .guestToolsMissing)

        // A session without a vsock device (pre-M3c VM): missing at once.
        let noDevice = model(clock: clock)
        noDevice.vmStarting(source: nil, guestToolsExpected: true)
        noDevice.vmRunning()
        #expect(noDevice.state == .guestToolsMissing)
    }

    @Test func unsupportedVersionKeepsPartialStatus() async {
        let clock = ManualClock()
        let channel = ScriptedGuestChannel(.answer(guestDocument(hostname: "futura", version: "3.1")))
        let monitor = model(clock: clock)
        monitor.vmStarting(source: client(channel), guestToolsExpected: true)
        monitor.vmRunning()
        await monitor.refresh()
        #expect(monitor.state == .unsupported("3.1"))
        #expect(monitor.status?.hostname == "futura")
        #expect(monitor.warnings == [.unsupportedVersion("3.1")])
    }

    @Test func unexpectedStopKeepsLastKnown() async {
        let clock = ManualClock()
        let channel = ScriptedGuestChannel(.answer(guestDocument(hostname: "alfa")))
        let monitor = model(clock: clock)
        monitor.setVisible(true)
        monitor.vmStarting(source: client(channel), guestToolsExpected: true)
        monitor.vmRunning()
        await monitor.refresh()
        let status = monitor.status
        clock.advance(2)
        monitor.vmStopped(unexpectedly: true)
        #expect(!monitor.isPolling)
        guard let status else {
            Issue.record("no status")
            return
        }
        #expect(monitor.state == .lastKnown(status, stoppedAt: clock.now))

        // A stop the user asked for: just "not running".
        monitor.vmStarting(source: client(channel), guestToolsExpected: true)
        monitor.vmRunning()
        await monitor.refresh()
        monitor.vmStopped(unexpectedly: false)
        #expect(monitor.state == .vmStopped)
    }

    @Test func pollingStopsWhenHidden() async {
        let clock = ManualClock()
        let channel = ScriptedGuestChannel(.answer(guestDocument(hostname: "alfa")))
        let monitor = model(clock: clock, interval: .milliseconds(20))
        monitor.vmStarting(source: client(channel), guestToolsExpected: true)
        monitor.vmRunning()
        // Running but hidden: nothing is asked.
        try? await Task.sleep(for: .milliseconds(100))
        #expect(channel.connects == 0)
        #expect(!monitor.isPolling)

        monitor.setVisible(true)
        #expect(monitor.isPolling)
        #expect(await waitUntil { channel.connects >= 3 })

        monitor.setVisible(false)
        #expect(!monitor.isPolling)
        try? await Task.sleep(for: .milliseconds(50))
        let after = channel.connects
        try? await Task.sleep(for: .milliseconds(200))
        #expect(channel.connects == after)

        monitor.setVisible(true)
        #expect(await waitUntil { channel.connects > after })
        monitor.vmStopped(unexpectedly: false)
        #expect(!monitor.isPolling)
    }

    @Test func noOverlappingRequests() async {
        let clock = ManualClock()
        let source = SlowStatusSource(delay: .milliseconds(80))
        let monitor = model(clock: clock, interval: .milliseconds(5))
        monitor.vmStarting(source: source, guestToolsExpected: true)
        monitor.vmRunning()
        monitor.setVisible(true)
        // Manual refreshes on top of the polling loop.
        async let a: Void = monitor.refresh()
        async let b: Void = monitor.refresh()
        async let c: Void = monitor.refresh()
        _ = await (a, b, c)
        #expect(await waitUntil { source.calls >= 4 })
        monitor.setVisible(false)
        #expect(source.maxInFlight == 1)
    }

    /// Two VMs on: each model shows only its own guest, and stopping one leaves the other polling.
    @Test func twoVMsIndependent() async {
        let clock = ManualClock()
        let channelA = ScriptedGuestChannel(.answer(guestDocument(hostname: "alfa")))
        let channelB = ScriptedGuestChannel(.answer(guestDocument(hostname: "beta")))
        let a = model(clock: clock, interval: .milliseconds(20))
        let b = model(clock: clock, interval: .milliseconds(20))
        for (monitor, channel) in [(a, channelA), (b, channelB)] {
            monitor.vmStarting(source: client(channel), guestToolsExpected: true)
            monitor.vmRunning()
            monitor.setVisible(true)
        }
        #expect(await waitUntil { channelA.connects >= 2 && channelB.connects >= 2 })
        #expect(a.status?.hostname == "alfa")
        #expect(b.status?.hostname == "beta")

        a.vmStopped(unexpectedly: false)
        #expect(!a.isPolling)
        #expect(b.isPolling)
        try? await Task.sleep(for: .milliseconds(50))
        let stoppedCount = channelA.connects
        let otherCount = channelB.connects
        #expect(await waitUntil { channelB.connects >= otherCount + 3 })
        #expect(channelA.connects == stoppedCount)
        #expect(a.state == .vmStopped)
        if case .live(let status, _) = b.state { #expect(status.hostname == "beta") } else { Issue.record("\(b.state)") }
        b.vmStopped(unexpectedly: false)
    }

    /// The window owns its monitor: polling follows the session, a crash keeps the last sample,
    /// samples reach the AI model, a session without its bridge says so.
    @Test func windowDrivesItsMonitor() async throws {
        let root = try TempRoot()
        let channel = ScriptedGuestChannel(.answer(guestDocument(hostname: "alfa")))
        let factory = FakeSessionFactory()
        factory.configure = {
            $0.guestChannel = channel
            $0.aiBridgeAttached = false
        }
        let window = VMWindowModel(
            name: try VMName("debian-13"), paths: root.paths, factory: factory,
            monitor: MonitorModel(interval: .milliseconds(20)))
        #expect(window.monitor.state == .vmStopped)
        await window.start()
        #expect(window.state == .running)
        window.monitor.setVisible(true)
        #expect(await waitUntil { window.monitor.status?.hostname == "alfa" })
        #expect(window.aiRuntime.guestResponds)
        #expect(window.aiRuntime.isVMRunning)
        // The bridge is off for this VM: no warning about a bridge that was not attached.
        #expect(window.aiBridge.attachWarning == nil)

        // The guest stops by itself: polling ends, the last sample stays.
        factory.made[0].state = .stopped
        #expect(!window.monitor.isPolling)
        if case .lastKnown(let status, _) = window.monitor.state {
            #expect(status.hostname == "alfa")
        } else {
            Issue.record("\(window.monitor.state)")
        }
        #expect(window.aiBridge.attachWarning == nil)
        #expect(!window.aiRuntime.isVMRunning)

        // Arresta: just "not running".
        await window.start()
        #expect(await waitUntil { window.monitor.status != nil })
        await window.stop()
        #expect(window.monitor.state == .vmStopped)
        #expect(!window.monitor.isPolling)
    }

    // MARK: - Polling lifetime

    /// A model dropped without `vmStopped` or `setVisible(false)`: its polling loop does not keep
    /// it alive (isolated deinit cancels the loop; the loop holds it only during one request).
    @Test func pollingLoopDoesNotRetainModel() async throws {
        let channel = ScriptedGuestChannel(.answer(guestDocument(hostname: "alfa")))
        weak var weakMonitor: MonitorModel?
        do {
            let monitor = MonitorModel(interval: .milliseconds(20))
            weakMonitor = monitor
            monitor.vmStarting(source: client(channel), guestToolsExpected: true)
            monitor.vmRunning()
            monitor.setVisible(true)
            #expect(await waitUntil { monitor.status != nil })
            #expect(monitor.isPolling)
        }
        #expect(await waitUntil { weakMonitor == nil })
        let connects = channel.connects
        try await Task.sleep(for: .milliseconds(120))
        #expect(channel.connects == connects, "the loop stopped with the model")
    }

    /// An unknown version's partial status ages like any other: stale after 10 s of failures.
    @Test func unsupportedGoesStale() async {
        let clock = ManualClock()
        let channel = ScriptedGuestChannel(.answer(guestDocument(hostname: "futura", version: "3.1")))
        let monitor = model(clock: clock)
        monitor.vmStarting(source: client(channel), guestToolsExpected: true)
        monitor.vmRunning()
        await monitor.refresh()
        #expect(monitor.state == .unsupported("3.1"))
        channel.set(.refuse)
        clock.advance(4)
        await monitor.refresh()
        #expect(monitor.state == .unsupported("3.1"))
        clock.advance(7)
        await monitor.refresh()
        guard case .stale(let status, _) = monitor.state else {
            Issue.record("expected stale, got \(monitor.state)")
            return
        }
        #expect(status.hostname == "futura")
    }

    /// The long grace (packages installed before the Guest Tools start) only on a first boot;
    /// any other boot says "Guest Tools non installati" after a short one.
    @Test func longGraceOnlyOnFirstBoot() async {
        let clock = ManualClock()
        let channel = ScriptedGuestChannel(.refuse)
        let later = model(clock: clock)
        later.vmStarting(source: client(channel), guestToolsExpected: true)
        later.vmRunning()
        clock.advance(MonitorModel.defaultBootGrace + 1)
        await later.refresh()
        #expect(later.state == .guestToolsMissing)

        let first = model(clock: clock)
        first.vmStarting(source: client(channel), guestToolsExpected: true, firstBoot: true)
        first.vmRunning()
        clock.advance(MonitorModel.defaultBootGrace + 1)
        await first.refresh()
        #expect(first.state == .waitingForGuest)
        clock.advance(MonitorModel.defaultGuestStartGrace)
        await first.refresh()
        #expect(first.state == .guestToolsMissing)
    }

    /// The provisioning progress needs the guest's answers while the Monitor tab is hidden.
    @Test func keepsPollingForProvisioning() async {
        let channel = ScriptedGuestChannel(.answer(guestDocument(hostname: "alfa")))
        let monitor = MonitorModel(interval: .milliseconds(20))
        monitor.vmStarting(source: client(channel), guestToolsExpected: true)
        monitor.vmRunning()
        #expect(!monitor.isPolling)
        monitor.keepsPolling = true
        #expect(monitor.isPolling)
        #expect(await waitUntil { monitor.status != nil })
        monitor.keepsPolling = false
        #expect(!monitor.isPolling)
        monitor.vmStopped(unexpectedly: false)
    }

    /// A guest's out-of-range percentage is shown clamped to 0…100 and never traps the app,
    /// which hosts every VM (audit NV-4).
    @Test func percentClampsHostileValues() {
        #expect(MonitorView.percent(23.4) == "23 %")
        #expect(MonitorView.percent(1e300) == "100 %")
        #expect(MonitorView.percent(1e19) == "100 %")
        #expect(MonitorView.percent(-1e300) == "0 %")
        #expect(MonitorView.percent(.infinity) == "–")
    }
}
