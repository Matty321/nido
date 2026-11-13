// SPDX-License-Identifier: Apache-2.0
import Testing
@testable import NidoCore

struct NidoVersionTests {
    @Test func buildNumberFollowsVersion() {
        #expect(NidoVersion.build(for: "0.8.0") == 800)
        #expect(NidoVersion.build(for: "0.7.6") == 706)
        #expect(NidoVersion.build(for: "1.2.3") == 10203)
    }

    @Test func rejectsMalformedVersions() {
        #expect(NidoVersion.build(for: "0.100.0") == nil)
        #expect(NidoVersion.build(for: "0.0.100") == nil)
        #expect(NidoVersion.build(for: "1.0") == nil)
        #expect(NidoVersion.build(for: "1.0.0.0") == nil)
        #expect(NidoVersion.build(for: "a.b.c") == nil)
        #expect(NidoVersion.build(for: "1.-1.0") == nil)
    }

    @Test func currentBuildMatchesCurrentVersion() {
        #expect(NidoVersion.build == NidoVersion.build(for: NidoVersion.current))
    }
}
