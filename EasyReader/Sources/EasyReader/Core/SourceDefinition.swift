import Foundation
import Yams

enum SourceAdapter: String, Codable, Sendable, CaseIterable, Identifiable {
    case files, smb, web
    var id: String { rawValue }
    var label: String { switch self { case .files: "本地文件"; case .smb: "SMB"; case .web: "网站" } }
    var icon: String { switch self { case .files: "folder"; case .smb: "externaldrive.badge.wifi"; case .web: "globe" } }
}

struct SourceConnection: Codable, Sendable, Equatable {
    var adapter: SourceAdapter
    var url: String?
    var host: String?
    var share: String?
    var username: String?
}

struct SourceEntry: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var name: String
    var path: String
    var kind: ResourceKind?
}

struct SourcePresentation: Codable, Sendable, Equatable {
    var layout: String?
    var openItem: String?
    var feed: FeedPresentation?
}

struct FeedPresentation: Codable, Sendable, Equatable {
    var nextGesture: String?
    var autoplay: Bool?
    var preloadNext: Int?
    var onPlaybackEnd: String?
}

struct SourceModules: Codable, Sendable, Equatable {
    var catalog: PageModule?
    var pagination: PaginationModule?
    var search: SearchModule?
    var login: LoginModule?
    var video: PageModule?
    var audio: PageModule?
    var ebook: PageModule?
    var episodes: EpisodeModule?
    var comic: PageModule?
    var chapter: PageModule?
    var tags: PageModule?
    var portal: SitePortal?
    var images: SiteImageTransform?
}

struct SourceDefinition: Codable, Sendable, Equatable, Identifiable {
    var schemaVersion = 2
    var id: String
    var name: String
    var source: SourceConnection
    var entries: [SourceEntry]?
    var modules: SourceModules?
    var presentation: SourcePresentation?

    var fingerprint: String { StableHash.of(ScriptJSON.encode(self)) }
    var startingEntries: [SourceEntry] {
        entries ?? [SourceEntry(id: "main", name: name, path: source.adapter == .web ? (source.url ?? "/") : "/")]
    }
    func absoluteURL(_ path: String) -> URL? {
        guard let url = URL(string: path, relativeTo: source.url.flatMap(URL.init(string:)))?.absoluteURL,
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host() != nil,
              url.user == nil, url.password == nil else { return nil }
        return url
    }
    func validate() throws {
        func require(_ flag: Bool, _ message: String) throws { if !flag { throw CoveError.message(message) } }
        try require(schemaVersion == 2, "需要使用新的 .site 格式版本 2")
        try require(id.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#, options: .regularExpression) != nil, "来源 id 无效")
        try require(!name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "来源名称不能为空")
        if source.adapter == .web { try require(source.url.flatMap(absoluteURL) != nil, "请输入有效的 HTTP(S) 入口地址") }
        if source.adapter == .smb {
            try require(!(source.host ?? "").isEmpty && !(source.share ?? "").isEmpty, "SMB 需要主机与共享名")
            try require(!(source.host ?? "").contains("/") && !(source.host ?? "").contains(":"), "SMB 主机不包含协议或端口")
        }
        try require(!startingEntries.isEmpty, "至少需要一个入口")
        try require(Set(startingEntries.map(\.id)).count == startingEntries.count, "入口 id 重复")
        for entry in startingEntries {
            try require(!entry.id.isEmpty && !entry.name.isEmpty, "入口身份与名称不能为空")
            if source.adapter == .web { try require(absoluteURL(entry.path) != nil, "入口地址无效") }
        }
        if let layout = presentation?.layout { try require(["grid", "portrait", "list"].contains(layout), "未知列表布局") }
        if let open = presentation?.openItem { try require(["reader", "videoFeed"].contains(open), "未知内容打开方式") }
        if let feed = presentation?.feed {
            if let gesture = feed.nextGesture { try require(["swipeUp", "swipeDown"].contains(gesture), "未知滑动方向") }
            if let preload = feed.preloadNext { try require((0...1).contains(preload), "最多预取下一项") }
            if let end = feed.onPlaybackEnd { try require(["stop", "nextItem", "nextEpisode"].contains(end), "未知播放结束行为") }
        }
        for (role, module) in [("catalog", modules?.catalog), ("video", modules?.video),
                               ("audio", modules?.audio), ("ebook", modules?.ebook),
                               ("comic", modules?.comic), ("chapter", modules?.chapter), ("tags", modules?.tags)] {
            if let module { try module.validate(role: role) }
        }
        try modules?.pagination?.validate()
        if let episodes = modules?.episodes {
            try require(["duration", "title", "extra", "episodeCount"].contains(episodes.countField), "未知集数字段")
            try require(episodes.url.contains("{episode}"), "选集地址需要 {episode} 占位符")
        }
        if let search = modules?.search {
            try require(search.url.contains("{query}"), "搜索地址需要 {query} 占位符")
            try require(absoluteURL(search.url.replacingOccurrences(of: "{query}", with: "test")) != nil, "搜索地址无效")
        }
        if let login = modules?.login { try require(absoluteURL(login.url) != nil, "登录入口无效") }
        try modules?.portal?.validate()
        try modules?.images?.validate()
        if source.adapter != .web {
            try require(modules == nil, "文件和 SMB 来源使用内置目录能力，无需网页解析模块")
        }
    }
    static func read(_ url: URL) throws -> Self {
        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? .max) <= 2 * 1024 * 1024 else { throw CoveError.message(".site 超过 2 MB") }
        return try decode(String(contentsOf: url, encoding: .utf8))
    }
    static func decode(_ text: String) throws -> Self {
        try SourceSchema.check(text)
        let value = try YAMLDecoder().decode(Self.self, from: text)
        try value.validate()
        return value
    }
    func yaml() throws -> String {
        let encoder = YAMLEncoder(); encoder.options.allowUnicode = true
        let text = try encoder.encode(self)
        guard var root = try Yams.compose(yaml: text) else { return text }
        func format(_ node: inout Yams.Node) {
            if var mapping = node.mapping {
                for i in mapping.indices {
                    var value = mapping[i].value
                    if ["script", "expression", "preNavigateScript"].contains(mapping[i].key.string ?? ""),
                       var scalar = value.scalar {
                        scalar.style = .literal; value = .scalar(scalar)
                    } else { format(&value) }
                    mapping[i] = (key: mapping[i].key, value: value)
                }
                node = .mapping(mapping)
            } else if var sequence = node.sequence {
                for i in sequence.indices { format(&sequence[i]) }; node = .sequence(sequence)
            }
        }
        format(&root)
        return try Yams.serialize(node: root, indent: 2, allowUnicode: true)
    }
    static func starter(name: String, adapter: SourceAdapter, url: String) -> Self {
        SourceDefinition(id: "user." + UUID().uuidString.lowercased(), name: name,
                         source: .init(adapter: adapter, url: adapter == .web ? url : nil),
                         modules: adapter == .web ? .init(catalog: .init(items: ".card", fields: [
                            "title": .init(shorthand: ".title"), "url": .init(shorthand: "a@href"),
                            "thumbnail": .init(shorthand: "img@src")
                         ], kind: .video)) : nil)
    }
}

struct RuleMatch: Codable, Sendable, Equatable {
    var pathPrefix: String?
    var pathPattern: String?
    var query: [String: String]?
    func validate() throws { if let pathPattern { _ = try NSRegularExpression(pattern: pathPattern) } }
    func matches(_ url: URL) -> Bool {
        let parts = URLComponents(url: url, resolvingAgainstBaseURL: true)
        let path = parts?.path ?? url.path
        if let pathPrefix, !path.hasPrefix(pathPrefix) { return false }
        if let pathPattern, path.range(of: pathPattern, options: .regularExpression) == nil { return false }
        return (query ?? [:]).allSatisfy { key, value in (parts?.queryItems ?? []).contains { $0.name == key && $0.value == value } }
    }
}

struct PageLoad: Codable, Sendable, Equatable {
    var waitSeconds: Double?
    var headers: [String: String]?
    var preNavigateScript: String?
}

/// The base module is the default rule. Ordered variants override it on matching pages.
struct PageModule: Codable, Sendable, Equatable {
    var items: String?
    var fields: [String: SelectorField]?
    var script: String?
    var expression: String?
    var kind: ResourceKind?
    var match: RuleMatch?
    var load: PageLoad?
    var request: TextRequest?
    var variants: [PageModule]?

    func selected(for url: URL) -> Self? {
        if let selected = variants?.first(where: { $0.match?.matches(url) ?? true }) { return selected }
        return (match?.matches(url) ?? true) ? self : nil
    }
    func validate(role: String, depth: Int = 0) throws {
        guard depth < 8 else { throw CoveError.message("模块变体嵌套过深") }
        try match?.validate()
        if let seconds = load?.waitSeconds, !seconds.isFinite || !(0...30).contains(seconds) {
            throw CoveError.message("等待时间必须为 0–30 秒")
        }
        let count = [fields != nil, script != nil, expression != nil, request != nil].filter { $0 }.count
        if count != 1 { throw CoveError.message("模块 \(role) 需要且只能使用 fields、script、expression 或 request 中的一种") }
        if let script, script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw CoveError.message("脚本不能为空") }
        if let fields {
            let required = ["catalog": ["title", "url"], "video": ["url"], "audio": ["url"], "ebook": ["url"], "comic": ["chapters"], "chapter": ["images"], "tags": ["tags"]][role] ?? []
            guard required.allSatisfy({ fields[$0] != nil }) else { throw CoveError.message("模块 \(role) 缺少必要字段：\(required.joined(separator: "、"))") }
            if role == "catalog", items?.isEmpty != false { throw CoveError.message("列表需要卡片选择器 items") }
            if let array = ["comic": "chapters", "chapter": "images", "tags": "tags"][role], fields[array]?.all != true {
                throw CoveError.message("字段 " + array + " 需要数组提取，可使用 [] 简写")
            }
            if role != "catalog", items != nil { throw CoveError.message("仅列表模块支持 items") }
            for field in fields.values { try field.validate() }
        }
        if let request { _ = try NSRegularExpression(pattern: request.capturePattern); _ = try NSRegularExpression(pattern: request.responsePattern) }
        for variant in variants ?? [] { try variant.validate(role: role, depth: depth + 1) }
    }
    var javascript: String {
        if let expression { return "return await (\(expression));" }
        if let script { return script }
        let config = ScriptJSON.encode(ExtractionSnapshot(items: items, fields: fields))
        return """
        const config = \(config);
        \(Self.selectorEngine)
        const roots = config.items ? [...document.querySelectorAll(config.items)] : [document];
        const result = roots.map(root => readFields(root, config.fields));
        return config.items ? result : result[0];
        """
    }
    private struct ExtractionSnapshot: Encodable { let items: String?; let fields: [String: SelectorField]? }
    private static let selectorEngine = #"""
    function readFields(root, fields) {
        const result = {};
        for (let [name, field] of Object.entries(fields || {})) {
            if (typeof field === 'string') {
                let all = field.endsWith('[]');
                if (all) field = field.slice(0,-2);
                const matched = field.match(/^(.*)@([A-Za-z_:][A-Za-z0-9_:.-]*)$/);
                field = matched ? {selector:matched[1],attribute:matched[2],all} : {selector:field,all};
            }
            const elements = field.selector ? [...root.querySelectorAll(field.selector)] : [root];
            const values = elements.map(el => {
                if (field.fields) return readFields(el, field.fields);
                if (field.value !== undefined) return field.value;
                let value = field.attribute ? el.getAttribute(field.attribute) : (el.textContent || '').trim();
                for (const attribute of field.fallbackAttributes || []) if (!value) value = el.getAttribute(attribute);
                if (field.pattern && value) value = value.match(new RegExp(field.pattern))?.[field.capture ?? 1] || '';
                if (value && (field.resolveURL === true || ['url','thumbnail','cover','images','nextPageURL','prevChapter','nextChapter'].includes(name))) {
                    try { value = new URL(value,document.baseURI).href; } catch (_) { value = ''; }
                }
                if (field.number === true || ['episodeNumber','episodeCount'].includes(name)) return value && Number.isFinite(Number(value)) ? Number(value) : null;
                return value || '';
            });
            result[name] = field.all ? values.filter(v => v !== '') : (values[0] ?? field.value ?? '');
        }
        return result;
    }
    """#
}

struct SelectorField: Codable, Sendable, Equatable {
    var selector: String?
    var attribute: String?
    var text: Bool?
    var all: Bool?
    var fallbackAttributes: [String]?
    var number: Bool?
    var resolveURL: Bool?
    var pattern: String?
    var capture: Int?
    var value: String?
    var fields: [String: SelectorField]?
    init(selector: String? = nil, attribute: String? = nil, all: Bool? = nil) {
        self.selector = selector; self.attribute = attribute; self.all = all
    }
    init(shorthand: String) {
        var value = shorthand
        let many = value.hasSuffix("[]")
        if many { value.removeLast(2) }
        if let range = value.range(of: #"@([A-Za-z_:][A-Za-z0-9_:.-]*)$"#, options: .regularExpression) {
            selector = String(value[..<range.lowerBound])
            attribute = String(value[value.index(after: range.lowerBound)...])
        } else { selector = value; attribute = nil }
        all = many ? true : nil
    }
    var editorShorthand: String {
        (selector ?? "") + (attribute.map { "@" + $0 } ?? "") + (all == true ? "[]" : "")
    }
    func editingShorthand(_ text: String) -> Self {
        let parsed = Self(shorthand: text)
        var result = self
        result.selector = parsed.selector; result.attribute = parsed.attribute; result.all = parsed.all
        return result
    }
    var shorthand: String? {
        guard text == nil, fallbackAttributes == nil, number == nil, resolveURL == nil,
              pattern == nil, capture == nil, value == nil, fields == nil, let selector else { return nil }
        return selector + (attribute.map { "@" + $0 } ?? "") + (all == true ? "[]" : "")
    }
    private enum CodingKeys: String, CodingKey {
        case selector, attribute, text, all, fallbackAttributes, number, resolveURL, pattern, capture, value, fields
    }
    init(from decoder: Decoder) throws {
        if let string = try? decoder.singleValueContainer().decode(String.self) { self.init(shorthand: string); return }
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        selector = try c.decodeIfPresent(String.self, forKey: .selector)
        attribute = try c.decodeIfPresent(String.self, forKey: .attribute)
        text = try c.decodeIfPresent(Bool.self, forKey: .text)
        all = try c.decodeIfPresent(Bool.self, forKey: .all)
        fallbackAttributes = try c.decodeIfPresent([String].self, forKey: .fallbackAttributes)
        number = try c.decodeIfPresent(Bool.self, forKey: .number)
        resolveURL = try c.decodeIfPresent(Bool.self, forKey: .resolveURL)
        pattern = try c.decodeIfPresent(String.self, forKey: .pattern)
        capture = try c.decodeIfPresent(Int.self, forKey: .capture)
        value = try c.decodeIfPresent(String.self, forKey: .value)
        fields = try c.decodeIfPresent([String: SelectorField].self, forKey: .fields)
    }
    func encode(to encoder: Encoder) throws {
        if let shorthand { var c = encoder.singleValueContainer(); try c.encode(shorthand); return }
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(selector, forKey: .selector); try c.encodeIfPresent(attribute, forKey: .attribute)
        try c.encodeIfPresent(text, forKey: .text); try c.encodeIfPresent(all, forKey: .all)
        try c.encodeIfPresent(fallbackAttributes, forKey: .fallbackAttributes)
        try c.encodeIfPresent(number, forKey: .number); try c.encodeIfPresent(resolveURL, forKey: .resolveURL)
        try c.encodeIfPresent(pattern, forKey: .pattern); try c.encodeIfPresent(capture, forKey: .capture)
        try c.encodeIfPresent(value, forKey: .value); try c.encodeIfPresent(fields, forKey: .fields)
    }
    func validate() throws {
        if let selector, selector.isEmpty { throw CoveError.message("CSS 选择器不能为空") }
        if let pattern { _ = try NSRegularExpression(pattern: pattern) }
        if let capture, capture < 0 { throw CoveError.message("正则捕获组无效") }
        for field in fields?.values ?? [:].values { try field.validate() }
    }
}

struct PaginationModule: Codable, Sendable, Equatable {
    var next: SelectorField?
    var script: String?
    var expression: String?
    var mode: String?
    var thumbnailScript: String?
    var variants: [PaginationVariant]?
    func validate() throws {
        if let mode, !["nextLink", "ajax", "webNavigation", "none"].contains(mode) { throw CoveError.message("未知分页模式") }
        if mode != "none", [next != nil, script != nil, expression != nil].filter({ $0 }).count != 1 {
            throw CoveError.message("分页需要且只能选择 next、script 或 expression")
        }
        try next?.validate()
        for variant in variants ?? [] { try variant.match.validate(); try variant.pagination.validate() }
    }
    func selected(for url: URL) -> Self {
        variants?.first(where: { $0.match.matches(url) })?.pagination ?? self
    }
}
struct PaginationVariant: Codable, Sendable, Equatable {
    var match: RuleMatch
    var pagination: PaginationModule
}
struct SearchModule: Codable, Sendable, Equatable { var url: String }
struct LoginModule: Codable, Sendable, Equatable { var url: String }
struct EpisodeModule: Codable, Sendable, Equatable {
    var countField: String
    var url: String
}
struct TextRequest: Codable, Sendable, Equatable {
    var capturePattern: String
    var urlTemplate: String
    var responsePattern: String
    var exclude: [String]?
}

enum ScriptJSON {
    static func encode<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "null"
    }
}

enum SourceSchema {
    private static let keys: [String: Set<String>] = [
        "definition": ["schemaVersion", "id", "name", "source", "entries", "modules", "presentation"],
        "source": ["adapter", "url", "host", "share", "username"],
        "entry": ["id", "name", "path", "kind"],
        "modules": ["catalog", "pagination", "search", "login", "video", "audio", "ebook", "episodes", "comic", "chapter", "tags", "portal", "images"],
        "episodes": ["countField", "url"],
        "page": ["items", "fields", "script", "expression", "kind", "match", "load", "request", "variants"],
        "match": ["pathPrefix", "pathPattern", "query"],
        "load": ["waitSeconds", "headers", "preNavigateScript"],
        "field": ["selector", "attribute", "text", "all", "fallbackAttributes", "number", "resolveURL", "pattern", "capture", "value", "fields"],
        "pagination": ["next", "mode", "script", "expression", "thumbnailScript", "variants"],
        "paginationVariant": ["match", "pagination"],
        "search": ["url"], "login": ["url"],
        "presentation": ["layout", "openItem", "feed"],
        "feed": ["nextGesture", "autoplay", "preloadNext", "onPlaybackEnd"],
        "request": ["capturePattern", "urlTemplate", "responsePattern", "exclude"],
        "portal": ["url", "base64Pattern", "dataPattern", "keyPattern", "urlPaths", "identityPaths", "identityPattern", "excludedHosts", "headers"],
        "images": ["hosts", "key", "iv"]
    ]
    static func check(_ text: String) throws {
        guard text.utf8.count <= 2 * 1024 * 1024, let root = try Yams.compose(yaml: text), root.mapping != nil else {
            throw CoveError.message(".site 必须是小于 2 MB 的 YAML 对象")
        }
        try visit(root, type: "definition", path: "site", depth: 0)
    }
    private static func visit(_ node: Yams.Node, type: String?, path: String, depth: Int) throws {
        guard depth < 32 else { throw CoveError.message("配置嵌套过深") }
        if let mapping = node.mapping {
            var seen = Set<String>()
            for (key, value) in mapping {
                guard let name = key.string, seen.insert(name).inserted else { throw CoveError.message("字段重复或无效：\(path)") }
                if let type, let allowed = keys[type], !allowed.contains(name) { throw CoveError.message("未知字段：\(path).\(name)") }
                let child: String?
                switch (type, name) {
                case ("fields", _): child = "field"
                case ("modules", "catalog"), ("modules", "video"), ("modules", "comic"), ("modules", "chapter"), ("modules", "tags"): child = "page"
                case ("modules", "audio"), ("modules", "ebook"): child = "page"
                case ("page", "variants"): child = "page"
                case ("pagination", "variants"): child = "paginationVariant"
                case (_, "entries"): child = "entry"
                case (_, "fields"): child = "fields"
                case ("pagination", "next"): child = "field"
                default: child = keys[name] != nil ? name : nil
                }
                try visit(value, type: child, path: path + "." + name, depth: depth + 1)
            }
        } else if let sequence = node.sequence {
            for value in sequence { try visit(value, type: type, path: path + "[]", depth: depth + 1) }
        }
    }
}
