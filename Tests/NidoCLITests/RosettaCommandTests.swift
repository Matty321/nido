// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import NidoCLI
@testable import NidoCore

@Suite(.italian) struct RosettaCommandTests {
    private struct Env {
        let tmp: URL
        let paths: NidoPaths
        let bundle: VMBundle

        init(guestRegisters: Bool = true) throws {
            tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("nido-tests-rosetta-cli-\(UUID().uuidString)", isDirectory: true)
            paths = NidoPaths(root: tmp.appendingPathComponent("VMs", isDirectory: true))
            var config = VMConfig(
                id: UUID(), name: try VMName("vm"), guest: .linux, cpuCount: 2,
                memoryBytes: 4 << 30, diskBytes: 20 << 30, macAddress: "02:00:00:00:00:01")
            config.guestRegistersRosetta = guestRegisters
            bundle = try VMBundle.create(config: config, paths: paths)
        }

        func cleanup() { try? FileManager.default.removeItem(at: tmp) }
    }

    /// Records whether the system install was asked for; it must never run by itself.
    private final class InstallSpy: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls = 0
        var calls: Int { lock.withLock { _calls } }
        func install() async throws { lock.withLock { _calls += 1 } }
    }

    @Test func templateRosettaIsRefused() throws {
        let env = try Env()
        defer { env.cleanup() }
        try env.bundle.updateConfig { $0.isTemplate = true }
        for enabled in [true, false] {
            #expect(throws: NidoError.isTemplate("vm")) {
                _ = try CLISupport.setRosetta(vm: "vm", enabled: enabled, paths: env.paths, state: .installed)
            }
        }
        #expect(try env.bundle.readConfig().rosetta == false)
    }

    @Test func enableRequiresStoppedVM() throws {
        let env = try Env()
        defer { env.cleanup() }
        for owner in [LockOwner.cli, .app] {
            let lock = try BundleLock.acquire(env.bundle, owner: owner)
            #expect(throws: NidoError.vmMustBeStopped("vm")) {
                _ = try CLISupport.setRosetta(vm: "vm", enabled: true, paths: env.paths, state: .installed)
            }
            #expect(throws: NidoError.vmMustBeStopped("vm")) {
                _ = try CLISupport.setRosetta(vm: "vm", enabled: false, paths: env.paths, state: .installed)
            }
            lock.release()
        }
        #expect(try env.bundle.readConfig().rosetta == false)

        let message = try CLISupport.setRosetta(vm: "vm", enabled: true, paths: env.paths, state: .installed)
        #expect(try env.bundle.readConfig().rosetta)
        #expect(message.contains("Vale dal prossimo avvio di vm"))
        #expect(!message.contains("sudo"))  // created with the cloud-init registration
        #expect(BundleLock.holder(env.bundle) == nil)

        let off = try CLISupport.setRosetta(vm: "vm", enabled: false, paths: env.paths, state: .installed)
        #expect(try env.bundle.readConfig().rosetta == false)
        #expect(off.contains("disattivata"))
    }

    @Test func enableWithoutRosettaOnTheMacSaysWhy() throws {
        let env = try Env()
        defer { env.cleanup() }
        // Not installed or unsupported: refused with the app's reason, nothing written.
        #expect(throws: NidoError.rosettaNotInstalled) {
            _ = try CLISupport.setRosetta(vm: "vm", enabled: true, paths: env.paths, state: .notInstalled)
        }
        #expect(throws: NidoError.rosettaUnavailable) {
            _ = try CLISupport.setRosetta(vm: "vm", enabled: true, paths: env.paths, state: .unsupported)
        }
        #expect(try env.bundle.readConfig().rosetta == false)
        #expect(CLISupport.message(for: NidoError.rosettaNotInstalled) + "." == RosettaState.notInstalled.reason)
        #expect(CLISupport.message(for: NidoError.rosettaUnavailable) + "." == RosettaState.unsupported.reason)
        // A VM that has it on can always turn it off.
        var config = try env.bundle.readConfig()
        config.rosetta = true
        try env.bundle.writeConfig(config)
        for state in [RosettaState.notInstalled, .unsupported] {
            try CLISupport.setRosetta(vm: "vm", enabled: false, paths: env.paths, state: state)
            #expect(try env.bundle.readConfig().rosetta == false)
        }
    }

    @Test func olderVMGetsTheGuestCommand() throws {
        let env = try Env(guestRegisters: false)
        defer { env.cleanup() }
        let message = try CLISupport.setRosetta(vm: "vm", enabled: true, paths: env.paths, state: .installed)
        #expect(message.contains(RosettaSupport.legacyGuestCommand))
    }

    @Test func statusTexts() {
        #expect(CLISupport.rosettaStatus(.installed).contains("installata"))
        #expect(CLISupport.rosettaStatus(.notInstalled).contains("nido rosetta install"))
        #expect(CLISupport.rosettaStatus(.unsupported).contains("non è disponibile"))
    }

    @Test func installAsksFirstAndNeverRunsByItself() async throws {
        // Already installed or unsupported: no question, no install.
        let spy = InstallSpy()
        var asked = 0
        let done = try await CLISupport.installRosetta(
            state: .installed, assumeYes: false, confirm: { _ in asked += 1; return true }, install: spy.install)
        #expect(done.contains("già installata"))
        await #expect(throws: NidoError.self) {
            _ = try await CLISupport.installRosetta(
                state: .unsupported, assumeYes: true, confirm: { _ in true }, install: spy.install)
        }
        #expect(asked == 0)
        #expect(spy.calls == 0)

        // Declined: nothing installed.
        let declined = try await CLISupport.installRosetta(
            state: .notInstalled, assumeYes: false, confirm: { _ in asked += 1; return false }, install: spy.install)
        #expect(asked == 1)
        #expect(spy.calls == 0)
        #expect(declined.contains("annullata"))

        // Confirmed (or --yes): the system install runs once.
        _ = try await CLISupport.installRosetta(
            state: .notInstalled, assumeYes: false, confirm: { _ in true }, install: spy.install)
        #expect(spy.calls == 1)
        _ = try await CLISupport.installRosetta(
            state: .notInstalled, assumeYes: true, confirm: { _ in Issue.record("asked"); return false },
            install: spy.install)
        #expect(spy.calls == 2)
    }
}

extension RosettaCommandTests {
    /// CORE m5: turning Rosetta on or off on a suspended VM says its saved state will be discarded.
    @Test func togglingRosettaOnASuspendedVMWarns() throws {
        let env = try Env()
        defer { env.cleanup() }
        try Data("state".utf8).write(to: env.bundle.stateURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: env.bundle.stateURL.path)
        var config = try env.bundle.readConfig()
        config.suspendedConfigHash = config.stateHash()
        try env.bundle.writeConfig(config)
        let warning = "Attenzione: la VM è sospesa: al prossimo avvio lo stato salvato verrà scartato."
        #expect(try CLISupport.setRosetta(vm: "vm", enabled: false, paths: env.paths).contains(warning) == false)
        #expect(try CLISupport.setRosetta(vm: "vm", enabled: true, paths: env.paths, state: .installed).contains(warning))
    }
}
