// SPDX-License-Identifier: Apache-2.0
import Testing
@testable import NidoCore

@Suite struct CodeSigningIdentityTests {
    @Test func adHocTestRunnerHasNoTeam() {
        #expect(CodeSigningIdentity.currentTeamID() == nil)
    }
}
