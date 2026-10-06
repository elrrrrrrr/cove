import Foundation

/// The index is loaded once. Reads/writes update byte accounting incrementally.
/// Disk keys never become directory components or untrusted filenames.
actor DiskCache {
    struct Entry: Codable, Sendable {
        var filename: String
        var bytes: Int
        var touched: Date
        var expires: Date
    }
    private let root: URL
    private let maxBytes: Int
    private let maxEntries: Int
    private var entries: [String: Entry]
    private var totalBytes: Int
    private var loaded = false

    init(root: URL, maxBytes: Int, maxEntries: Int) {
        self.root = root; self.maxBytes = maxBytes; self.maxEntries = maxEntries
        self.entries = [:]; self.totalBytes = 0
    }
    private func regularFileBytes(_ url: URL) -> Int? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber else { return nil }
        return size.intValue
    }
    private func ensureLoaded() {
        guard !loaded else { return }; loaded = true
        let index = root.appendingPathComponent("index.json")
        if let size = regularFileBytes(index), size <= 8 * 1024 * 1024,
           let data = try? Data(contentsOf: index), let saved = try? JSONDecoder().decode([String: Entry].self, from: data) {
            let candidates = saved.sorted { $0.value.touched > $1.value.touched }.prefix(maxEntries)
            for (key, entry) in candidates {
                guard entry.filename == Self.filename(key: key, suffix: (entry.filename as NSString).pathExtension),
                      entry.bytes >= 0, entry.bytes <= maxBytes, entry.expires > .now else { continue }
                let file = root.appendingPathComponent(entry.filename)
                if let actual = regularFileBytes(file), actual == entry.bytes {
                    entries[key] = entry; totalBytes += actual
                }
            }
        }
        // One bounded startup reconciliation removes cache-only orphaned writes.
        let retained = Set(entries.values.map(\.filename))
        if let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsSubdirectoryDescendants]) {
            var examined = 0
            for case let file as URL in enumerator {
                examined += 1; if examined > maxEntries * 2 { break }
                let name = file.lastPathComponent
                if name != "index.json", !retained.contains(name), name.range(of: #"^[a-f0-9]{64}\.[A-Za-z0-9]{1,12}$"#, options: .regularExpression) != nil {
                    try? FileManager.default.removeItem(at: file)
                }
            }
        }
        if totalBytes > maxBytes {
            for key in entries.sorted(by: { $0.value.touched < $1.value.touched }).map(\.key) {
                if totalBytes <= maxBytes { break }; remove(key)
            }
        }
        try? flush()
    }
    static func filename(key: String, suffix: String = "cache") -> String {
        let safe = suffix.range(of: #"^[A-Za-z0-9]{1,12}$"#, options: .regularExpression) != nil ? suffix : "cache"
        return StableHash.of(key) + "." + safe
    }
    func file(for key: String, now: Date = .now) -> URL? {
        ensureLoaded()
        guard var entry = entries[key] else { return nil }
        let url = root.appendingPathComponent(entry.filename)
        guard now < entry.expires, regularFileBytes(url) == entry.bytes else {
            remove(key); return nil
        }
        entry.touched = now; entries[key] = entry
        return url
    }
    func data(for key: String, now: Date = .now) -> Data? {
        guard let file = file(for: key, now: now) else { return nil }
        return try? Data(contentsOf: file)
    }
    func store(_ data: Data, for key: String, ttl: TimeInterval, suffix: String = "cache", now: Date = .now) throws {
        ensureLoaded()
        guard data.count <= maxBytes else { throw CoveError.message("缓存内容超过容量限制") }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let filename = Self.filename(key: key, suffix: suffix)
        try data.write(to: root.appendingPathComponent(filename), options: .atomic)
        record(key: key, filename: filename, bytes: data.count, ttl: ttl, now: now)
        try flush()
    }
    func ingest(_ file: URL, for key: String, ttl: TimeInterval, suffix: String, now: Date = .now) throws -> URL {
        ensureLoaded()
        guard let bytes = regularFileBytes(file) else { throw CoveError.message("缓存文件必须是普通文件") }
        guard bytes <= maxBytes else { throw CoveError.message("文件超过缓存容量限制") }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let filename = Self.filename(key: key, suffix: suffix)
        let destination = root.appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        try FileManager.default.moveItem(at: file, to: destination)
        record(key: key, filename: filename, bytes: bytes, ttl: ttl, now: now)
        try flush()
        return destination
    }
    private func record(key: String, filename: String, bytes: Int, ttl: TimeInterval, now: Date) {
        if let previous = entries[key] {
            totalBytes -= previous.bytes
            if previous.filename != filename { try? FileManager.default.removeItem(at: root.appendingPathComponent(previous.filename)) }
        }
        entries[key] = Entry(filename: filename, bytes: bytes, touched: now, expires: now.addingTimeInterval(ttl))
        totalBytes += bytes
        for key in entries.filter({ $0.value.expires <= now }).map(\.key) { remove(key) }
        if totalBytes > maxBytes || entries.count > maxEntries {
            for key in entries.sorted(by: { $0.value.touched < $1.value.touched }).map(\.key) {
                guard totalBytes > maxBytes || entries.count > maxEntries else { break }
                remove(key)
            }
        }
    }
    private func remove(_ key: String) {
        guard let entry = entries.removeValue(forKey: key) else { return }
        totalBytes -= entry.bytes
        try? FileManager.default.removeItem(at: root.appendingPathComponent(entry.filename))
    }
    private func flush() throws { try CoveStorage.write(entries, to: root.appendingPathComponent("index.json")) }
    func usage() -> (bytes: Int, count: Int) { ensureLoaded(); return (totalBytes, entries.count) }
    func clear() throws {
        if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
        entries = [:]; totalBytes = 0; loaded = true
    }
}

actor AsyncSlots {
    private let limit: Int
    private var active = 0
    private var order: [UUID] = []
    private var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    init(limit: Int) { self.limit = limit }
    func acquire() async -> Bool {
        let id = UUID()
        return await withTaskCancellationHandler {
            guard !Task.isCancelled else { return false }
            if active < limit { active += 1; return true }
            return await withCheckedContinuation { continuation in
                waiters[id] = continuation; order.append(id)
            }
        } onCancel: { Task { await self.cancel(id) } }
    }
    private func cancel(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume(returning: false)
        order.removeAll { $0 == id }
    }
    func release() {
        while !order.isEmpty {
            let id = order.removeFirst()
            if let waiter = waiters.removeValue(forKey: id) { waiter.resume(returning: true); return }
        }
        active = max(0, active - 1)
    }
}
