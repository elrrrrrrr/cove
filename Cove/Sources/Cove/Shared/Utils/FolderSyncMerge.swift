import Foundation

/// A value tree keeps merge work independent of SwiftData and actor isolation.
enum SyncJSON: Codable, Equatable, Sendable {
    case object([String: SyncJSON]), array([SyncJSON]), string(String), number(Double), bool(Bool), null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([String: SyncJSON].self) { self = .object(v) }
        else { self = .array(try c.decode([SyncJSON].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    var object: [String: SyncJSON]? { if case .object(let v) = self { return v }; return nil }
}

extension SyncJSON {
    /// Normalized form for equality comparison: drops volatile metadata (`exportDate`)
    /// and sorts arrays (by `id`, or by scalar value) so ordering differences don't count as changes.
    func normalized(idSortedKeys: [String], scalarSortedKeys: [String] = []) -> SyncJSON {
        guard var object = self.object else { return self }
        object.removeValue(forKey: "exportDate")
        for key in idSortedKeys {
            if case .array(let values) = object[key] {
                object[key] = .array(values.sorted { String(describing: $0.object?["id"]) < String(describing: $1.object?["id"]) })
            }
        }
        for key in scalarSortedKeys {
            if case .array(let values) = object[key] {
                object[key] = .array(values.sorted { String(describing: $0) < String(describing: $1) })
            }
        }
        return .object(object)
    }
}

enum FolderSyncMerge {
    struct Result: Sendable { var data: Data; var hasConflicts: Bool }
    static func merge(local: Data, remote: Data, baseline: Data?) throws -> Result {
        let decoder = JSONDecoder()
        func tree(_ data: Data) throws -> SyncJSON {
            var value = try decoder.decode(SyncJSON.self, from: data).object ?? [:]
            value.removeValue(forKey: "exportDate")
            guard value["schemaVersion"] == .number(1) else { throw ReaderSafetyError.message("云端备份格式无效") }
            return .object(value)
        }
        let localTree = try tree(local), remoteTree = try tree(remote)
        let baseTree = try baseline.map(tree)
        var conflicts = false
        let collections: Set<String> = ["sites", "nasConfigs", "siteDefinitions", "favorites", "histories", "offlineItems"]
        func index(_ values: [SyncJSON]) throws -> [String: SyncJSON] {
            var result: [String: SyncJSON] = [:]
            for value in values {
                guard case .string(let id) = value.object?["id"], result[id] == nil else {
                    throw ReaderSafetyError.message("同步记录缺少唯一标识")
                }
                result[id] = value
            }
            return result
        }
        func combine(_ l: SyncJSON?, _ r: SyncJSON?, _ b: SyncJSON?, key: String = "") throws -> SyncJSON? {
            if l == r { return l }
            if baseTree != nil {
                if l == b { return r }
                if r == b { return l }
            } else {
                if l == nil { return r }
                if r == nil { return l }
            }
            if case .object(let left) = l, case .object(let right) = r {
                let base = b?.object ?? [:]
                var output: [String: SyncJSON] = [:]
                for k in Set(left.keys).union(right.keys).union(base.keys) {
                    output[k] = try combine(left[k], right[k], base[k], key: k)
                }
                return .object(output)
            }
            if collections.contains(key), case .array(let left) = l, case .array(let right) = r {
                let li = try index(left), ri = try index(right)
                let bi: [String: SyncJSON]
                if case .array(let values) = b { bi = try index(values) } else { bi = [:] }
                var output: [SyncJSON] = []
                for id in Set(li.keys).union(ri.keys).union(bi.keys).sorted() {
                    if let value = try combine(li[id], ri[id], bi[id]) { output.append(value) }
                }
                return .array(output)
            }
            conflicts = true
            // First connection restores cloud fields; subsequent concurrent edits keep local
            // fields, with both originals archived by the caller before publication.
            return baseTree == nil ? r : l
        }
        var output = try combine(localTree, remoteTree, baseTree)?.object ?? [:]
        // Dates are metadata, not evidence that a whole device wins a merge.
        output["exportDate"] = .string(ISO8601DateFormatter().string(from: Date()))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return Result(data: try encoder.encode(SyncJSON.object(output)), hasConflicts: conflicts)
    }
    static func equivalent(_ first: Data, _ second: Data) throws -> Bool {
        let keys = ["sites", "nasConfigs", "siteDefinitions", "favorites", "histories", "offlineItems"]
        func value(_ data: Data) throws -> [String: SyncJSON] {
            try JSONDecoder().decode(SyncJSON.self, from: data).normalized(idSortedKeys: keys).object ?? [:]
        }
        return try value(first) == value(second)
    }
}
