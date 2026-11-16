// SPDX-License-Identifier: Apache-2.0
import Foundation
import Synchronization
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

    /// The start's plan: a Linux VM never reads `config.json` again nor the Keychain; a macOS VM
    /// reads both, and a read error is thrown (never a plain start that shows Setup Assistant).
    @Test func startPlanReadsOnlyForAMacGuest() throws {
        let store = MemoryGuestPasswordStore()
        let config = try base()
        let password = try #require(GuestPassword("abcde-fghjk"))
        try store.save(password, vm: config.id)
        struct Unreadable: Error {}
        let reads = Mutex(0)
        let linux = try VMSession.firstBootPlan(
            stateGuest: .linux, readConfig: { reads.withLock { $0 += 1 }; throw Unreadable() },
            passwords: store, hostMajor: 27)
        #expect(linux == nil)
        #expect(reads.withLock { $0 } == 0)

        let plan = try VMSession.firstBootPlan(
            stateGuest: .macos, readConfig: { reads.withLock { $0 += 1 }; return config },
            passwords: store, hostMajor: 27)
        #expect(plan?.password == password)
        #expect(reads.withLock { $0 } == 1)
        #expect(throws: Unreadable.self) {
            _ = try VMSession.firstBootPlan(
                stateGuest: .macos, readConfig: { throw Unreadable() }, passwords: store, hostMajor: 27)
        }
    }

    /// Counts reads; `result` is what a read answers.
    private final class ReadingStore: GuestPasswordStore, @unchecked Sendable {
        let reads = Mutex(0)
        let result: Result<GuestPassword?, any Error>
        init(_ result: Result<GuestPassword?, any Error>) { self.result = result }
        func read(vm: UUID) throws -> GuestPassword? {
            reads.withLock { $0 += 1 }
            return try result.get()
        }
        func save(_ password: GuestPassword, vm: UUID) throws {}
        func delete(vm: UUID) throws {}
    }

    /// A Keychain that refuses the read ends the start (`VMSession.start()` throws it): never a
    /// plain start that would show Setup Assistant.
    @Test func startPlanThrowsWhenTheStoreThrows() throws {
        let store = ReadingStore(.failure(GuestPasswordStoreError.keychain(-25293)))
        #expect(throws: GuestPasswordStoreError.keychain(-25293)) {
            _ = try VMSession.firstBootPlan(
                stateGuest: .macos, readConfig: { try self.base() }, passwords: store, hostMajor: 27)
        }
        #expect(store.reads.withLock { $0 } == 1)
    }

    /// The Keychain is asked only when a plan could exist: not on a host before 27, not once the
    /// provisioning was sent, not for a VM with no account of Nido's.
    @Test func startPlanSkipsTheStoreWhenNoPlanIsPossible() throws {
        let store = ReadingStore(.failure(GuestPasswordStoreError.keychain(-25293)))
        var sent = try base()
        sent.macProvisioningSent = true
        var noAccount = try base()
        noAccount.macAccountFullName = nil
        for (config, host) in [(try base(), 26), (sent, 27), (noAccount, 27)] {
            let plan = try VMSession.firstBootPlan(
                stateGuest: .macos, readConfig: { config }, passwords: store, hostMajor: host)
            #expect(plan == nil)
        }
        #expect(store.reads.withLock { $0 } == 0)
    }

    /// No stored password: no plan and no error (the VM starts plain).
    @Test func startPlanWithNoStoredPasswordIsNil() throws {
        let store = ReadingStore(.success(nil))
        let plan = try VMSession.firstBootPlan(
            stateGuest: .macos, readConfig: { try self.base() }, passwords: store, hostMajor: 27)
        #expect(plan == nil)
        #expect(store.reads.withLock { $0 } == 1)
    }
}
