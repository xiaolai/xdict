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

    public func save(_ key: String) throws {
        let data = Data(key.utf8)
        let status: OSStatus
        if self.key() == nil {
            var item = base
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(item as CFDictionary, nil)
        } else {
            status = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        }
        guard status == errSecSuccess else { throw MeaningKeyError(status: status) }
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
