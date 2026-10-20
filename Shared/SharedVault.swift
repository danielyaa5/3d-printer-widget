import Foundation
import Security

enum SharedVault {
    private static let service = "PrintProgress.shared"
    private static func query(_ account: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
        if let group = Bundle.main.object(forInfoDictionaryKey: "PrintProgressKeychainGroup") as? String,
           !group.isEmpty, !group.contains("$(") {
            query[kSecAttrAccessGroup as String] = group
        }
        return query
    }
    static func read<Value: Decodable>(_ type: Value.Type, account: String) throws -> Value? {
        var query = query(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw PrinterError.keychain(status) }
        guard let data = item as? Data else { throw PrinterError.invalidResponse }
        return try JSONDecoder().decode(type, from: data)
    }
    static func write<Value: Encodable>(_ value: Value, account: String) throws {
        let data = try JSONEncoder().encode(value)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let query = query(account)
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { $1 } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw PrinterError.keychain(status) }
    }
    static func delete(account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw PrinterError.keychain(status) }
    }
    static func profiles() throws -> [PrinterProfile] { try read([PrinterProfile].self, account: "printers") ?? [] }
    static func saveProfiles(_ profiles: [PrinterProfile]) throws { try write(profiles, account: "printers") }
    static func snapshot(for id: UUID) throws -> PrinterSnapshot? {
        try read(PrinterSnapshot.self, account: "snapshot.\(id.uuidString)")
    }
    static func saveSnapshot(_ snapshot: PrinterSnapshot) throws {
        try write(snapshot, account: "snapshot.\(snapshot.id.uuidString)")
    }
}
