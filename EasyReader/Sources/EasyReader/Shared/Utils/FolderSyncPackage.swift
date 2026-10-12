import Foundation
import CryptoKit

/// The existing schemaVersion 1 snapshot projected into its editable documents.
/// app-data.json owns the remaining fields and an ID catalog, never duplicate definitions/favorites.
enum FolderSyncPackage {
    static let appDataName = "app-data.json"
    static let favoritesName = "favorites.json"
    static let sitesDirectory = "sites"

    static func documents(_ snapshot: Data, sitePaths: [String: String] = [:]) throws -> [String: Data] {
        let backup = try ConfigBackup.decode(snapshot)
        var metadata = try object(snapshot)
        metadata.removeValue(forKey: "siteDefinitions")
        metadata.removeValue(forKey: "favorites")
        metadata["siteDefinitionIDs"] = backup.siteDefinitions.map(\.id).sorted()
        var result = [appDataName: try json(metadata), favoritesName: try FavoriteDataFile(favorites: backup.favorites ?? []).json()]
        var paths = Set<String>()
        for definition in backup.siteDefinitions {
            var path = sitePaths[definition.id] ?? "sites/\(definition.id).site"
            if path.utf8.count > 240 || paths.contains(path.lowercased()) {
                let digest = SHA256.hash(data: Data(definition.id.utf8)).map { String(format: "%02x", $0) }.joined()
                path = "sites/site-\(digest).site"
            }
            guard path.hasPrefix("sites/"), path.split(separator: "/").count == 2,
                  !path.contains("\\"), path.hasSuffix(".site"), paths.insert(path.lowercased()).inserted else {
                throw ReaderSafetyError.message("站点文件名无效或重复")
            }
            result[path] = Data(try definition.yaml().utf8)
        }
        return result
    }

    static func assemble(_ documents: [String: Data], baseline: Data? = nil) throws -> Data {
        guard let metadata = documents[appDataName], let favoriteBytes = documents[favoritesName] else {
            throw ReaderSafetyError.message("云端 app-data.json 或 favorites.json 尚未下载，暂不覆盖")
        }
        var raw = try object(metadata)
        guard raw["siteDefinitions"] == nil, raw["favorites"] == nil,
              let expected = raw.removeValue(forKey: "siteDefinitionIDs") as? [String], Set(expected).count == expected.count else {
            throw ReaderSafetyError.message("app-data.json 的站点目录无效；站点和收藏请分别保存在独立文件")
        }
        let definitions = try siteDefinitions(documents)
        let ids = Set(definitions.map(\.id))
        guard Set(expected).isSubset(of: ids) else {
            throw ReaderSafetyError.message("站点文件尚未齐全，请等待云盘下载；删除站点请同时更新入口和站点目录")
        }
        let favorites = try FavoriteDataFile.decode(favoriteBytes)
        raw["siteDefinitions"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(definitions))
        raw["favorites"] = try object(favorites.json())["favorites"]
        var backup = try ConfigBackup.decode(json(raw))
        let previous = try baseline.map(ConfigBackup.decode)
        // Apply explicit entry edits by stable entry ID, retaining bookmark UUIDs/custom labels.
        for index in backup.sites.indices {
            let site = backup.sites[index]
            guard let definition = definitions.first(where: { $0.id == site.definitionID }),
                  let entry = definition.entries.first(where: { $0.id == site.entryID }),
                  let oldDefinition = previous?.siteDefinitions.first(where: { $0.id == definition.id }),
                  let oldEntry = oldDefinition.entries.first(where: { $0.id == entry.id }) else { continue }
            if oldEntry.name != entry.name && site.name == oldEntry.name { backup.sites[index].name = entry.name }
            if oldEntry.url(in: oldDefinition) != entry.url(in: definition), site.urlString == oldEntry.url(in: oldDefinition)?.absoluteString {
                backup.sites[index].urlString = entry.url(in: definition)?.absoluteString ?? site.urlString
            }
            if oldEntry.category != entry.category, site.category == SiteCategory(configurationValue: oldEntry.category)?.rawValue {
                backup.sites[index].category = SiteCategory(configurationValue: entry.category)?.rawValue ?? site.category
            }
        }
        try backup.validate()
        return try backup.json()
    }

    static func siteDefinitions(_ documents: [String: Data]) throws -> [SiteDefinition] {
        var result: [SiteDefinition] = []
        for (path, data) in documents.sorted(by: { $0.key < $1.key }) where path.hasPrefix("sites/") && path.hasSuffix(".site") {
            guard let text = String(data: data, encoding: .utf8) else { throw ReaderSafetyError.message("站点文件不是 UTF-8 文本") }
            let definition = try SiteDefinition.decode(text)
            guard !result.contains(where: { $0.id == definition.id }) else { throw ReaderSafetyError.message("多个站点文件使用了同一个 id") }
            result.append(definition)
        }
        return result
    }

    static func equivalentDocument(_ path: String, _ first: Data, _ second: Data) throws -> Bool {
        if path.hasSuffix(".site") {
            guard let a = String(data: first, encoding: .utf8), let b = String(data: second, encoding: .utf8) else { return false }
            return try SiteDefinition.decode(a) == SiteDefinition.decode(b)
        }
        func tree(_ bytes: Data) throws -> SyncJSON {
            guard var object = try JSONDecoder().decode(SyncJSON.self, from: bytes).object else { throw ReaderSafetyError.message("配置文件必须是 JSON 对象") }
            object.removeValue(forKey: "exportDate")
            for key in ["sites", "nasConfigs", "favorites", "histories", "offlineItems"] {
                if case .array(let values) = object[key] {
                    object[key] = .array(values.sorted { String(describing: $0.object?["id"]) < String(describing: $1.object?["id"]) })
                }
            }
            if case .array(let values) = object["siteDefinitionIDs"] {
                object["siteDefinitionIDs"] = .array(values.sorted { String(describing: $0) < String(describing: $1) })
            }
            return .object(object)
        }
        return try tree(first) == tree(second)
    }
    static func object(_ data: Data) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ReaderSafetyError.message("配置文件必须是 JSON 对象") }
        return value
    }
    static func json(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }
}
