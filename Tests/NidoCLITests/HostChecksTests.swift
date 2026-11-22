// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import NidoCLI
@testable import NidoCore

/// A data root with one macOS VM (agent access on) whose every file can be compared before and
/// after a refused command.
struct IntelRefusalFixture {
    let tmp: URL
    let paths: NidoPaths
    let bundle: VMBundle

    init(guest: GuestOS = .macos) throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("nido-tests-intel-\(UUID().uuidString)", isDirectory: true)
        paths = NidoPaths(root: tmp.appendingPathComponent("VMs", isDirectory: true))
        var config = VMConfig(
            id: UUID(), name: try VMName("vm"), guest: guest, cpuCount: 2,
            memoryBytes: 4 << 30, diskBytes: 20 << 30, macAddress: "02:00:00:00:00:01")
        if guest == .macos { config.agentAccess = true }
        bundle = try VMBundle.create(config: config, paths: paths)
    }

    /// Every file under the root with its bytes: a refusal must leave this equal.
    func snapshot() throws -> [String: Data] {
        var result: [String: Data] = [:]
        let base = tmp.resolvingSymlinksInPath().path
        let files = FileManager.default.enumerator(at: tmp, includingPropertiesForKeys: nil)
        while let url = files?.nextObject() as? URL {
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            let key = url.resolvingSymlinksInPath().path.replacingOccurrences(of: base, with: "")
            result[key] = isDirectory.boolValue ? Data("dir".utf8) : try Data(contentsOf: url)
        }
        return result
    }

    func cleanup() { try? FileManager.default.removeItem(at: tmp) }
}

@Suite(.italian) struct HostChecksTests {
    // MARK: - Helpers of the checks

    @Test func translatedProcessIsRefused() throws {
        #expect(throws: NidoError.translatedProcess) { try HostChecks.refuseTranslated(isTranslated: { true }) }
        try HostChecks.refuseTranslated(isTranslated: { false })
    }

    @Test func imageFileHelpNamesArchitecture() {
        let intel = HostChecks.imageFileHelp(.intel)
        let arm = HostChecks.imageFileHelp(.appleSilicon)
        #expect(intel.hasPrefix("Immagine disco locale, raw o qcow2 (non verificata). "))
        #expect(intel.hasSuffix("Usa un’immagine amd64 su questo Mac."))
        #expect(arm.hasSuffix("Usa un’immagine arm64 su questo Mac."))
    }

    // MARK: - Command entry points on Intel

    @Test func macCommandsRefusedOnIntel() throws {
        let env = try IntelRefusalFixture()
        defer { env.cleanup() }
        let before = try env.snapshot()
        let refused = NidoError.needsAppleSilicon

        // nido agent enable / disable (and every other agent subcommand: they open the VM here).
        #expect(throws: refused) { _ = try AgentSupport.switchAgentAccess(true, vm: "vm", paths: env.paths, host: .intel) }
        #expect(throws: refused) { _ = try AgentSupport.switchAgentAccess(false, vm: "vm", paths: env.paths, host: .intel) }
        #expect(throws: refused) { _ = try AgentSupport.openBundle("vm", paths: env.paths, host: .intel) }
        // nido act (a wait action would otherwise succeed; the VM name need not even exist).
        #expect(throws: refused) {
            _ = try AgentSupport.openForAct(vm: "vm", action: ["wait", "10"], paths: env.paths, host: .intel)
        }
        #expect(throws: refused) {
            _ = try AgentSupport.openForAct(vm: "nobody", action: ["wait", "10"], paths: env.paths, host: .intel)
        }
        // nido mcp --fresh (plain `nido mcp` opens the VM with AgentSupport.openBundle, above).
        for stopped in [true, false] {
            #expect(throws: refused) {
                _ = try AgentSupport.openFreshBase(vm: "vm", requireStopped: stopped, paths: env.paths, host: .intel)
            }
        }
        // nido image macos, also with --output.
        #expect(throws: refused) { _ = try CLISupport.beginMacImage(output: nil, host: .intel) }
        #expect(throws: refused) {
            _ = try CLISupport.beginMacImage(output: env.tmp.appendingPathComponent("m.ipsw").path, host: .intel)
        }

        #expect(try env.snapshot() == before)
    }

    @Test func macCommandsUnchangedOnAppleSilicon() throws {
        let env = try IntelRefusalFixture()
        defer { env.cleanup() }
        let host = HostPlatform.appleSilicon

        _ = try AgentSupport.openBundle("vm", paths: env.paths, host: host)
        let act = try AgentSupport.openForAct(vm: "vm", action: ["wait", "10"], paths: env.paths, host: host)
        #expect(act.name.rawValue == "vm")
        let fresh = try AgentSupport.openFreshBase(vm: "vm", requireStopped: true, paths: env.paths, host: host)
        #expect(fresh.0.rawValue == "vm")
        let (_, destination) = try CLISupport.beginMacImage(output: nil, host: host)
        #expect(destination == nil)
        _ = try AgentSupport.switchAgentAccess(false, vm: "vm", paths: env.paths, host: host)
        #expect(try env.bundle.readConfig().agentAccess == false)
    }

    @Test func rosettaInstallAndEnableRefusedOnIntelDisableWorks() async throws {
        let env = try IntelRefusalFixture(guest: .linux)
        defer { env.cleanup() }
        let before = try env.snapshot()
        var installs = 0
        var asked = 0
        await #expect(throws: NidoError.rosettaUnavailable) {
            _ = try await CLISupport.installRosetta(
                state: .notInstalled, assumeYes: true, confirm: { _ in asked += 1; return true },
                install: { installs += 1 }, host: .intel)
        }
        #expect(installs == 0 && asked == 0)
        #expect(throws: NidoError.rosettaUnavailable) {
            _ = try CLISupport.setRosetta(
                vm: "vm", enabled: true, paths: env.paths, state: .installed, host: .intel)
        }
        #expect(try env.snapshot() == before)
        // Disabling still works on Intel (a VM may carry the flag from elsewhere).
        _ = try CLISupport.setRosetta(
            vm: "vm", enabled: false, paths: env.paths, state: .unsupported, host: .intel)
        // Status reports unsupported.
        #expect(CLISupport.rosettaStatus(.unsupported).contains("non è disponibile"))
    }
}
