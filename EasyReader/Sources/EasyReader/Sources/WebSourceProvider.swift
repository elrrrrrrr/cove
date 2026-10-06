import Foundation
import WebKit

@MainActor final class WebSourceProvider: SourceProvider {
    let definition: SourceDefinition
    let revision: String
    private let catalogEngine: WebEngine
    private let resolveSlots = AsyncSlots(limit: 2)
    private let cache = CatalogCache.shared
    private var compiled: [String: (module: PageModule, script: String)] = [:]
    init(definition: SourceDefinition, revision: String? = nil) { self.definition = definition; self.revision = revision ?? definition.fingerprint; catalogEngine = WebEngine(sourceID: definition.id) }
    private func prepared(_ role: String, url: URL) -> (module: PageModule, script: String)? {
        let key = role + "\u{0}" + url.absoluteString
        if let value = compiled[key] { return value }
        let base: PageModule?
        switch role {
        case "catalog": base = definition.modules?.catalog
        case "video": base = definition.modules?.video
        case "audio": base = definition.modules?.audio
        case "ebook": base = definition.modules?.ebook
        case "comic": base = definition.modules?.comic
        case "chapter": base = definition.modules?.chapter
        default: base = definition.modules?.tags
        }
        guard let module = base?.selected(for: url) else { return nil }
        let value = (module, module.javascript)
        if compiled.count >= 128 { compiled.removeAll(keepingCapacity: true) }
        compiled[key] = value
        return value
    }
    func list(_ request: CollectionRequest) async throws -> ResourcePage {
        guard var url = definition.absoluteURL(request.locator) else { throw CoveError.message("列表地址无效") }
        if let query = request.query, let search = definition.modules?.search {
            url = try SearchURL.resolve(template: search.url, query: query, base: url)
        }
        var page = 1
        if let cursor = request.cursor {
            if cursor.hasPrefix("page:") { page = Int(cursor.dropFirst(5)) ?? 1 }
            else if let next = definition.absoluteURL(cursor) { url = next }
        }
        let key = definition.id + revision + url.absoluteString + (request.cursor ?? "")
        if !request.forceRefresh, let cached = await cache.page(key) {
            return ResourcePage(items: cached.items, nextCursor: cached.nextCursor)
        }
        let selected = prepared("catalog", url: url)
        let module = selected?.module ?? Self.genericCatalog
        let script = selected?.script ?? Self.genericCatalog.javascript
        let pagination = definition.modules?.pagination?.selected(for: url)
        if catalogEngine.webView.url != url || page == 1 {
            try await navigate(engine: catalogEngine, url: url, load: module.load)
        }
        let body: String
        if page > 1, pagination?.mode == "ajax" {
            body = pagination?.script ?? pagination?.expression.map { "return await (\($0));" } ?? "return [];"
        } else { body = script }
        let result = try await catalogEngine.execute(body, arguments: ["page": page])
        let pageURL = url
        let episodes = definition.modules?.episodes
        let sourceID = definition.id, defaultKind = module.kind ?? definition.startingEntries.first?.kind ?? .web
        var items = try await Task.detached(priority: .userInitiated) {
            try ResourceParser.catalog(result, sourceID: sourceID, base: pageURL, defaultKind: defaultKind, episodes: episodes)
        }.value
        if let thumbnailScript = pagination?.thumbnailScript, !items.isEmpty {
            let images = try await catalogEngine.execute(thumbnailScript, arguments: ["page": page])
            if let data = images.data(using: .utf8), let map = try? JSONDecoder().decode([String: String].self, from: data) {
                for i in items.indices { if let image = map[items[i].locator] { items[i].thumbnail = image } }
            }
        }
        let nextCursor: String?
        if items.isEmpty || pagination?.mode == "none" || pagination == nil { nextCursor = nil }
        else if pagination?.mode == "ajax" { nextCursor = "page:\(page + 1)" }
        else if let field = pagination?.next {
            let result = try await catalogEngine.execute(PageModule(fields: ["url": field]).javascript)
            let values = try ResourceParser.object(result)
            nextCursor = values["url"] as? String
        } else {
            let result = try await catalogEngine.execute(pagination?.script ?? pagination?.expression.map { "return await (\($0));" } ?? "return '';")
            nextCursor = result.isEmpty || result == "null" ? nil : result
        }
        let validCursor = nextCursor?.isEmpty != false || nextCursor == url.absoluteString || nextCursor == request.cursor ? nil : nextCursor
        let value = ResourcePage(items: items, nextCursor: validCursor)
        try? await cache.store(value, key: key)
        return ResourcePage(items: items, nextCursor: validCursor)
    }
    private func navigate(engine: WebEngine, url: URL, load: PageLoad?) async throws {
        var destination = url
        if let portal = definition.modules?.portal {
            if let rewritten = await SitePortalResolver.fetch(config: portal, target: url) { destination = rewritten }
        }
        try await engine.load(destination, headers: load?.headers ?? [:], wait: load?.waitSeconds ?? 0)
        if let preNavigate = load?.preNavigateScript {
            let result = try await engine.execute(preNavigate)
            if let rewritten = URL(string: result, relativeTo: destination)?.absoluteURL, ["http", "https"].contains(rewritten.scheme ?? "") {
                try await engine.load(rewritten, headers: load?.headers ?? [:], wait: load?.waitSeconds ?? 0)
            }
        }
    }
    func resolve(_ item: ResourceItem) async throws -> ResolvedContent {
        guard let url = definition.absoluteURL(item.locator) else { throw CoveError.message("内容地址无效") }
        if item.kind == .folder { return .collection(item.locator) }
        if item.kind == .image { return .image(url) }
        if item.kind == .ebook, !["pdf", "txt", "epub"].contains(item.fileExtension), let rule = prepared("ebook", url: url) {
            let engine = WebEngine(sourceID: definition.id); defer { engine.cancel() }
            try await navigate(engine: engine, url: url, load: rule.module.load)
            let result = try ResourceParser.object(await engine.execute(rule.script))
            guard let address = result["url"] as? String, let target = definition.absoluteURL(address) else { throw CoveError.message("电子书地址无效") }
            var document = item; document.locator = target.absoluteString; document.format = result["format"] as? String
            return .document(try await localDocument(document))
        }
        if item.kind == .ebook { return .document(try await localDocument(item)) }
        if item.kind == .comic, ["cbz", "zip", "cbr", "rar"].contains(item.fileExtension) {
            return .comic(ComicContent(localArchive: try await localDocument(item)))
        }
        if [.video, .audio].contains(item.kind), !item.fileExtension.isEmpty,
           ResourceKind.detect(path: url.path) == item.kind { return .media(MediaAsset(url: url, headers: ["Referer": item.locator])) }
        if item.kind == .web { return .web(url) }
        guard await resolveSlots.acquire() else { throw CancellationError() }
        do {
            let resolved = try await resolvePage(item: item, url: url)
            await resolveSlots.release(); return resolved
        } catch { await resolveSlots.release(); throw error }
    }
    private func resolvePage(item: ResourceItem, url: URL) async throws -> ResolvedContent {
        let engine = WebEngine(sourceID: definition.id)
        defer { engine.cancel() }
        if item.kind == .comic {
            if let rule = prepared("comic", url: url) {
                try await navigate(engine: engine, url: url, load: rule.module.load)
                let result = try ResourceParser.object(await engine.execute(rule.script))
                let chapters = (result["chapters"] as? [[String: Any]] ?? []).compactMap { chapter -> ComicChapter? in
                    guard let address = chapter["url"] as? String, let target = URL(string: address, relativeTo: url)?.absoluteURL else { return nil }
                    return ComicChapter(title: chapter["title"] as? String ?? "章节", locator: target.absoluteString)
                }
                if !chapters.isEmpty {
                    return .comic(ComicContent(title: result["title"] as? String, author: result["author"] as? String,
                                          status: result["status"] as? String, description: result["desc"] as? String,
                                          cover: result["cover"] as? String, tags: result["tags"] as? [String] ?? [], chapters: chapters))
                }
            }
            if let rule = prepared("chapter", url: url) {
                if let request = rule.module.request {
                    let captures = SitePortalResolver.captures(request.capturePattern, in: item.locator)
                    guard let capture = captures.first,
                          let endpoint = definition.absoluteURL(request.urlTemplate.replacingOccurrences(of: "{capture}", with: capture)) else { throw CoveError.message("章节请求地址无效") }
                    let (data, response) = try await URLSession.shared.data(from: endpoint)
                    guard (response as? HTTPURLResponse).map({ (200...299).contains($0.statusCode) }) == true,
                          let text = String(data: data, encoding: .utf8) else { throw CoveError.message("章节请求失败") }
                    let images = SitePortalResolver.captures(request.responsePattern, in: text).filter { image in
                        !(request.exclude ?? []).contains { image.contains($0) }
                    }
                    return .comic(ComicContent(images: images))
                }
                if engine.webView.url == nil { try await navigate(engine: engine, url: url, load: rule.module.load) }
                let result = try ResourceParser.object(await engine.execute(rule.script))
                let images = (result["images"] as? [String] ?? []).compactMap { URL(string: $0, relativeTo: url)?.absoluteURL.absoluteString }
                return .comic(ComicContent(images: images))
            }
        }
        let rule = prepared(item.kind == .audio ? "audio" : "video", url: url)
        try await navigate(engine: engine, url: url, load: rule?.module.load)
        let body = rule?.script ?? "const v=document.querySelector('video,audio'); return {url:v?.currentSrc || v?.src || v?.querySelector('source')?.src || ''};"
        let result = try ResourceParser.object(await engine.execute(body))
        guard let address = result["url"] as? String, !address.isEmpty,
              let media = URL(string: address, relativeTo: url)?.absoluteURL, ["http", "https"].contains(media.scheme ?? "") else {
            throw CoveError.message("未找到可播放内容，请检查解析规则或先登录来源")
        }
        var headers = result["headers"] as? [String: String] ?? [:]
        headers["Referer"] = headers["Referer"] ?? url.absoluteString
        if let cookie = await SourceWebSession.cookieHeader(id: definition.id, url: media) { headers["Cookie"] = cookie }
        let next = (result["nextPageURL"] as? String).flatMap { URL(string: $0, relativeTo: url)?.absoluteURL }.map {
            ResourceItem(sourceID: item.sourceID, title: item.title, locator: $0.absoluteString, kind: item.kind, thumbnail: item.thumbnail)
        }
        return .media(MediaAsset(url: media, headers: headers, nextEpisode: next, format: result["type"] as? String))
    }
    private func localDocument(_ item: ResourceItem) async throws -> URL {
        var headers = ["Referer": item.locator]
        if let url = URL(string: item.locator), let cookie = await SourceWebSession.cookieHeader(id: definition.id, url: url) { headers["Cookie"] = cookie }
        return try await ResourceAccess.shared.localFile(for: item, headers: headers, scope: revision)
    }
    func close() { catalogEngine.cancel(); compiled.removeAll() }
    private static let genericCatalog = PageModule(items: "a[href]", fields: [
        "title": SelectorField(selector: nil),
        "url": SelectorField(attribute: "href"),
        "thumbnail": SelectorField(shorthand: "img@src")
    ], kind: .web)
}

enum SearchURL {
    static func resolve(template: String, query: String, base: URL) throws -> URL {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: allowed),
              let url = URL(string: template.replacingOccurrences(of: "{query}", with: encoded), relativeTo: base)?.absoluteURL,
              ["http", "https"].contains(url.scheme ?? "") else { throw CoveError.message("搜索地址无效") }
        return url
    }
}

enum ResourceParser {
    static func object(_ text: String) throws -> [String: Any] {
        guard let data = text.data(using: .utf8), let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CoveError.message("解析结果应为对象")
        }
        return object
    }
    static func catalog(_ text: String, sourceID: String, base: URL, defaultKind: ResourceKind, episodes: EpisodeModule? = nil) throws -> [ResourceItem] {
        guard let data = text.data(using: .utf8), let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw CoveError.message("列表解析结果应为数组")
        }
        let dates = ISO8601DateFormatter()
        var seen = Set<String>()
        return array.compactMap { value in
            guard let raw = value["url"] as? String, let url = URL(string: raw, relativeTo: base)?.absoluteURL,
                  ["http", "https"].contains(url.scheme ?? ""), seen.insert(url.absoluteString).inserted else { return nil }
            let title = (value["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }
            let tags = value["tags"] as? [String] ?? (value["extra"] as? String ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            let kind = (value["kind"] as? String).flatMap(ResourceKind.init(rawValue:)) ?? defaultKind
            let thumbnail = (value["thumbnail"] as? String).flatMap { URL(string: $0, relativeTo: base)?.absoluteURL.absoluteString }
            let count = episodes.flatMap { config -> Int? in
                if let number = value[config.countField] as? Int { return number }
                guard let text = value[config.countField] as? String else { return nil }
                return text.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }.max()
            }
            let modified = (value["modifiedAt"] as? String).flatMap(dates.date(from:))
                ?? (value["modifiedAt"] as? Double).map(Date.init(timeIntervalSince1970:))
            return ResourceItem(sourceID: sourceID, title: title, locator: url.absoluteString, kind: kind,
                                identity: value["id"] as? String, thumbnail: thumbnail,
                                subtitle: value["duration"] as? String ?? "", tags: tags, byteSize: (value["byteSize"] as? NSNumber)?.int64Value, modifiedAt: modified, format: value["format"] as? String, episodeCount: count)
        }
    }
}
