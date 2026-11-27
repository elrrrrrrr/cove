import Foundation
import CommonCrypto
import CryptoKit
import SwiftData

// MARK: - Crypto & Portal Resolution

enum SiteCrypto {
    static func decrypt(_ data: Data, key: Data, iv: Data) -> Data? {
        guard [16, 24, 32].contains(key.count), iv.count == 16, !data.isEmpty, data.count % 16 == 0 else { return nil }
        var output = Data(count: data.count + 16)
        let capacity = output.count
        var length = 0
        let status = output.withUnsafeMutableBytes { out in
            data.withUnsafeBytes { input in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding), keyBytes.baseAddress, key.count,
                            ivBytes.baseAddress, input.baseAddress, data.count,
                            out.baseAddress, capacity, &length)
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        output.removeSubrange(length..<output.count)
        return output
    }
}

enum SitePortalResolver {
    static func captures(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[range])
        }
    }

    static func values(at path: String, in object: Any) -> [String] {
        func visit(_ parts: ArraySlice<String>, _ value: Any) -> [String] {
            guard let head = parts.first else { return (value as? String).map { [$0] } ?? [] }
            if head == "*", let array = value as? [Any] { return array.flatMap { visit(parts.dropFirst(), $0) } }
            guard let dict = value as? [String: Any], let next = dict[head] else { return [] }
            return visit(parts.dropFirst(), next)
        }
        return visit(path.split(separator: ".").map(String.init)[...], object)
    }

    static func resolve(in html: String, portal: URL, target: URL, config: SitePortal) -> URL? {
        func rewrite(_ candidates: [String]) -> URL? {
            for candidate in candidates {
                guard let url = WebURLSafety.resolveURL(candidate, relativeTo: portal),
                      let host = url.host(), host.lowercased() != portal.host()?.lowercased(),
                      !(config.excludedHosts ?? []).contains(where: { host.lowercased().contains($0.lowercased()) }) else { continue }
                var result = URLComponents(url: target, resolvingAgainstBaseURL: true)
                result?.scheme = url.scheme; result?.host = host; result?.port = url.port
                return result?.url
            }
            return nil
        }
        if let pattern = config.base64Pattern {
            for value in captures(pattern, in: html) {
                if let bytes = Data(base64Encoded: value), let text = String(data: bytes, encoding: .utf8),
                   let result = rewrite(captures(#"href=["'](https?://[^"']+)["']"#, in: text)) { return result }
            }
        }
        if let dataPattern = config.dataPattern, let keyPattern = config.keyPattern {
            for key in captures(keyPattern, in: html).reversed() {
                for encoded in captures(dataPattern, in: html).reversed() {
                    guard let payload = Data(base64Encoded: encoded), payload.count > 16,
                          let plain = SiteCrypto.decrypt(Data(payload.dropFirst(16)), key: Data(SHA256.hash(data: Data(key.utf8))), iv: Data(payload.prefix(16))),
                          let object = try? JSONSerialization.jsonObject(with: plain) else { continue }
                    if let identity = config.identityPattern {
                        let text = (config.identityPaths ?? []).flatMap { values(at: $0, in: object) }.joined(separator: " ")
                        guard text.range(of: identity, options: [.regularExpression, .caseInsensitive]) != nil else { continue }
                    }
                    if let result = rewrite((config.urlPaths ?? []).flatMap { values(at: $0, in: object) }) { return result }
                }
            }
            return nil
        }
        return rewrite(captures(#"href=["'](https?://[^"']+)["']"#, in: html))
    }

    static func fetch(config: SitePortal, target: URL) async -> URL? {
        guard let portal = URL(string: config.url), WebURLSafety.isWebURL(portal) else { return nil }
        let request = WebURLSafety.makeRequest(url: portal, headers: config.headers ?? [:], timeout: 10)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let html = String(data: data, encoding: .utf8) else { return nil }
        return resolve(in: html, portal: portal, target: target, config: config)
    }
}

// MARK: - Parser & Registry

enum PaginationMode: Sendable {
    case none
    case webNavigation(nextPageJS: String)
    case ajax(js: String, thumbnailJS: String? = nil)
}

struct SiteParserCategory: Sendable, Hashable {
    let name: String
    let urlString: String
}

struct SiteParser: Sendable {
    let definitionID: String?
    let ruleID: String?
    let itemKind: ItemKind
    let preNavigateJS: String?
    let waitSeconds: Double
    let extractItemsJS: String
    let paginationMode: PaginationMode
    let categories: [SiteParserCategory]
    let needsJS: Bool
    let portal: SitePortal?
    let transformScript: String?
    let requestHeaders: [String: String]
    let presentation: SitePresentation
    let galleryLayout: BrowserLayout
    let searchURLTemplate: String?

    func searchURL(keyword: String, base: URL?) -> URL? {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        guard let template = searchURLTemplate, template.contains("{keyword}"),
              let encoded = keyword.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return WebURLSafety.resolveURL(template.replacingOccurrences(of: "{keyword}", with: encoded), relativeTo: base)
    }
}

final class SiteParserRegistry: @unchecked Sendable {
    static let shared = SiteParserRegistry()
    private let lock = NSLock()
    private var storedDefinitions: [SiteDefinition] = []

    static var definitions: [SiteDefinition] { shared.lock.withLock { shared.storedDefinitions } }
    static func replaceDefinitions(_ values: [SiteDefinition]) { shared.lock.withLock { shared.storedDefinitions = values } }

    static func definition(for url: URL, id: String? = nil) -> SiteDefinition? {
        if let id, let value = definitions.first(where: { $0.id == id }) { return value }
        return definitions.filter { $0.match.matches(url) }.sorted { $0.id < $1.id }.first
    }

    static func rule(for url: URL, role: String, definitionID: String? = nil) -> SiteRule? {
        definition(for: url, id: definitionID)?.rule(for: url, role: role)
    }

    static func imageTransform(for url: URL, referer: URL?, definitionID: String? = nil) -> SiteImageTransform? {
        if let definitionID { return definitions.first { $0.id == definitionID }?.images }
        if let referer, let transform = definition(for: referer)?.images { return transform }
        return definitions.compactMap(\.images).first {
            ($0.hosts ?? []).contains { url.host()?.lowercased() == $0.lowercased() }
        }
    }

    static func parser(for urlString: String, definitionID: String? = nil) -> SiteParser {
        guard let url = URL(string: urlString),
              let definition = definition(for: url, id: definitionID),
              let rule = definition.rule(for: url, role: "catalog") else { return .generic }
        return parser(definition: definition, rule: rule)
    }

    static func parser(definition: SiteDefinition, rule: SiteRule) -> SiteParser {
        let kind = rule.contentType.flatMap(ItemKind.init(string:)) ?? .video
        let pagination: PaginationMode
        if let config = rule.pagination {
            switch config.mode {
            case "ajax": pagination = .ajax(js: config.script ?? "return '[]';", thumbnailJS: config.thumbnailScript)
            case "webNavigation", "nextLink":
                let js: String
                if let expression = config.expression { js = expression }
                else if let script = config.script { js = "(async function(){\n\(script)\n})()" }
                else {
                    js = "(function(){ const el = document.querySelector(\(SiteScript.json(config.selector ?? "a[rel=next]"))); const value = el?.getAttribute(\(SiteScript.json(config.attribute ?? "href"))); return value ? new URL(value, document.baseURI).href : null; })()"
                }
                pagination = .webNavigation(nextPageJS: js)
            default: pagination = .none
            }
        } else { pagination = .none }

        return SiteParser(
            definitionID: definition.id,
            ruleID: rule.id,
            itemKind: kind,
            preNavigateJS: rule.load?.preNavigateExpression ?? rule.load?.preNavigateScript.map { "(async function(){\n\($0)\n})()" },
            waitSeconds: rule.load?.waitSeconds ?? 0,
            extractItemsJS: rule.extract?.javascript ?? "'[]'",
            paginationMode: pagination,
            categories: (rule.categories ?? []).map { .init(name: $0.name, urlString: $0.path) },
            needsJS: rule.load?.mode == "webView",
            portal: definition.portal,
            transformScript: rule.load?.transformScript,
            requestHeaders: rule.load?.headers ?? [:],
            presentation: rule.presentation ?? .init(),
            galleryLayout: rule.presentation?.layout.flatMap(BrowserLayout.init(rawValue:)) ?? .defaultLayout(for: kind),
            searchURLTemplate: rule.searchURLTemplate
        )
    }
}

extension SiteParser {
    static let generic = SiteParser(
        definitionID: nil, ruleID: nil, itemKind: .video, preNavigateJS: nil, waitSeconds: 2.0,
        extractItemsJS: genericExtractItemsJS, paginationMode: .webNavigation(nextPageJS: genericNextPageJS),
        categories: [], needsJS: false, portal: nil, transformScript: nil,
        requestHeaders: [:], presentation: .init(), galleryLayout: .bento, searchURLTemplate: nil
    )

    static let genericNextPageJS = #"""
    (function() {
        const rel = document.querySelector('link[rel="next"]');
        if (rel?.href) return rel.href;
        const kw = [/\bnext\b/i, /下一页/, /›|»/];
        const links = [...document.querySelectorAll('a[href]')];
        for (const k of kw) {
            const a = links.find(el => k.test(el.textContent.trim()) && !el.href.match(/#$/));
            if (a) return a.href;
        }
        return null;
    })()
    """#

    static let genericExtractItemsJS = #"""
    (function() {
        const selectors = ['.video-list-item','.video-item','.video-card','.thumb-item','.col-6','.col-4','.col-3','.col-sm-4','.col-lg-3','article','.item','.card'];
        let best = [], bestScore = 0;
        for (const sel of selectors) {
            const els = [...document.querySelectorAll(sel)];
            const score = els.filter(el => el.querySelector('a') && el.querySelector('img')).length;
            if (score > bestScore) { bestScore = score; best = els; }
        }
        if (bestScore === 0) return '[]';
        const items = [];
        best.forEach(el => {
            const a = el.querySelector('a[href]'), img = el.querySelector('img');
            const title = el.querySelector('h1,h2,h3,h4,h5,h6,[class*="title"],[class*="name"]');
            const dur = el.querySelector('[class*="duration"],[class*="time"],.badge');
            const url = a?.href || '', text = (title?.textContent || img?.alt || a?.title || '').trim();
            const thumb = img?.dataset?.src || img?.dataset?.lazySrc || img?.dataset?.original || img?.src || '';
            if (url && text && !/^(#|javascript)/.test(url)) {
                items.push({ title: text, url, thumbnail: thumb, duration: (dur?.textContent || '').trim(), extra: '' });
            }
        });
        const seen = new Set();
        return JSON.stringify(items.filter(i => seen.has(i.url) ? false : (seen.add(i.url), true)).slice(0, 100));
    })()
    """#
}

// MARK: - SiteDefinitionStore & Optional Bundled Favorites

@Observable @MainActor
final class SiteDefinitionStore {
    static let shared = SiteDefinitionStore()
    static let bootstrapKey = "siteDefinitions.initialized.v1"

    private(set) var definitions: [SiteDefinition] = []
    var issues: [String] = []
    var pendingImport: SiteDefinition?
    private let storageURL: URL
    private var initialized = false

    init(storageURL: URL? = nil) {
        self.storageURL = storageURL ?? LocalAppStorage.config.appendingPathComponent("sites.json")
        if let data = try? Data(contentsOf: self.storageURL) {
            do {
                let decoded = try JSONDecoder().decode([SiteDefinition].self, from: data)
                for item in decoded { try item.validate() }
                definitions = decoded.sorted { $0.id < $1.id }
            } catch {
                issues.append("读取站点配置失败：\(error.localizedDescription)")
            }
        }
        SiteParserRegistry.replaceDefinitions(definitions)
    }

    func definition(id: String?) -> SiteDefinition? { id.flatMap { key in definitions.first { $0.id == key } } }

    func save(_ definition: SiteDefinition) throws {
        try definition.validate()
        try replace(definitions.filter { $0.id != definition.id } + [definition])
    }

    func replace(_ values: [SiteDefinition]) throws {
        for value in values { try value.validate() }
        guard Set(values.map(\.id)).count == values.count else { throw SiteDefinitionError.invalid("站点 id 重复") }
        try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let sorted = values.sorted { $0.id < $1.id }
        try JSONEncoder().encode(sorted).write(to: storageURL, options: .atomic)
        definitions = sorted
        SiteParserRegistry.replaceDefinitions(sorted)
    }

    static func bundledDefinitions(bundle: Bundle = .main) -> (definitions: [SiteDefinition], issues: [String]) {
        let urls = (bundle.urls(forResourcesWithExtension: "site", subdirectory: "Sites") ?? []).sorted { $0.lastPathComponent < $1.lastPathComponent }
        var values: [SiteDefinition] = [], issues: [String] = []
        for url in urls {
            do {
                let def = try SiteDefinition.decode(String(contentsOf: url, encoding: .utf8))
                guard !values.contains(where: { $0.id == def.id }) else { throw SiteDefinitionError.invalid("站点 id 重复：\(def.id)") }
                values.append(def)
            } catch { issues.append("\(url.lastPathComponent)：\(error.localizedDescription)") }
        }
        return (values, issues)
    }

    func initialize(context: ModelContext, freshInstall: Bool, defaults: UserDefaults = .standard, bundle: Bundle = .main) {
        guard !initialized else { return }
        initialized = true
        guard !defaults.bool(forKey: Self.bootstrapKey) else { return }
        let bundled = Self.bundledDefinitions(bundle: bundle)
        issues.append(contentsOf: bundled.issues)
        let previous = definitions
        do {
            if freshInstall {
                try replace(bundled.definitions)
                for def in definitions { addEntries(def, context: context) }
                if let url = bundle.url(forResource: "favorites", withExtension: "json", subdirectory: "BundledData") {
                    try FavoriteDataFile.decode(Data(contentsOf: url)).apply(to: context)
                }
            } else {
                let bookmarks = try context.fetch(FetchDescriptor<BookmarkSite>())
                let favorites = try context.fetch(FetchDescriptor<FavoriteVideo>())
                let histories = try context.fetch(FetchDescriptor<ReadingHistory>())
                let urls = (bookmarks.map(\.urlString) + favorites.map(\.pageURLString) + histories.compactMap(\.url)).compactMap(URL.init(string:))
                var merged = definitions
                for def in bundled.definitions where !merged.contains(where: { $0.id == def.id }) {
                    if urls.contains(where: { def.match.matches($0) }) { merged.append(def) }
                }
                try replace(merged)
                for fav in favorites { fav.definitionID = fav.pageURL.flatMap { SiteParserRegistry.definition(for: $0)?.id } }
                for hist in histories { hist.definitionID = hist.url.flatMap(URL.init(string:)).flatMap { SiteParserRegistry.definition(for: $0)?.id } }
                for bm in bookmarks { bm.definitionID = bm.url.flatMap { SiteParserRegistry.definition(for: $0)?.id } }
            }
            try context.save()
            defaults.set(true, forKey: Self.bootstrapKey)
        } catch {
            context.rollback()
            try? replace(previous)
            initialized = false
            issues.append("初始化站点配置失败：\(error.localizedDescription)")
        }
    }

    func addEntries(_ definition: SiteDefinition, context: ModelContext) {
        let bookmarks = (try? context.fetch(FetchDescriptor<BookmarkSite>())) ?? []
        var order = (bookmarks.map(\.sortOrder).max() ?? -1) + 1
        for entry in definition.entries {
            guard let url = entry.url(in: definition) else { continue }
            if let existing = bookmarks.first(where: { $0.definitionID == definition.id && $0.entryID == entry.id }) {
                existing.name = entry.name
                existing.urlString = url.absoluteString
                existing.category = SiteCategory(configurationValue: entry.category) ?? .other
                continue
            }
            let bookmark = BookmarkSite(name: entry.name, urlString: url.absoluteString,
                                        category: SiteCategory(configurationValue: entry.category) ?? .other, sortOrder: order)
            bookmark.definitionID = definition.id; bookmark.entryID = entry.id
            context.insert(bookmark); order += 1
        }
    }

    func importDefinition(_ value: SiteDefinition, context: ModelContext, asCopy: Bool = false) throws {
        var definition = value
        if asCopy { definition.id = "user." + UUID().uuidString.lowercased(); definition.name += "（副本）" }
        let previous = definitions
        do {
            try save(definition)
            addEntries(definition, context: context)
            try context.save()
        } catch {
            context.rollback(); try? replace(previous); throw error
        }
    }
}

struct FavoriteDataFile: Codable, Sendable {
    var schemaVersion: Int = 1
    var favorites: [Item]

    struct Item: Codable, Sendable {
        var title: String; var pageURLString: String; var thumbnailURLString: String?
        var duration: String; var siteName: String; var definitionID: String?
        var isComic: Bool; var isArticle: Bool; var addedAt: Date?
    }

    static func decode(_ data: Data) throws -> Self {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let file = try decoder.decode(Self.self, from: data)
        guard file.schemaVersion == 1 else { throw SiteDefinitionError.invalid("不支持的收藏文件版本：\(file.schemaVersion)") }
        for item in file.favorites {
            guard let url = URL(string: item.pageURLString), WebURLSafety.isWebURL(url) else {
                throw SiteDefinitionError.invalid("收藏地址无效：\(item.pageURLString)")
            }
        }
        return file
    }

    @MainActor func apply(to context: ModelContext) throws {
        let existing = try context.fetch(FetchDescriptor<FavoriteVideo>())
        let urls = Set(existing.map(\.pageURLString))
        for item in favorites where !urls.contains(item.pageURLString) {
            let value = FavoriteVideo(
                title: item.title, pageURLString: item.pageURLString, thumbnailURLString: item.thumbnailURLString,
                duration: item.duration, siteName: item.siteName, isComic: item.isComic, isArticle: item.isArticle,
                definitionID: item.definitionID
            )
            if let addedAt = item.addedAt { value.addedAt = addedAt }
            context.insert(value)
        }
        try context.save()
    }
}
