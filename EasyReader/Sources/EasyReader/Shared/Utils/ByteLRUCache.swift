import Foundation

struct ByteLRUCache<Key: Hashable> {
    private struct Entry { let data: Data; let savedAt: Date; var tick: UInt64 }
    private var entries: [Key: Entry] = [:]
    private var tick: UInt64 = 0
    private(set) var byteCount = 0
    private(set) var count = 0
    let byteLimit: Int
    let countLimit: Int
    var ttl: TimeInterval = 3600

    mutating func value(for key: Key, now: Date = Date()) -> Data? {
        guard let entry = entries[key] else { return nil }
        guard now.timeIntervalSince(entry.savedAt) <= ttl else {
            entries.removeValue(forKey: key); byteCount -= entry.data.count; count = entries.count; return nil
        }
        let data = entry.data
        tick &+= 1; entries[key]?.tick = tick
        return data
    }
    mutating func insert(_ data: Data, for key: Key, now: Date = Date()) {
        if let previous = entries.removeValue(forKey: key) { byteCount -= previous.data.count }
        guard data.count <= byteLimit else { count = entries.count; return }
        tick &+= 1; entries[key] = Entry(data: data, savedAt: now, tick: tick); byteCount += data.count
        if byteCount <= byteLimit && entries.count <= countLimit { count = entries.count; return }
        for entry in entries.sorted(by: { $0.value.tick < $1.value.tick }) {
            guard byteCount > byteLimit || entries.count > countLimit else { break }
            byteCount -= entry.value.data.count; entries.removeValue(forKey: entry.key)
        }
        count = entries.count
    }
    mutating func clear() { entries.removeAll(); byteCount = 0; count = 0; tick = 0 }
}
