import Foundation
import os

public final class SearchCache {
    private struct Entry {
        let result: SearchResult
        let insertedAt: Date
    }

    private let maxEntries: Int, maxItems: Int
    private let clock: () -> Date
    private var lock = os_unfair_lock_s()
    // Oldest first; a small bounded array avoids a second set of key allocations.
    private var entries: [Entry] = []
    private var itemCount = 0

    public init(maxEntries: Int = 32, maxItems: Int = 4_000_000, clock: @escaping () -> Date = { Date() }) {
        self.maxEntries = max(0, maxEntries); self.maxItems = max(0, maxItems)
        self.clock = clock
    }

    public func lookup(query: Query, options: SearchOptions, store: IndexStore) -> SearchResult? {
        guard !query.isTimeDependent else { return nil }
        return store.read {
            os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
            let now = clock()
            discardExpired(now: now)
            discardStale(store: store)
            guard let i = entries.firstIndex(where: { matches($0.result, query: query, options: options, store: store) }) else { return nil }
            let entry = entries.remove(at: i)
            entries.append(entry)
            return entry.result
        }
    }

    public func insert(_ result: SearchResult) {
        guard !result.query.isTimeDependent else { return }
        result.store.read {
            os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
            let now = clock()
            discardExpired(now: now)
            discardStale(store: result.store)
            guard result.storeVersion == result.store.version, maxEntries > 0, result.items.count <= maxItems else { return }
            if let i = entries.firstIndex(where: { matches($0.result, query: result.query, options: result.options, store: result.store) }) {
                itemCount -= entries.remove(at: i).result.items.count
            }
            entries.append(Entry(result: result, insertedAt: now)); itemCount += result.items.count
            while entries.count > maxEntries || itemCount > maxItems {
                itemCount -= entries.removeFirst().result.items.count
            }
        }
    }

    public func removeAll() {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        entries.removeAll(keepingCapacity: true); itemCount = 0
    }

    private func matches(_ result: SearchResult, query: Query, options: SearchOptions, store: IndexStore) -> Bool {
        result.store === store && result.storeVersion == store.version && result.query.raw == query.raw &&
        result.options.kind == options.kind && result.options.pinyin == options.pinyin &&
        result.options.sort == options.sort && result.options.ascending == options.ascending
    }

    private func discardStale(store: IndexStore) {
        entries.removeAll { entry in
            let result = entry.result
            if result.store === store && result.storeVersion != store.version {
                itemCount -= result.items.count
                return true
            }
            return false
        }
    }

    private func discardExpired(now: Date) {
        entries.removeAll { entry in
            if now.timeIntervalSince(entry.insertedAt) > 600 {
                itemCount -= entry.result.items.count
                return true
            }
            return false
        }
    }
}
