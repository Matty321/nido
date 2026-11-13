// SPDX-License-Identifier: Apache-2.0
import Foundation
import Security

/// A Hugging Face access token. Its value never shows in `description`, `debugDescription`,
/// `dump` or string interpolation (all print `HFToken(redacted)`); it is not `Codable`, so it
/// cannot slip into a JSON file either. Only `URLSessionRouterClient` and `KeychainTokenStore`
/// read `value`.
public struct HFToken: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible,
    CustomReflectable
{
    /// Longest accepted token.
    public static let maxLength = 1024

    let value: String

    /// The token without surrounding whitespace; nil when empty, longer than `maxLength` or
    /// containing anything but visible ASCII (no space or control character can reach the
    /// `Authorization` header).
    public init?(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...Self.maxLength).contains(trimmed.utf8.count),
            trimmed.utf8.allSatisfy({ (0x21...0x7E).contains($0) })
        else { return nil }
        value = trimmed
    }

    public var description: String { "HFToken(redacted)" }
    public var debugDescription: String { "HFToken(redacted)" }
    public var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }
}

/// Where the Mac keeps the one Hugging Face token of Nido.
public protocol TokenStore: Sendable {
    /// The stored token, or nil when there is none.
    func read() throws -> HFToken?
    /// Stores `token`, replacing the previous one.
    func save(_ token: HFToken) throws
    /// Removes the token; removing a missing token is not an error.
    func delete() throws
}

/// A Keychain failure: only the `OSStatus`, never the token.
public enum TokenStoreError: Error, Equatable, Sendable, CustomStringConvertible {
    case keychain(OSStatus)

    public var description: String {
        switch self {
        case .keychain(let status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown"
            return "Keychain error \(status): \(message)"
        }
    }
}

/// The token in the login Keychain: a generic password, service `Nido Hugging Face`, account
/// `default`, accessible only while the Mac is unlocked and never migrated to another device.
public struct KeychainTokenStore: TokenStore {
    public static let defaultService = "Nido Hugging Face"
    public static let defaultAccount = "default"

    public let service: String
    public let account: String

    /// `service` other than the default is for tests only.
    public init(service: String = KeychainTokenStore.defaultService, account: String = KeychainTokenStore.defaultAccount) {
        self.service = service
        self.account = account
    }

    private var itemQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public func read() throws -> HFToken? {
        var query = itemQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw TokenStoreError.keychain(status) }
        guard let data = result as? Data else { return nil }
        // A value that is not a valid token (edited by hand) counts as no token.
        return HFToken(String(decoding: data, as: UTF8.self))
    }

    public func save(_ token: HFToken) throws {
        let data = Data(token.value.utf8)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let updated = SecItemUpdate(itemQuery as CFDictionary, attributes as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else { throw TokenStoreError.keychain(updated) }
        var add = itemQuery
        add.merge(attributes) { _, new in new }
        add[kSecAttrLabel as String] = service
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw TokenStoreError.keychain(status) }
    }

    public func delete() throws {
        let status = SecItemDelete(itemQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw TokenStoreError.keychain(status) }
    }
}
