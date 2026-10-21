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

    static func claimWidgetAction(_ id: UUID) throws {
        var claim = query(id.uuidString)
        claim[kSecAttrService as String] = "PrintProgress.widget-action-claims"
        claim[kSecValueData as String] = Data([1])
        claim[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(claim as CFDictionary, nil)
        if status == errSecDuplicateItem { throw PrinterControlError.busy }
        guard status == errSecSuccess else { throw PrinterError.keychain(status) }
        // Claims contain no connection details. Remove old receipts in this
        // separate service without ever enumerating saved printer credentials.
        var listing = query("")
        listing.removeValue(forKey: kSecAttrAccount as String)
        listing[kSecAttrService as String] = "PrintProgress.widget-action-claims"
        listing[kSecReturnAttributes as String] = true
        listing[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        if SecItemCopyMatching(listing as CFDictionary, &result) == errSecSuccess,
           let items = result as? [[String: Any]] {
            for item in items {
                if let created = item[kSecAttrCreationDate as String] as? Date,
                   created < Date().addingTimeInterval(-7 * 86400),
                   let account = item[kSecAttrAccount as String] as? String {
                    var old = query(account)
                    old[kSecAttrService as String] = "PrintProgress.widget-action-claims"
                    SecItemDelete(old as CFDictionary)
                }
            }
        }
    }
}
