import Foundation
import Security

/// Keychain persistence for `DeviceActivationRecord` — same
/// `kSecClassGenericPassword`-as-one-JSON-blob pattern as
/// `LicenseKeychainStore`, deliberately under a DIFFERENT service string so
/// wiping/quarantining one store can never touch the other. See
/// `DeviceActivationRecord`'s doc comment for why this is a single store
/// with no UserDefaults mirror, unlike the trial/license layer.
enum DeviceActivationKeychainStore {
    private static let service = "com.seb.Peek3D.activation"
    private static let account = "device-activation-record"

    /// Never throws, never surfaces "corrupted" to callers as something to
    /// react to specially — an unreadable or absent item both fold into
    /// `.empty`, exactly like `LicenseStore`'s "never fails" contract for
    /// the trial/license layer. Losing this record only means re-activating
    /// from scratch, so there is no quarantine-and-preserve step here the
    /// way `LicenseKeychainStore` has for the higher-stakes trial record.
    static func load() -> DeviceActivationRecord {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            return .empty
        }
        return (try? JSONDecoder().decode(DeviceActivationRecord.self, from: data)) ?? .empty
    }

    @discardableResult
    static func save(_ record: DeviceActivationRecord) -> Bool {
        guard let data = try? JSONEncoder().encode(record) else { return false }

        var addQuery = baseQuery()
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus == errSecSuccess { return true }
        if addStatus == errSecDuplicateItem {
            let updateQuery = baseQuery()
            let attributes: [String: Any] = [kSecValueData as String: data]
            return SecItemUpdate(updateQuery as CFDictionary, attributes as CFDictionary) == errSecSuccess
        }
        return false
    }

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    #if DEBUG
    /// Full wipe — "fresh install" for `LicenseActivationSelfTest` and
    /// manual QA, same role as `LicenseKeychainStore.debugDeleteAll()`.
    static func debugDeleteAll() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        SecItemDelete(query as CFDictionary)
    }
    #endif
}
