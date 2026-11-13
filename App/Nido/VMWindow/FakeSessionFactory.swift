// SPDX-License-Identifier: Apache-2.0
#if DEBUG
    import Darwin
    import Foundation
    import NidoCore

    /// DEBUG `-NidoFakeSessions`: VM windows run a session without a VM, so the UI tests can drive
    /// the running states (close confirmation, full screen, quit) and the serial console without
    /// booting a guest. The bundle lock is still the real one.
    ///
    /// DEBUG `-NidoFakeStates "dev-box=starting,sandbox=paused,test-arm=error"` (implies fake
    /// sessions) gives single VMs a scripted behaviour, and the app starts those VMs at launch, so
    /// the screenshot tests find the library and the VM window in every live state.
    @MainActor
    final class FakeVMSessionFactory: SessionFactory {
        /// What a fake VM does when it is started.
        enum Plan: String, Sendable, CaseIterable {
            /// Boots in 300 ms to the login prompt (the default).
            case running
            /// Stays in "Avvio in corso" with the first kernel lines on the console.
            case starting
            /// Boots, then pauses (the pause comes from the app, see `AppEnvironment`).
            case paused
            /// The session cannot be created: the start fails with a disk error.
            case error
        }

        /// The design's start failure (S07 errore).
        struct DiskUnreadable: LocalizedError {
            var errorDescription: String? {
                String(localized: "The VM’s disk (disk.img) can’t be read. Check the free space on the Mac and start it again.")
            }
        }

        let plans: [String: Plan]
        /// `-NidoFakeGuest`: what the guest of single VMs answers (monitor, Ollama, bridge).
        let guests: [String: FakeGuest]
        /// One runtime per VM: its state (installed, models) lasts as long as the app.
        private var runtimes: [String: FakeAIRuntime] = [:]

        init(plans: [String: Plan] = [:], guests: [String: FakeGuest] = [:]) {
            self.plans = plans
            self.guests = guests
        }

        func makeSession(bundle: VMBundle) async throws -> any VMSessionHandle {
            let name = bundle.url.deletingPathExtension().lastPathComponent
            let plan = plans[name] ?? .running
            if plan == .error { throw DiskUnreadable() }
            return FakeVMSession(
                name: name, bundleURL: bundle.url, hangsWhileStarting: plan == .starting, guest: guests[name])
        }

        func aiRuntime(for name: VMName) -> (any AIRuntimeControlling)? {
            guard let guest = guests[name.rawValue] else { return nil }
            if let existing = runtimes[name.rawValue] { return existing }
            let runtime = FakeAIRuntime(behavior: guest.ollama)
            runtimes[name.rawValue] = runtime
            return runtime
        }

        /// Parses `name=plan,name=plan`; nil when the value is malformed or names an unknown plan.
        nonisolated static func parsePlans(_ text: String) -> [String: Plan]? {
            var plans: [String: Plan] = [:]
            for item in text.split(separator: ",") {
                let parts = item.split(separator: "=", omittingEmptySubsequences: false)
                guard parts.count == 2, !parts[0].isEmpty, let plan = Plan(rawValue: String(parts[1])) else {
                    return nil
                }
                plans[String(parts[0])] = plan
            }
            return plans.isEmpty ? nil : plans
        }
    }

    /// A live snapshot of a fake VM writes a placeholder state after `saveDuration` (long enough
    /// for the screenshot of S09 "creazione in corso").
    @MainActor
    final class FakeVMSession: VMSessionHandle, MachineStateSaving {
        let console: (any GuestConsole)?
        let bundleURL: URL
        let attachedStateHash = "fake"
        private let hangsWhileStarting: Bool
        private let guest: FakeGuest?
        static let saveDuration: Duration = .seconds(8)

        init(name: String, bundleURL: URL, hangsWhileStarting: Bool = false, guest: FakeGuest? = nil) {
            self.bundleURL = bundleURL
            self.hangsWhileStarting = hangsWhileStarting
            self.guest = guest
            console = FakeGuestConsole(name: name, booted: !hangsWhileStarting)
        }

        /// `-NidoFakeGuest`: the fake guest's monitor; none without one (or for `missing`).
        var guestChannel: (any GuestChannel)? {
            guard let guest, guest.monitor != .missing else { return nil }
            return FakeGuestChannel(monitor: guest.monitor)
        }

        var aiBridgeAttached: Bool? { guest?.bridgeAttached }

        var state: VMRunState = .stopped {
            didSet { if oldValue != state { onStateChange?(state) } }
        }
        var onStateChange: ((VMRunState) -> Void)?
        var machineIsGone: Bool { !state.acceptsStop && state != .stopping }

        func start() async throws {
            state = .starting
            if hangsWhileStarting { return }
            try? await Task.sleep(for: .milliseconds(300))
            if state == .starting { state = .running }
            if guest?.monitor == .stops {
                // The guest powers off by itself: the monitor keeps its last sample.
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(6))
                    if self?.state == .running { self?.state = .stopped }
                }
            }
        }

        func pause() async throws {
            guard state == .running else { throw NidoError.notRunning("fake") }
            state = .paused
        }

        func resume() async throws {
            guard state == .paused else { throw NidoError.notRunning("fake") }
            state = .running
        }

        func startOrResume() async throws -> SuspendedState.BootOutcome {
            try await start()
            return .coldStart
        }

        func validateSaveRestoreSupport() throws {}

        var stateSaver: (any MachineStateSaving)? { self }

        func saveMachineState(to url: URL) async throws {
            guard state == .paused else { throw NidoError.notRunning("fake") }
            try? await Task.sleep(for: Self.saveDuration)
            // As PrivateFile (internal to NidoCore) creates bundle files: new, no symlink, 0600.
            let fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            defer { _ = Darwin.close(fd) }
            let bytes = Array("fake-state".utf8)
            guard bytes.withUnsafeBytes({ Darwin.write(fd, $0.baseAddress, $0.count) }) == bytes.count else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }

        /// Saves nothing (no VM): pauses, then stops, as a suspend looks from the window.
        func suspend() async throws {
            guard state == .running || state == .paused else { throw NidoError.notRunning("fake") }
            state = .paused
            try? await Task.sleep(for: .milliseconds(300))
            state = .stopped
        }

        /// A guest that takes a moment to power off.
        func stop(gracePeriod: Duration) async {
            guard state.acceptsStop else { return }
            state = .stopping
            try? await Task.sleep(for: .seconds(1))
            state = .stopped
        }
    }

    /// A getty on hvc0, as far as a test can tell: the end of the boot, the Debian banner and the
    /// login prompt, then an echo of what is typed (Backspace erases, Return prompts again). A
    /// guest that is still booting shows only the first kernel lines.
    final class FakeGuestConsole: GuestConsole {
        let output: AsyncStream<Data>
        private let continuation: AsyncStream<Data>.Continuation
        private let prompt: String

        init(name: String, booted: Bool = true) {
            (output, continuation) = AsyncStream.makeStream(of: Data.self)
            prompt = "\(name) login: "
            continuation.yield(Data((booted ? Self.bootTail(name: name, prompt: prompt) : Self.kernelHead).utf8))
        }

        deinit { continuation.finish() }

        func send(_ data: Data) {
            var echo = Data()
            for byte in data {
                switch byte {
                case 0x0D: echo.append(Data("\r\n\(prompt)".utf8))
                case 0x7F: echo.append(Data("\u{08} \u{08}".utf8))
                default: echo.append(byte)
                }
            }
            continuation.yield(echo)
        }

        /// The design's console (S07 avvio).
        static let kernelHead = """
            Loading Linux 6.12.48+deb13-arm64 ...\r
            Loading initial ramdisk ...\r
            [    0.000000] Booting Linux on physical CPU 0x0000000000 [0x610f0000]\r
            [    0.000000] Linux version 6.12.48+deb13-arm64 (debian-kernel@lists.debian.org)\r
            [    0.000000] Machine model: Apple Virtualization Generic Platform\r
            [    1.204817] virtio_blk virtio1: [vda] 134217728 512-byte logical blocks (68.7 GB/64.0 GiB)\r

            """

        /// The design's console (S07 in esecuzione).
        static func bootTail(name: String, prompt: String) -> String {
            """
            [  OK  ] Finished cloud-init-network.service - Cloud-init: Network Stage.\r
            [  OK  ] Reached target cloud-config.target - Cloud-config availability.\r
            [  OK  ] Started ssh.service - OpenBSD Secure Shell server.\r
            [  OK  ] Finished cloud-final.service - Cloud-init: Final Stage.\r
            [  OK  ] Reached target multi-user.target - Multi-User System.\r
            \r
            Debian GNU/Linux 13 \(name) hvc0\r
            \r
            \(prompt)
            """
        }
    }
#endif
