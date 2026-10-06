import Foundation
import Observation

@Observable @MainActor final class SourceStore {
    private(set) var definitions: [SourceDefinition] = []
    private(set) var revisions: [String: String] = [:]
    private final class WeakProvider {
        weak var value: (any SourceProvider)?
        init(_ value: any SourceProvider) { self.value = value }
    }
    private var providers: [String: WeakProvider] = [:]
    private var byID: [String: SourceDefinition] = [:]
    private var bookmarks: [String: Data] = [:]
    private let storageURL: URL
    private let bindingURL: URL
    @ObservationIgnored var onProviderClosed: ((String) -> Void)?
    var error: String?

    init(storageURL: URL = CoveStorage.config.appendingPathComponent("sources.json"),
         bindingURL: URL = CoveStorage.config.appendingPathComponent("folders.json")) {
        self.storageURL = storageURL; self.bindingURL = bindingURL
        do {
            if FileManager.default.fileExists(atPath: storageURL.path) {
                let values = try JSONDecoder().decode([SourceDefinition].self, from: Data(contentsOf: storageURL))
                for value in values { try value.validate() }
                guard Set(values.map(\.id)).count == values.count else { throw CoveError.message("配置中有重复来源") }
                definitions = values
            }
            if FileManager.default.fileExists(atPath: bindingURL.path) {
                bookmarks = try JSONDecoder().decode([String: Data].self, from: Data(contentsOf: bindingURL))
            }
        } catch { self.error = "读取来源失败：\(error.localizedDescription)" }
        byID = Dictionary(uniqueKeysWithValues: definitions.map { ($0.id, $0) })
        revisions = Dictionary(uniqueKeysWithValues: definitions.map { ($0.id, $0.fingerprint + self.sessionEpoch($0.id)) })
    }
    func definition(id: String) -> SourceDefinition? { byID[id] }
    func save(_ value: SourceDefinition) throws {
        try value.validate()
        var next = definitions
        if let index = next.firstIndex(where: { $0.id == value.id }) { next[index] = value }
        else { next.append(value) }
        try replace(next)
    }
    func replace(_ values: [SourceDefinition]) throws {
        for value in values { try value.validate() }
        guard Set(values.map(\.id)).count == values.count else { throw CoveError.message("来源 id 重复") }
        try CoveStorage.write(values, to: storageURL)
        for (id, provider) in providers where !values.contains(where: { $0.id == id && $0.fingerprint + sessionEpoch(id) == revisions[id] }) {
            provider.value?.close(); onProviderClosed?(id); providers.removeValue(forKey: id)
        }
        definitions = values
        byID = Dictionary(uniqueKeysWithValues: values.map { ($0.id, $0) })
        revisions = Dictionary(uniqueKeysWithValues: values.map { ($0.id, $0.fingerprint + self.sessionEpoch($0.id)) })
    }
    func remove(id: String) throws {
        try replace(definitions.filter { $0.id != id })
        bookmarks.removeValue(forKey: id)
        try CoveStorage.write(bookmarks, to: bindingURL)
        CredentialVault.remove(id: id)
    }
    /// Reordering a filtered subset permutes only its original slots.
    func reorder(ids: [String], visible: [String]) throws {
        let visibleSet = Set(visible)
        guard Set(ids) == visibleSet, ids.count == visible.count else { throw CoveError.message("来源排序无效") }
        let lookup = Dictionary(uniqueKeysWithValues: definitions.map { ($0.id, $0) })
        var iterator = ids.makeIterator()
        let next = definitions.map { item in
            guard visibleSet.contains(item.id), let nextID = iterator.next(), let value = lookup[nextID] else { return item }
            return value
        }
        try replace(next)
    }
    func bindFolder(_ url: URL, id: String) throws {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        bookmarks[id] = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        try CoveStorage.write(bookmarks, to: bindingURL)
        invalidateSession(id: id)
    }
    func folder(id: String) throws -> URL {
        guard let data = bookmarks[id] else { throw CoveError.message("请先为此来源选择文件夹") }
        var stale = false
        let url = try URL(resolvingBookmarkData: data, options: .withoutUI, relativeTo: nil, bookmarkDataIsStale: &stale)
        if stale { try bindFolder(url, id: id) }
        return url
    }
    private func sessionEpoch(_ id: String) -> String { UserDefaults.standard.string(forKey: "cove2.session." + id) ?? "" }
    func invalidateSession(id: String) {
        UserDefaults.standard.set(UUID().uuidString, forKey: "cove2.session." + id)
        providers.removeValue(forKey: id)?.value?.close(); onProviderClosed?(id)
        if let definition = definition(id: id) { revisions[id] = definition.fingerprint + sessionEpoch(id) }
    }
    func setPassword(_ password: String, id: String) throws {
        try CredentialVault.save(password, id: id)
        invalidateSession(id: id)
    }
    func provider(id: String) throws -> any SourceProvider {
        if let cached = providers[id]?.value { return cached }
        guard let definition = definition(id: id) else { throw CoveError.message("此内容的来源已删除，请重新添加来源") }
        let provider: any SourceProvider
        switch definition.source.adapter {
        case .web: provider = WebSourceProvider(definition: definition, revision: revisions[id])
        case .files: provider = try FileSourceProvider(definition: definition, root: folder(id: id))
        case .smb: provider = SMBSourceProvider(definition: definition, password: CredentialVault.load(id: id) ?? "", revision: revisions[id])
        }
        providers[id] = WeakProvider(provider)
        return provider
    }
    func bootstrap(library: LibraryStore, bundle: Bundle = .main, defaults: UserDefaults = .standard) throws {
        guard !defaults.bool(forKey: "cove2.bootstrap.done") else { return }
        let files = (bundle.urls(forResourcesWithExtension: "site", subdirectory: "Sites") ?? []).sorted { $0.path < $1.path }
        var imported: [SourceDefinition] = []
        for url in files { imported.append(try SourceDefinition.read(url)) }
        let previous = definitions
        do {
            if definitions.isEmpty { try replace(imported) }
            if let url = bundle.url(forResource: "favorites", withExtension: "json", subdirectory: "BundledData") {
                try library.importFavorites(Data(contentsOf: url))
            }
            defaults.set(true, forKey: "cove2.bootstrap.done")
        } catch {
            try? replace(previous)
            throw error
        }
    }
}
