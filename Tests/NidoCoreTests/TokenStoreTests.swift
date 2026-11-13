// SPDX-License-Identifier: Apache-2.0
import Foundation
import Security
import Testing
@testable import NidoCore

/// True when this process can write the login keychain (not the case without a user session,
/// e.g. some CI runners): checked with a throwaway item.
private let keychainAvailable: Bool = {
    let store = KeychainTokenStore(service: "Nido Hugging Face Tests probe \(UUID().uuidString)")
    guard let token = HFToken("hf_probe") else { return false }
    do {
        try store.save(token)
        try store.delete()
        return true
    } catch {
        return false
    }
}()

@Suite struct TokenStoreTests {
    @Test(.enabled(if: keychainAvailable, "needs a login keychain the test process can write"))
    func keychainRoundTrip() throws {
        let store = KeychainTokenStore(service: "Nido Hugging Face Tests \(UUID().uuidString)")
        defer { try? store.delete() }
        #expect(try store.read() == nil)
        let first = try #require(HFToken("hf_first0123456789"))
        try store.save(first)
        #expect(try store.read() == first)
        // Saving again replaces it.
        let second = try #require(HFToken("hf_second0123456789"))
        try store.save(second)
        #expect(try store.read() == second)
        try store.delete()
        #expect(try store.read() == nil)
        // Deleting what is not there is fine.
        try store.delete()
    }

    @Test func defaultKeychainItem() {
        let store = KeychainTokenStore()
        #expect(store.service == "Nido Hugging Face")
        #expect(store.account == "default")
        #expect(KeychainTokenStore.defaultService == "Nido Hugging Face")
    }

    @Test func tokenDescriptionRedacted() throws {
        let token = try #require(HFToken("  \(testSecret)\n"))
        #expect(token.description == "HFToken(redacted)")
        #expect(token.debugDescription == "HFToken(redacted)")
        #expect("\(token)" == "HFToken(redacted)")
        #expect(String(reflecting: token) == "HFToken(redacted)")
        var dumped = ""
        dump(token, to: &dumped)
        #expect(!dumped.contains(testSecret))
        #expect(dumped.contains("HFToken(redacted)"))
        #expect(!"\([token])".contains(testSecret))
        #expect(!"\(Optional(token) as Any)".contains(testSecret))
        // Whitespace around is dropped; the value itself is kept.
        #expect(token == HFToken(testSecret))

        // Nothing that could break the Authorization header.
        for bad in ["", "   ", "hf_a b", "hf_a\r\nX-Evil: 1", "hf_\u{7F}", "hf_è", String(repeating: "a", count: 1025)] {
            #expect(HFToken(bad) == nil, "\(bad.debugDescription)")
        }
        let error = TokenStoreError.keychain(-25300)
        #expect(!"\(error)".isEmpty)
    }
}
