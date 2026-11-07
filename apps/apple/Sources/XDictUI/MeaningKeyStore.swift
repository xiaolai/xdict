import Foundation
import Security
import XDictBase

/// **Where the cloud endpoint's key lives** (ADR-0021 d.3): the Keychain, and nowhere else. XDict is the only writer; the
/// key never enters a defaults database, the reader's sync, or a log. The store is a seam so the tests never touch the
/// reader's Keychain.
public protocol MeaningKeyStore {
    /// The stored key, or nil when none is stored.
    func key() -> String?
    /// Replaces the stored key. Throws when the Keychain refuses (locked, or no access).
    func save(_ key: String) throws
    /// Deletes the stored key. Throws when the Keychain refuses; `errSecItemNotFound` is success — nothing to remove.
    func remove() throws
}

/// The Keychain store: one generic password, addressed by the app's service and a fixed account.
public struct KeychainKeyStore: MeaningKeyStore {
    public let service: String
    public let account: String

    public init(service: String = XDictIdentity.app + ".meaning", account: String = "cloud-endpoint") {
        self.service = service
        self.account = account
    }

    public func key() -> String? {
        var query = base
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// **Update first, add only where there is nothing to update** (L4): deciding by `key()` read a stored item that
    /// could not be read (a locked Keychain, bytes that are not UTF-8) as absent, and the add then failed as a
    /// duplicate. The accessibility class goes with the update too, so an older item is brought to it.
    public func save(_ key: String) throws {
        let data = Data(key.utf8)
        let changes: [String: Any] = [kSecValueData as String: data,
                                      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock]
        switch Self.afterUpdate(SecItemUpdate(base as CFDictionary, changes as CFDictionary)) {
        case .done:
            return
        case .refuse(let status):
            throw MeaningKeyError(status: status)
        case .add:
            var item = base
            item.merge(changes) { _, new in new }
            let status = SecItemAdd(item as CFDictionary, nil)
            guard status == errSecSuccess else { throw MeaningKeyError(status: status) }
        }
    }

    /// What a save does after `SecItemUpdate` answered `status`.
    public enum SaveStep: Equatable, Sendable {
        /// The stored key was replaced.
        case done
        /// No key is stored: add one.
        case add
        /// The Keychain refused; the status is surfaced, never retried as an add.
        case refuse(OSStatus)
    }

    /// **The update's status, decided**: success is done, `errSecItemNotFound` is the one status that means add, and
    /// every other status is the Keychain's refusal, said to the reader.
    public static func afterUpdate(_ status: OSStatus) -> SaveStep {
        switch status {
        case errSecSuccess: .done
        case errSecItemNotFound: .add
        default: .refuse(status)
        }
    }

    public func remove() throws {
        let status = SecItemDelete(base as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw MeaningKeyError(status: status) }
    }

    private var base: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }
}

/// The Keychain's refusal, as a value: the status is what `SecItem` returned and names nothing of the key.
public struct MeaningKeyError: Error, Equatable, Sendable {
    public let status: OSStatus

    public init(status: OSStatus) {
        self.status = status
    }
}
