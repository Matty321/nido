// SPDX-License-Identifier: Apache-2.0
import Foundation
import Security
import Testing
@testable import NidoCore

private let testService = "io.gitlab.pichierri.Nido.guest-account.tests"

/// True when this process can write the login keychain (not the case without a user session):
/// checked with a throwaway item.
private let keychainAvailable: Bool = {
    let store = KeychainGuestPasswordStore(service: "\(testService).probe.\(UUID().uuidString)")
    let id = UUID()
    guard let password = GuestPassword("probe") else { return false }
    do {
        try store.save(password, vm: id)
        try store.delete(vm: id)
        return true
    } catch {
        return false
    }
}()

@Suite struct GuestPasswordStoreTests {
    @Test func memoryStoreRoundTrips() throws {
        let store = MemoryGuestPasswordStore()
        let id = UUID()
        let password = try #require(GuestPassword("s3cret"))
        #expect(try store.read(vm: id) == nil)
        try store.save(password, vm: id)
        #expect(try store.read(vm: id) == password)
        #expect(try store.read(vm: UUID()) == nil)
        try store.delete(vm: id)
        #expect(try store.read(vm: id) == nil)
    }

    @Test func memoryStoreContains() throws {
        let store = MemoryGuestPasswordStore()
        let id = UUID()
        #expect(try !store.contains(vm: id))
        try store.save(try #require(GuestPassword("s3cret")), vm: id)
        #expect(try store.contains(vm: id))
        #expect(try !store.contains(vm: UUID()))
        try store.delete(vm: id)
        #expect(try !store.contains(vm: id))
    }

    @Test func deleteMissingIsNotAnError() throws {
        try MemoryGuestPasswordStore().delete(vm: UUID())
    }

    @Test func passwordIsRedacted() throws {
        let password = try #require(GuestPassword("s3cret"))
        #expect(!"\(password)".contains("s3cret"))
        #expect(!String(reflecting: password).contains("s3cret"))
        #expect(!"\([password])".contains("s3cret"))
        var dumped = ""
        dump(password, to: &dumped)
        #expect(!dumped.contains("s3cret"))
        #expect(password.value == "s3cret")
    }

    @Test func emptyIsNotAPassword() {
        #expect(GuestPassword("") == nil)
    }

    /// ssh's askpass reader stops at a line break or NUL and keeps at most 1023 bytes.
    @Test func refusesWhatAskpassCannotCarry() {
        #expect(GuestPassword("pass\nword") == nil)
        #expect(GuestPassword("pass\rword") == nil)
        #expect(GuestPassword("pass\0word") == nil)
        #expect(GuestPassword("password\n") == nil)
        #expect(GuestPassword(String(repeating: "a", count: 1024)) == nil)
        #expect(GuestPassword(String(repeating: "a", count: 1023)) != nil)
        // Bytes, not characters: 511 × "é" (2 bytes) + "a" is 1023 bytes; one "é" more is 1024.
        #expect(GuestPassword(String(repeating: "é", count: 511) + "a") != nil)
        #expect(GuestPassword(String(repeating: "é", count: 512)) == nil)
        #expect(GuestPassword("tab\tand space ok") != nil)
    }

    @Test func generatedPasswordFormat() throws {
        let alphabet = Set("abcdefghjkmnpqrstuvwx23456789")
        let pattern = try Regex("^[a-hjkmnp-x2-9]{5}(-[a-hjkmnp-x2-9]{5}){3}$")
        for _ in 0..<200 {
            let value = GuestPassword.generate().value
            #expect(value.wholeMatch(of: pattern) != nil, "\(value.count) characters")
            #expect(value.count == 23)
            let groups = value.split(separator: "-")
            #expect(groups.count == 4 && groups.allSatisfy { $0.count == 5 })
            #expect(value.filter { $0 != "-" }.allSatisfy(alphabet.contains))
        }
    }

    @Test func generatedPasswordsDiffer() {
        let values = Set((0..<50).map { _ in GuestPassword.generate().value })
        #expect(values.count == 50)
        #expect(GuestPassword.generate() != GuestPassword.generate())
    }

    @Test func defaultKeychainService() {
        #expect(KeychainGuestPasswordStore().service == "io.gitlab.pichierri.Nido.guest-account")
    }

    @Test(.enabled(if: keychainAvailable, "needs a login keychain the test process can write"))
    func keychainRoundTrips() throws {
        let store = KeychainGuestPasswordStore(service: "\(testService).\(UUID().uuidString)")
        let id = UUID()
        defer { try? store.delete(vm: id) }
        #expect(try store.read(vm: id) == nil)
        #expect(try !store.contains(vm: id))
        let first = try #require(GuestPassword("first pass"))
        try store.save(first, vm: id)
        #expect(try store.contains(vm: id))
        #expect(try store.read(vm: id) == first)
        let second = try #require(GuestPassword("second"))
        try store.save(second, vm: id)
        #expect(try store.read(vm: id) == second)
        try store.delete(vm: id)
        #expect(try store.read(vm: id) == nil)
        #expect(try !store.contains(vm: id))
        try store.delete(vm: id)
    }

    /// A Keychain failure is reported with its status, never as "no password".
    @Test func keychainErrorIsNotMissing() {
        let description = GuestPasswordStoreError.keychain(-25293).errorDescription
        #expect(description?.contains("-25293") == true)
    }

    /// A status without a system message falls back to a localized "unknown error".
    @Test(.italian) func keychainErrorWithoutMessageIsLocalized() {
        #expect(GuestPasswordStoreError.keychainDescription(-25293, systemMessage: nil)
            == "Errore del Portachiavi -25293: errore sconosciuto")
        #expect(GuestPasswordStoreError.keychainDescription(-25293, systemMessage: "msg")
            == "Errore del Portachiavi -25293: msg")
    }

    /// A stored item that is not valid UTF-8, or that `GuestPassword` refuses, is an error: never
    /// "no password", never a silently repaired one.
    @Test func unusableItemIsAnError() throws {
        #expect(throws: GuestPasswordStoreError.unusableItem) {
            _ = try KeychainGuestPasswordStore.decode(Data([0x70, 0xFF, 0xFE, 0x77]) as CFTypeRef)
        }
        for refused in ["", "pass\nword", "nul\0byte", String(repeating: "a", count: 1024)] {
            #expect(throws: GuestPasswordStoreError.unusableItem) {
                _ = try KeychainGuestPasswordStore.decode(Data(refused.utf8) as CFTypeRef)
            }
        }
        #expect(throws: GuestPasswordStoreError.unusableItem) {
            _ = try KeychainGuestPasswordStore.decode(nil)
        }
        #expect(throws: GuestPasswordStoreError.unusableItem) {
            _ = try KeychainGuestPasswordStore.decode("not data" as CFString)
        }
        #expect(try KeychainGuestPasswordStore.decode(Data("pässwörd".utf8) as CFTypeRef) == GuestPassword("pässwörd"))
    }

    @Test(.italian) func unusableItemMessage() {
        #expect(GuestPasswordStoreError.unusableItem.errorDescription
            == "La password salvata per questa VM non si può usare: inseriscila di nuovo in Impostazioni › Agente della VM o con nido agent setup")
    }

    /// The same through the real Keychain: an item written by someone else with bytes that are no
    /// password.
    @Test(.enabled(if: keychainAvailable, "needs a login keychain the test process can write"))
    func keychainUnusableItemThrows() throws {
        let store = KeychainGuestPasswordStore(service: "\(testService).\(UUID().uuidString)")
        let id = UUID()
        defer { try? store.delete(vm: id) }
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: store.service,
            kSecAttrAccount as String: id.uuidString,
            kSecValueData as String: Data([0x61, 0xC3, 0x28]),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        #expect(SecItemAdd(add as CFDictionary, nil) == errSecSuccess)
        #expect(throws: GuestPasswordStoreError.unusableItem) { _ = try store.read(vm: id) }
        // Present, though unusable: `contains` does not read the data.
        #expect(try store.contains(vm: id))
    }
}
