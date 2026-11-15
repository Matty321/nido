// SPDX-License-Identifier: Apache-2.0
import Foundation
import Security

/// The password of the account of a macOS guest, as the user chose it in the wizard. Its value
/// never shows in `description`, `debugDescription`, `dump` or string interpolation; it is not
/// `Codable`, so it cannot slip into a JSON file either.
public struct GuestPassword: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible,
    CustomReflectable
{
    public let value: String

    /// The most UTF-8 bytes a password may have: ssh's askpass reader keeps at most 1023.
    public static let maxBytes = 1023

    /// Nil when `value` is empty (no password is no account), holds a line break or NUL, or is
    /// longer than `maxBytes`: ssh's askpass reader would cut it there and send another password.
    public init?(_ value: String) {
        guard !value.isEmpty, value.utf8.count <= Self.maxBytes,
            !value.utf8.contains(where: { $0 == 0x0A || $0 == 0x0D || $0 == 0x00 })
        else { return nil }
        self.value = value
    }

    /// The characters of a generated password: lowercase letters and digits that read and type
    /// the same everywhere (no y/z, swapped between QWERTY and QWERTZ; no 0/o/1/l/i).
    public static let generatedAlphabet = Array("abcdefghjkmnpqrstuvwx23456789")

    /// A new random password: 4 groups of 5 characters of `generatedAlphabet` joined by "-"
    /// (about 97 bits), from `SystemRandomNumberGenerator`.
    public static func generate() -> GuestPassword {
        var generator = SystemRandomNumberGenerator()
        let groups = (0..<4).map { _ in
            String((0..<5).map { _ in generatedAlphabet.randomElement(using: &generator)! })
        }
        return GuestPassword(groups.joined(separator: "-"))!
    }

    public var description: String { "<redacted>" }
    public var debugDescription: String { "<redacted>" }
    public var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }
}

/// Where the Mac keeps the guest account password of each VM (one item per VM id).
public protocol GuestPasswordStore: Sendable {
    /// The stored password, or nil when there is none.
    func read(vm: UUID) throws -> GuestPassword?
    /// Whether a password is stored, without reading it (the Keychain asks no confirmation for
    /// that).
    func contains(vm: UUID) throws -> Bool
    /// Stores `password`, replacing the previous one.
    func save(_ password: GuestPassword, vm: UUID) throws
    /// Removes the password; removing a missing one is not an error.
    func delete(vm: UUID) throws
}

extension GuestPasswordStore {
    /// By reading the password: for stores without a cheaper way.
    public func contains(vm: UUID) throws -> Bool { try read(vm: vm) != nil }
}

/// A Keychain failure: only the `OSStatus`, never the password.
public enum GuestPasswordStoreError: Error, Equatable, Sendable, LocalizedError {
    case keychain(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .keychain(let status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown"
            return L10n.string("Keychain error \(String(status)): \(message)")
        }
    }
}

/// The passwords in the login Keychain: generic passwords, one service for all VMs and the VM id
/// as account, accessible only while the Mac is unlocked and never migrated to another device.
public struct KeychainGuestPasswordStore: GuestPasswordStore {
    public static let defaultService = "io.gitlab.pichierri.Nido.guest-account"

    public let service: String

    /// `service` other than the default is for tests only.
    public init(service: String = KeychainGuestPasswordStore.defaultService) {
        self.service = service
    }

    private func itemQuery(_ vm: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: vm.uuidString,
        ]
    }

    public func read(vm: UUID) throws -> GuestPassword? {
        var query = itemQuery(vm)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw GuestPasswordStoreError.keychain(status) }
        guard let data = result as? Data else { return nil }
        return GuestPassword(String(decoding: data, as: UTF8.self))
    }

    /// Asks only for the item's attributes, never its data: no "allow" prompt of the Keychain.
    public func contains(vm: UUID) throws -> Bool {
        var query = itemQuery(vm)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess else { throw GuestPasswordStoreError.keychain(status) }
        return true
    }

    public func save(_ password: GuestPassword, vm: UUID) throws {
        let attributes: [String: Any] = [
            kSecValueData as String: Data(password.value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let updated = SecItemUpdate(itemQuery(vm) as CFDictionary, attributes as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else { throw GuestPasswordStoreError.keychain(updated) }
        var add = itemQuery(vm)
        add.merge(attributes) { _, new in new }
        add[kSecAttrLabel as String] = "Nido VM account"
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw GuestPasswordStoreError.keychain(status) }
    }

    public func delete(vm: UUID) throws {
        let status = SecItemDelete(itemQuery(vm) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw GuestPasswordStoreError.keychain(status)
        }
    }
}

/// An in-memory store: the fake for tests and DEBUG builds.
public final class MemoryGuestPasswordStore: GuestPasswordStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [UUID: GuestPassword] = [:]

    public init() {}

    public func read(vm: UUID) throws -> GuestPassword? {
        lock.withLock { items[vm] }
    }

    public func contains(vm: UUID) throws -> Bool {
        lock.withLock { items[vm] != nil }
    }

    public func save(_ password: GuestPassword, vm: UUID) throws {
        lock.withLock { items[vm] = password }
    }

    public func delete(vm: UUID) throws {
        lock.withLock { items[vm] = nil }
    }
}
