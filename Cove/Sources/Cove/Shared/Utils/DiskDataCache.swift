import Foundation

/// Index once per process; writes update byte totals instead of rescanning the directory.
actor DiskDataCache {
    private struct Entry { let path: String; let bytes: Int; let savedAt: Date; var accessedAt: Date }
    let root: URL
    private let suffix: String
    private let byteLimit: Int
    private let entryByteLimit: Int
    private let countLimit: Int
    private let ttl: TimeInterval
    private var entries: [String: Entry] = [:]
    private var indexed = false
    private var bytes = 0
    private(set) var scanCount = 0

    init(root: URL, suffix: String, byteLimit: Int, countLimit: Int = 10_000, ttl: TimeInterval, entryByteLimit: Int? = nil) {
        self.entryByteLimit = min(byteLimit, entryByteLimit ?? byteLimit)
        self.root = root; self.suffix = suffix; self.byteLimit = byteLimit; self.countLimit = countLimit; self.ttl = ttl
    }
    private func file(_ key: String) -> URL? {
        guard !key.isEmpty, key.allSatisfy({ $0.isHexDigit && $0.isASCII }) else { return nil }
        return try? ReaderContainedPath.resolve(key + suffix, under: root)
    }
    private func index(now: Date) {
        guard !indexed else { return }
        indexed = true; scanCount += 1
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys)) else { return }
        for case let url as URL in enumerator {
            guard let value = try? url.resourceValues(forKeys: keys), value.isRegularFile == true, value.isSymbolicLink != true,
                  url.path.hasPrefix(root.path + "/") else { continue }
            let relative = String(url.path.dropFirst(root.path.count + 1))
            guard (try? ReaderContainedPath.resolve(relative, under: root)) != nil else { continue }
            let stem = String(url.lastPathComponent.dropLast(min(suffix.count, url.lastPathComponent.count)))
            let key = !relative.contains("/") && relative.hasSuffix(suffix) && file(stem) != nil ? stem : "legacy:" + relative
            let saved = value.contentModificationDate ?? .distantPast
            entries[key] = Entry(path: relative, bytes: value.fileSize ?? 0, savedAt: saved, accessedAt: saved)
            bytes += value.fileSize ?? 0
        }
        prune(now: now)
    }
    func load(_ key: String, now: Date = Date()) -> Data? {
        index(now: now)
        guard let entry = entries[key], now.timeIntervalSince(entry.savedAt) <= ttl, let url = file(key),
              let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= entryByteLimit,
              let data = try? Data(contentsOf: url), data.count <= entryByteLimit else {
            remove(key); return nil
        }
        entries[key]?.accessedAt = now
        return data
    }
    func store(_ data: Data, for key: String, now: Date = Date()) {
        guard !Task.isCancelled else { return }
        index(now: now)
        guard data.count <= entryByteLimit, let url = file(key) else { return }
        do {
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: url.path)
            bytes -= entries[key]?.bytes ?? 0
            entries[key] = Entry(path: key + suffix, bytes: data.count, savedAt: now, accessedAt: now)
            bytes += data.count
            prune(now: now)
        } catch { /* Cache failures do not block displaying the decoded resource. */ }
    }
    private func remove(_ key: String) {
        guard let entry = entries.removeValue(forKey: key) else { return }
        bytes -= entry.bytes
        if let url = try? ReaderContainedPath.resolve(entry.path, under: root) { try? FileManager.default.removeItem(at: url) }
    }
    private func prune(now: Date) {
        for (key, entry) in entries where now.timeIntervalSince(entry.savedAt) > ttl || entry.bytes > entryByteLimit { remove(key) }
        guard bytes > byteLimit || entries.count > countLimit else { return }
        for entry in entries.sorted(by: { $0.value.accessedAt < $1.value.accessedAt }) {
            guard bytes > byteLimit || entries.count > countLimit else { break }
            remove(entry.key)
        }
    }
    func usageBytes() -> Int { let now = Date(); index(now: now); prune(now: now); return bytes }
    func clear() {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        entries.removeAll(); bytes = 0; indexed = true
    }
}
