import Foundation
import Security

struct NearbyKeychain {
    static let service = "local.liferecord.nearby.v1"
    static func read() throws -> NearbyVault {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "identity-and-peers", kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { let vault = NearbyVault(); try save(vault); return vault }
        guard status == errSecSuccess, let data = result as? Data else { throw NearbyError.keychain(status) }
        guard let vault = try? JSONDecoder().decode(NearbyVault.self, from: data), UUID(uuidString: vault.serviceID) != nil, vault.credentials.allSatisfy({ $0.key.count == 32 }) else { throw NearbyError.keychain(errSecDecode) }
        return vault
    }
    static func save(_ vault: NearbyVault) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "identity-and-peers"]
        let attributes: [String: Any] = [kSecValueData as String: try JSONEncoder().encode(vault), kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var addition = query; attributes.forEach { addition[$0] = $1 }
            let added = SecItemAdd(addition as CFDictionary, nil)
            guard added == errSecSuccess else { throw NearbyError.keychain(added) }
        } else if status != errSecSuccess { throw NearbyError.keychain(status) }
    }
}
