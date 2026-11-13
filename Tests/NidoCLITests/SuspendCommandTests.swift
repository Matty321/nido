// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import NidoCLI
@testable import NidoCore

@Suite(.italian) struct SuspendCommandTests {
    struct Env {
        let tmp: URL
        let paths: NidoPaths
        let bundle: VMBundle

        init() throws {
            tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("nido-tests-suspend-cli-\(UUID().uuidString)", isDirectory: true)
            paths = NidoPaths(root: tmp.appendingPathComponent("VMs", isDirectory: true))
            let config = VMConfig(
                id: UUID(), name: try VMName("vm"), guest: .linux, cpuCount: 2,
                memoryBytes: 1 << 30, diskBytes: 1 << 20, macAddress: "02:00:00:00:00:01")
            bundle = try VMBundle.create(config: config, paths: paths)
        }

        func suspend() throws {
            try Data("saved-state".utf8).write(to: bundle.stateURL)
            var config = try bundle.readConfig()
            config.suspendedConfigHash = "h"
            try bundle.writeConfig(config)
        }

        func cleanup() { try? FileManager.default.removeItem(at: tmp) }
    }

    @Test func listShowsSuspended() throws {
        let env = try Env()
        defer { env.cleanup() }
        #expect(try CLISupport.listVMs(paths: env.paths).map(\.state) == ["ferma"])
        try env.suspend()
        #expect(try CLISupport.listVMs(paths: env.paths).map(\.state) == ["sospesa"])
        let lock = try BundleLock.acquire(env.bundle, owner: .cli)
        defer { lock.release() }
        #expect(try CLISupport.listVMs(paths: env.paths).map(\.state) == ["in esecuzione"])
    }

    @Test func suspendReportReadsTheBundle() throws {
        let env = try Env()
        defer { env.cleanup() }
        #expect(CLISupport.suspendReport(bundle: env.bundle, lockHeld: false) == .stoppedWithoutState)
        #expect(CLISupport.suspendReport(bundle: env.bundle, lockHeld: true) == .stillRunning)
        try env.suspend()
        #expect(CLISupport.suspendReport(bundle: env.bundle, lockHeld: false) == .suspended)
        #expect(CLISupport.SuspendReport.suspended.message(vm: "vm") == "VM vm sospesa.")
    }
}

extension SuspendCommandTests {
    /// Finding 1: a holder that cannot suspend answers, and the waiter returns at once.
    @Test func refusalIsReportedAtOnce() throws {
        let env = try Env()
        defer { env.cleanup() }
        let lock = try BundleLock.acquire(env.bundle, owner: .cli)
        defer { lock.release() }
        try VMControl.writeSuspendResult(bundle: env.bundle, reason: "la VM non è ancora in esecuzione")
        let started = Date()
        let report = CLISupport.waitForSuspend(bundle: env.bundle, timeout: 30)
        #expect(Date().timeIntervalSince(started) < 2)
        #expect(report == .refused("la VM non è ancora in esecuzione"))
        #expect(report.message(vm: "vm") == "La VM vm non è stata sospesa: la VM non è ancora in esecuzione")
        // Consumed: the next request does not see it.
        #expect(VMControl.readSuspendResult(bundle: env.bundle) == nil)
    }

    /// The three fixed refusals travel as language-neutral codes: `nido stop --suspend` shows
    /// them in its own language; any other answer (an error message) is shown as it is.
    @Test func refusalCodesAreShownInTheReadersLanguage() throws {
        let env = try Env()
        defer { env.cleanup() }
        let lock = try BundleLock.acquire(env.bundle, owner: .cli)
        defer { lock.release() }
        try VMControl.writeSuspendResult(bundle: env.bundle, reason: CLISupport.SuspendRefusal.alreadyStopping.rawValue)
        let report = CLISupport.waitForSuspend(bundle: env.bundle, timeout: 30)
        #expect(report == .refused("suspend-refused:stopping"))
        #expect(report.message(vm: "vm") == "La VM vm non è stata sospesa: si sta già arrestando")
        #expect(CLISupport.SuspendReport.refused("suspend-refused:resuming").message(vm: "vm")
            == "La VM vm non è stata sospesa: sta riprendendo dallo stato sospeso, riprova tra poco")
        #expect(CLISupport.SuspendReport.refused("suspend-refused:not-running").message(vm: "vm")
            == "La VM vm non è stata sospesa: non è ancora in esecuzione, riprova tra poco")
        #expect(CLISupport.SuspendRefusal.alreadyStopping.line == "Sospensione rifiutata: la VM si sta già arrestando.")
        // Codes are plain ASCII words; a free-text reason is left alone.
        for refusal in CLISupport.SuspendRefusal.allCases {
            #expect(refusal.rawValue.allSatisfy { $0.isASCII && !$0.isWhitespace })
        }
        #expect(CLISupport.SuspendRefusal.text("disco pieno") == "disco pieno")
    }

    @Test func waiterEndsWhenTheLockIsReleased() throws {
        let env = try Env()
        defer { env.cleanup() }
        try env.suspend()
        #expect(CLISupport.waitForSuspend(bundle: env.bundle, timeout: 30) == .suspended)
        let lock = try BundleLock.acquire(env.bundle, owner: .cli)
        defer { lock.release() }
        #expect(CLISupport.waitForSuspend(bundle: env.bundle, timeout: 0.3, pollInterval: 0.1) == .stillRunning)
    }

    @Test func suspendResultRefusesASymlink() throws {
        let env = try Env()
        defer { env.cleanup() }
        let target = env.tmp.appendingPathComponent("elsewhere")
        try Data("x".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: env.bundle.suspendResultURL, withDestinationURL: target)
        #expect(VMControl.readSuspendResult(bundle: env.bundle) == nil)
        #expect(throws: NidoError.unsafePath(".suspend-result")) {
            try VMControl.writeSuspendResult(bundle: env.bundle, reason: "r")
        }
        VMControl.clearSuspendResult(bundle: env.bundle)
        #expect(FileManager.default.fileExists(atPath: target.path))
    }
}
