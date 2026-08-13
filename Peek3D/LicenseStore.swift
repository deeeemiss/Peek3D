import Foundation

/// The trial/license persistence layer: merges the Keychain (authoritative)
/// and its UserDefaults mirror (non-authoritative) on every read, repairs
/// whichever side drifted, and performs the anti-overcount-safe increment
/// when a new file is counted against the trial.
final class LicenseStore {

    /// Loads both stores, merges them, and repairs whichever side is
    /// behind. Never fails — an absent or corrupted store on either side
    /// folds into "trial, zero files seen" rather than surfacing as an
    /// error (see `LicenseStatus`, which has no `.error` case by design).
    func loadMergedRecord() -> LicenseRecord {
        let keychainOutcome = readKeychain()
        let defaultsOutcome = readDefaults()
        let merged = Self.merge(keychainOutcome, defaultsOutcome)
        repairIfNeeded(merged: merged, keychainOutcome: keychainOutcome, defaultsOutcome: defaultsOutcome)
        return merged
    }

    /// Call ONLY after `ModelLoader` has returned a valid model for `url` —
    /// never for a failed load. Safe to call for a window macOS restored
    /// automatically: if `url`'s hash is already known, this is a no-op on
    /// the count (see the dedup check below), exactly matching "reopening a
    /// seen file never consumes a trial slot".
    ///
    /// Rereads both stores immediately before touching the counter — stale
    /// in-memory state must never cause an overcount — then applies
    /// `max(memoria, portachiavi, defaults) + 1`. That formula is
    /// implemented here as a UNION of every hash set this process can see
    /// (in-memory `currentRecord` + fresh Keychain + fresh UserDefaults),
    /// which reduces to exactly that arithmetic whenever the three stores
    /// are simple prefixes/copies of one another — the normal case, since
    /// every successful call writes all of them synchronously — and can
    /// only ever be safer (never overcounts) when they've drifted, per
    /// "fra sottoconteggio e sovraconteggio, preferisci sempre il
    /// sottoconteggio".
    @discardableResult
    func recordFileOpened(_ url: URL, currentRecord: LicenseRecord) -> LicenseRecord {
        let hash = FileIdentityHasher.hash(for: url)

        let keychainOutcome = readKeychain()
        let defaultsOutcome = readDefaults()
        let freshMerged = Self.merge(keychainOutcome, defaultsOutcome)

        var hashes = Set(freshMerged.seenFileHashes)
        hashes.formUnion(currentRecord.seenFileHashes)
        let licenseText = freshMerged.licenseKeyText ?? currentRecord.licenseKeyText

        // Already counted — a genuine reopen, or macOS's automatic window
        // restoration replaying a file this trial already paid for. Never
        // increment either way; inserting into a set that already has the
        // hash is naturally a no-op.
        hashes.insert(hash)

        let record = LicenseRecord(seenFileHashes: Array(hashes), licenseKeyText: licenseText)
        persist(record)
        return record
    }

    /// Persists a license key string the user just entered. The paywall UI
    /// (out of scope here) is the only expected caller.
    @discardableResult
    func saveLicenseKeyText(_ text: String) -> LicenseRecord {
        var merged = loadMergedRecord()
        merged.licenseKeyText = text
        persist(merged)
        return merged
    }

    // MARK: - Merge

    private enum StoreOutcome {
        case absent
        case record(LicenseRecord)
        case corrupted
    }

    /// "Il valore più avanzato vince": a licensed record beats any trial
    /// record (obtaining a license is strictly more advanced than any trial
    /// state); the seen-file-hash sets union together (never fewer distinct
    /// files than either side alone knew about — the whole point of
    /// tracking distinct files is to never forget one). `.absent`/
    /// `.corrupted` contribute nothing to the merge, which is exactly
    /// "restore the survivor" when only one side has real data.
    private static func merge(_ a: StoreOutcome, _ b: StoreOutcome) -> LicenseRecord {
        let recordA = record(from: a)
        let recordB = record(from: b)

        let licenseText = recordA.licenseKeyText ?? recordB.licenseKeyText
        var hashes = Set(recordA.seenFileHashes)
        hashes.formUnion(recordB.seenFileHashes)
        return LicenseRecord(seenFileHashes: Array(hashes), licenseKeyText: licenseText)
    }

    private static func record(from outcome: StoreOutcome) -> LicenseRecord {
        if case .record(let record) = outcome { return record }
        return .empty
    }

    // MARK: - Store access + repair

    private func readKeychain() -> StoreOutcome {
        switch LicenseKeychainStore.read() {
        case .absent: return .absent
        case .record(let record): return .record(record)
        case .corrupted:
            // Never delete what we failed to interpret — quarantine it
            // under a renamed account and treat this read as absent.
            LicenseKeychainStore.quarantineUnreadable()
            return .corrupted
        }
    }

    private func readDefaults() -> StoreOutcome {
        switch LicenseDefaultsMirror.read() {
        case .absent: return .absent
        case .record(let record): return .record(record)
        case .corrupted:
            LicenseDefaultsMirror.quarantineUnreadable()
            return .corrupted
        }
    }

    /// If either side didn't already equal the merged result (missing,
    /// corrupted-and-quarantined, or simply behind), rewrite it — this is
    /// the "restore the survivor" / drift-repair step.
    private func repairIfNeeded(merged: LicenseRecord, keychainOutcome: StoreOutcome, defaultsOutcome: StoreOutcome) {
        if Self.record(from: keychainOutcome) != merged {
            LicenseKeychainStore.write(merged)
        }
        if Self.record(from: defaultsOutcome) != merged {
            LicenseDefaultsMirror.write(merged)
        }
    }

    private func persist(_ record: LicenseRecord) {
        LicenseKeychainStore.write(record)
        LicenseDefaultsMirror.write(record)
    }

    #if DEBUG
    /// Overwrites both stores directly with `record`, bypassing merge —
    /// `LicenseDebugHarness`'s way of forcing an arbitrary starting state.
    func debugForceRecord(_ record: LicenseRecord) {
        LicenseKeychainStore.write(record)
        LicenseDefaultsMirror.write(record)
    }

    /// Makes both stores hold undecodable bytes, so the next read exercises
    /// the real corruption-handling path (quarantine + fall back to trial)
    /// end to end.
    func debugForceCorrupted() {
        LicenseKeychainStore.debugWriteRawGarbage()
        LicenseDefaultsMirror.debugWriteRawGarbage()
    }

    /// Wipes both stores entirely — "fresh install" for testing.
    func debugReset() {
        LicenseKeychainStore.debugDeleteAll()
        LicenseDefaultsMirror.debugDeleteAll()
    }
    #endif
}
