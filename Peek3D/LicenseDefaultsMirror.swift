import Foundation

/// UserDefaults mirror of the Keychain entitlement record. NOT authoritative
/// — see `LicenseStore` for the merge rule. Exists to survive three failure
/// modes the Keychain alone doesn't cover: detecting partial deletion
/// (present in one, absent in the other), not locking out a paying customer
/// when the Keychain is unreadable, and surviving a Team ID change.
enum LicenseDefaultsMirror {
    private static let key = "com.seb.Peek3D.entitlementMirror"

    enum ReadResult {
        case absent
        case record(LicenseRecord)
        case corrupted
    }

    static func read() -> ReadResult {
        guard let data = UserDefaults.standard.data(forKey: key) else { return .absent }
        guard let record = try? JSONDecoder().decode(LicenseRecord.self, from: data) else {
            return .corrupted
        }
        return .record(record)
    }

    static func write(_ record: LicenseRecord) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    /// Moves unreadable bytes to a timestamped backup key instead of ever
    /// discarding them — same "never destroy state we failed to interpret"
    /// rule as `LicenseKeychainStore.quarantineUnreadable()`. The bytes are
    /// copied to the backup key BEFORE the normal key is cleared, so
    /// nothing is lost even though the normal key becomes readable-absent
    /// afterward.
    static func quarantineUnreadable() {
        guard let data = UserDefaults.standard.data(forKey: key) else { return }
        let backupKey = "\(key).corrupted.\(Int(Date().timeIntervalSince1970))"
        UserDefaults.standard.set(data, forKey: backupKey)
        UserDefaults.standard.removeObject(forKey: key)
    }

    #if DEBUG
    /// Writes non-JSON bytes directly under the mirror key, bypassing
    /// `write(_:)` — used only by `LicenseDebugHarness` to manufacture a
    /// "corrupted" state for testing. Never reachable outside a DEBUG build.
    static func debugWriteRawGarbage() {
        UserDefaults.standard.set(Data([0xDE, 0xAD, 0xBE, 0xEF]), forKey: key)
    }

    /// Full wipe of the mirror key and every quarantined backup — an
    /// explicit "reset to fresh install" for `LicenseDebugHarness`.
    static func debugDeleteAll() {
        let defaults = UserDefaults.standard
        let prefix = "\(key).corrupted."
        for existingKey in defaults.dictionaryRepresentation().keys where existingKey == key || existingKey.hasPrefix(prefix) {
            defaults.removeObject(forKey: existingKey)
        }
    }
    #endif
}
