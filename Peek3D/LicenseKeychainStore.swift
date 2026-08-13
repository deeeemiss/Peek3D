import Foundation
import Security

/// Owns the single Keychain item that is the authoritative store for
/// Peek3D's entitlement record: one `kSecClassGenericPassword` item, written
/// atomically as one JSON blob (see `LicenseRecord`).
enum LicenseKeychainStore {
    /// Written by hand, NOT derived from `Bundle.main.bundleIdentifier`:
    /// this app was renamed once already (GLBViewer -> Peek3D) and left a
    /// dead container on disk. A service string derived from the bundle id
    /// would orphan every customer's license the next time that happens.
    private static let service = "com.seb.Peek3D.entitlement"
    private static let account = "entitlement-record"

    enum ReadResult {
        /// No item found under `service`/`account` — never treated as an
        /// error, just "nothing persisted yet".
        case absent
        /// Found and decoded successfully.
        case record(LicenseRecord)
        /// Found, but the bytes didn't decode as a `LicenseRecord`. This
        /// call leaves the item untouched — callers that want to recover
        /// MUST call `quarantineUnreadable()` explicitly, so a transient
        /// decode failure can never destroy a paying customer's license by
        /// having something blindly `write()` over it.
        case corrupted
    }

    static func read() -> ReadResult {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            return .absent
        }
        guard let record = try? JSONDecoder().decode(LicenseRecord.self, from: data) else {
            return .corrupted
        }
        return .record(record)
    }

    /// Overwrites (or creates) the single entitlement item with `record`.
    /// If a prior `read()` returned `.corrupted`, callers must have already
    /// called `quarantineUnreadable()` first — this function doesn't check,
    /// it just adds-or-updates the item at `service`/`account`.
    @discardableResult
    static func write(_ record: LicenseRecord) -> Bool {
        guard let data = try? JSONEncoder().encode(record) else { return false }
        return writeRaw(data)
    }

    /// Moves an unreadable item out of the way by renaming its
    /// `kSecAttrAccount` to a timestamped quarantine value, WITHOUT deleting
    /// or touching its bytes — a transient decode failure must never
    /// destroy a real license. After this call `read()` reports `.absent`,
    /// so the caller can safely treat this as "no state" and eventually
    /// `write()` a fresh record under the normal account.
    static func quarantineUnreadable() {
        let query = baseQuery()
        let quarantineAccount = "entitlement-record.corrupted.\(Int(Date().timeIntervalSince1970))"
        let attributes: [String: Any] = [kSecAttrAccount as String: quarantineAccount]
        SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    }

    private static func writeRaw(_ data: Data) -> Bool {
        var addQuery = baseQuery()
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        // Deliberately absent: kSecAttrSynchronizable (no iCloud sync — a
        // settled product decision) and kSecUseDataProtectionKeychain (the
        // file-based Keychain survives a signing-identity change with a
        // recoverable prompt instead of silently losing the item, and needs
        // no entitlement).

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
    /// Writes non-JSON bytes directly to the item, bypassing `write(_:)` —
    /// used only by `LicenseDebugHarness` to manufacture a "corrupted"
    /// state for testing. Never reachable outside a DEBUG build.
    static func debugWriteRawGarbage() {
        _ = writeRaw(Data([0xDE, 0xAD, 0xBE, 0xEF]))
    }

    /// Full wipe of every item this store has ever written, including
    /// quarantined/corrupted copies. An explicit "reset to fresh install"
    /// for `LicenseDebugHarness` — NOT the same operation as
    /// `quarantineUnreadable()`, which intentionally never deletes.
    static func debugDeleteAll() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        SecItemDelete(query as CFDictionary)
    }
    #endif
}
