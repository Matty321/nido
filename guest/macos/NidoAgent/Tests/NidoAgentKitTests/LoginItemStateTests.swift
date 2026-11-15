// SPDX-License-Identifier: Apache-2.0
import NidoAgentKit
import Testing

@Test func loginItemRawValuesMatchSMAppServiceStatus() {
    // SMAppService.Status: notRegistered 0, enabled 1, requiresApproval 2, notFound 3.
    #expect(LoginItemState(status: 0) == .notRegistered)
    #expect(LoginItemState(status: 1) == .enabled)
    #expect(LoginItemState(status: 2) == .requiresApproval)
    #expect(LoginItemState(status: 3) == .notFound)
}

@Test func unknownLoginItemStatusCountsAsNotFound() {
    #expect(LoginItemState(status: 42) == .notFound)
    #expect(LoginItemState(status: -1) == .notFound)
}

/// macOS 26 reports `notFound` for a helper never registered: skipping it left the helper off at login.
@Test func registersWhenNotRegisteredOrNotFound() {
    #expect(LoginItemState.notRegistered.shouldRegister)
    #expect(LoginItemState.notFound.shouldRegister)
    #expect(!LoginItemState.enabled.shouldRegister)
    #expect(!LoginItemState.requiresApproval.shouldRegister)
}

@Test func onlyRequiresApprovalNeedsTheUser() {
    #expect(LoginItemState.allCases.filter(\.needsApproval) == [.requiresApproval])
}

@Test func loginItemLogNamesAreDistinct() {
    #expect(Set(LoginItemState.allCases.map(\.logName)).count == LoginItemState.allCases.count)
}
