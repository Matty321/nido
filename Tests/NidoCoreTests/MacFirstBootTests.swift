// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
import Virtualization
@testable import NidoCore

@Suite struct MacFirstBootTests {
    private func base() throws -> VMConfig {
        VMConfig(
            id: UUID(), name: try VMName("agent"), guest: .macos, cpuCount: 4,
            memoryBytes: 8 << 30, diskBytes: 64 << 30, macAddress: "02:00:00:00:00:01",
            sshUser: "agent", osVersion: "27.2.1", macAccountFullName: "Agent")
    }

    private let password = GuestPassword("s3cret")!

    @Test func planOnHost27WithGuest27() throws {
        let plan = MacFirstBoot.plan(config: try base(), hostMajor: 27, password: password)
        #expect(plan == MacProvisioningPlan(fullName: "Agent", username: "agent", password: password))
    }

    @Test func noPlanOnHost26() throws {
        #expect(MacFirstBoot.plan(config: try base(), hostMajor: 26, password: password) == nil)
    }

    @Test func noPlanForGuest26() throws {
        var c = try base()
        c.osVersion = "26.6.2"
        #expect(MacFirstBoot.plan(config: c, hostMajor: 27, password: password) == nil)
    }

    @Test func noPlanOnceSent() throws {
        var c = try base()
        c.macProvisioningSent = true
        #expect(MacFirstBoot.plan(config: c, hostMajor: 27, password: password) == nil)
    }

    @Test func noPasswordNoPlan() throws {
        #expect(MacFirstBoot.plan(config: try base(), hostMajor: 27, password: nil) == nil)
    }

    @Test func noAccountNoPlan() throws {
        var c = try base()
        c.macAccountFullName = nil
        #expect(MacFirstBoot.plan(config: c, hostMajor: 27, password: password) == nil)
        c.macAccountFullName = ""
        #expect(MacFirstBoot.plan(config: c, hostMajor: 27, password: password) == nil)
    }

    @Test func noPlanForLinux() throws {
        var c = try base()
        c.guest = .linux
        #expect(MacFirstBoot.plan(config: c, hostMajor: 27, password: password) == nil)
    }

    // MARK: - What macOS refuses

    @Test(.enabled(if: MacFirstBoot.canValidate, "needs macOS 27 Virtualization"))
    func validateAsksVirtualization() throws {
        try MacFirstBoot.validate(fullName: "Agent", username: "agent", password: password)
        #expect(throws: MacProvisioningError.self) {
            try MacFirstBoot.validate(fullName: " ", username: "agent", password: password)
        }
        #expect(throws: MacProvisioningError.self) {
            try MacFirstBoot.validate(fullName: "Agent", username: "root", password: password)
        }
        #expect(throws: MacProvisioningError.self) {
            try MacFirstBoot.validate(fullName: "Agent", username: "agent", password: GuestPassword("abc")!)
        }
    }

    @Test func provisioningErrorsNameTheField() {
        func vz(_ code: Int, _ reason: String) -> NSError {
            NSError(domain: VZErrorDomain, code: code, userInfo: [NSLocalizedFailureReasonErrorKey: reason])
        }
        #expect(MacFirstBoot.provisioningError(vz(40001, "empty"), password: password) as? MacProvisioningError
            == .invalidFullName("empty"))
        #expect(MacFirstBoot.provisioningError(vz(40002, "bad"), password: password) as? MacProvisioningError
            == .invalidUsername("bad"))
        #expect(MacFirstBoot.provisioningError(vz(40003, "too short"), password: password) as? MacProvisioningError
            == .invalidPassword("too short"))
        // A reason that quotes the password is left out.
        #expect(MacFirstBoot.provisioningError(vz(40003, "s3cret is weak"), password: password) as? MacProvisioningError
            == .invalidPassword(""))
        let other = NSError(domain: VZErrorDomain, code: 1)
        #expect((MacFirstBoot.provisioningError(other, password: password) as NSError) == other)
        #expect(MacProvisioningError.invalidPassword("").errorDescription
            == L10n.string("macOS doesn’t accept the password of the account."))
        #expect(MacProvisioningError.invalidFullName("empty").errorDescription?.contains("empty") == true)
    }

    @Test func guestMajorParses() {
        #expect(MacFirstBoot.guestMajor("27.2.1") == 27)
        #expect(MacFirstBoot.guestMajor("27") == 27)
        #expect(MacFirstBoot.guestMajor(nil) == nil)
        #expect(MacFirstBoot.guestMajor("x") == nil)
    }

    @Test func needsPasswordMirrorsPlan() throws {
        #expect(MacFirstBoot.needsPassword(config: try base(), hostMajor: 27))
        #expect(!MacFirstBoot.needsPassword(config: try base(), hostMajor: 26))
        var c = try base()
        c.osVersion = "26.6.2"
        #expect(!MacFirstBoot.needsPassword(config: c, hostMajor: 27))
        c = try base()
        c.macProvisioningSent = true
        #expect(!MacFirstBoot.needsPassword(config: c, hostMajor: 27))
        c = try base()
        c.macAccountFullName = nil
        #expect(!MacFirstBoot.needsPassword(config: c, hostMajor: 27))
        c = try base()
        c.guest = .linux
        #expect(!MacFirstBoot.needsPassword(config: c, hostMajor: 27))
    }
}
