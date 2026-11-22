// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import NidoCore

@Suite struct ArchitectureGateTests {
    func config(_ architecture: CPUArchitecture = .arm64, guest: GuestOS = .linux) throws -> VMConfig {
        VMConfig(
            id: UUID(), name: try VMName("debian-13"), guest: guest, cpuCount: 2,
            memoryBytes: 4 << 30, diskBytes: 20 << 30, macAddress: "02:00:00:00:00:01",
            architecture: architecture)
    }

    @Test func sameArchPasses() throws {
        try ArchitectureGate.check(try config(.arm64), host: .appleSilicon)
        try ArchitectureGate.check(try config(.x86_64), host: .intel)
        try ArchitectureGate.check(try config(.arm64, guest: .macos), host: .appleSilicon)
    }

    @Test func arm64OnIntelRefused() throws {
        let error = #expect(throws: NidoError.self) {
            try ArchitectureGate.check(try config(.arm64), host: .intel)
        }
        #expect(error == .wrongArchitecture(name: "debian-13", made: .arm64))
        #expect(error?.localizedDescription(language: "en") == "debian-13 was made for Apple silicon: it can’t start on this Mac")
    }

    @Test func intelOnAppleSiliconRefused() throws {
        let error = #expect(throws: NidoError.self) {
            try ArchitectureGate.check(try config(.x86_64), host: .appleSilicon)
        }
        #expect(error == .wrongArchitecture(name: "debian-13", made: .x86_64))
    }

    @Test func macOSOnIntelRefused() throws {
        let error = #expect(throws: NidoError.self) {
            try ArchitectureGate.check(try config(.x86_64, guest: .macos), host: .intel)
        }
        #expect(error == .wrongArchitecture(name: "debian-13", made: .arm64))
    }
}
