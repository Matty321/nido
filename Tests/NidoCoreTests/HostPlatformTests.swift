// SPDX-License-Identifier: Apache-2.0
import Testing
@testable import NidoCore

@Suite struct HostPlatformTests {
    @Test func appleSiliconSupportsEverything() {
        let host = HostPlatform.appleSilicon
        #expect(host.architecture == .arm64)
        #expect(host.supportsMacGuests)
        #expect(host.supportsSaveRestore)
        #expect(host.supportsRosetta)
    }

    @Test func intelSupportsNone() {
        let host = HostPlatform.intel
        #expect(host.architecture == .x86_64)
        #expect(!host.supportsMacGuests)
        #expect(!host.supportsSaveRestore)
        #expect(!host.supportsRosetta)
    }

    @Test func labels() {
        #expect(CPUArchitecture.arm64.imageLabel == "arm64")
        #expect(CPUArchitecture.x86_64.imageLabel == "amd64")
        #expect(CPUArchitecture.arm64.unameMachine == "aarch64")
        #expect(CPUArchitecture.x86_64.unameMachine == "x86_64")
    }

    @Test func fakeHostOnlyInDebug() {
        #if DEBUG
        #expect(HostPlatform.current(environment: ["NIDO_FAKE_HOST": "intel"]) == .intel)
        #else
        #expect(HostPlatform.current(environment: ["NIDO_FAKE_HOST": "intel"])
            == HostPlatform.current(environment: [:]))
        #endif
    }

    @Test func currentFollowsCompiledArch() {
        #if arch(arm64)
        #expect(HostPlatform.current(environment: [:]) == .appleSilicon)
        #expect(HostPlatform.current == .appleSilicon)
        #else
        #expect(HostPlatform.current(environment: [:]) == .intel)
        #endif
    }
}
