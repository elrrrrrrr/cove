import Foundation
import Yams

/// A complete, portable site definition. Missing optional settings use engine defaults.
struct SiteDefinition: Codable, Sendable, Equatable, Identifiable {
    var schemaVersion: Int = 1
    var id: String
    var name: String
    var match: SiteMatch
    var entries: [SiteEntry]
    var rules: [SiteRule]
    var portal: SitePortal?
    var images: SiteImageTransform?

    func validate() throws {
        func require(_ condition: Bool, _ message: String) throws {
            if !condition { throw SiteDefinitionError.invalid(message) }
        }
        try require(schemaVersion == 1, "不支持的格式版本：\(schemaVersion)")
        try require(id.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#, options: .regularExpression) != nil, "站点 id 只能包含字母、数字、点、下划线和连字符")
        try require(!name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "站点名称不能为空")
        try match.validate()
        try require(!entries.isEmpty && !rules.isEmpty, "至少需要一个入口和一条解析规则")
        try require(Set(entries.map(\.id)).count == entries.count, "入口 id 重复")
        try require(Set(rules.map(\.id)).count == rules.count, "规则 id 重复")
        for entry in entries {
            try require(!entry.id.isEmpty && !entry.name.isEmpty, "入口 id 和名称不能为空")
            try require(entry.url(in: self) != nil, "入口地址无效：\(entry.path)")
            try require(SiteCategory(configurationValue: entry.category) != nil, "入口分类无效：\(entry.category)")
        }
        for rule in rules {
            try require(!rule.id.isEmpty, "规则 id 不能为空")
            try require(["catalog", "video", "comic", "chapter", "tags"].contains(rule.role), "未知页面角色：\(rule.role)")
            if let match = rule.match { try match.validate(requireHost: false) }
            if let kind = rule.contentType { try require(ItemKind(string: kind) != nil, "未知内容类型：\(kind)") }
            if let layout = rule.presentation?.layout { try require(GalleryLayout(rawValue: layout) != nil, "未知布局：\(layout)") }
            if let seconds = rule.load?.waitSeconds { try require(seconds.isFinite && (0...30).contains(seconds), "等待时间必须在 0–30 秒之间") }
            if let mode = rule.load?.mode { try require(["auto", "webView"].contains(mode), "未知加载方式：\(mode)") }
            try require((rule.extract != nil) != (rule.request != nil), "规则 \(rule.id) 需要且只能选择 extract 或 request")
            if let extract = rule.extract {
                try extract.validate()
                if let fields = extract.fields {
                    if rule.role != "catalog" { try require(extract.items == nil, "非列表页面请通过字段 all 返回数组") }
                    let required: [String]
                    switch rule.role {
                    case "catalog":
                        required = ["title", "url"]
                        try require(extract.items != nil, "列表规则需要 items 选择器")
                    case "video": required = ["url"]
                    case "comic": required = ["chapters"]
                    case "chapter": required = ["images"]
                    case "tags": required = ["tags"]
                    default: required = []
                    }
                    try require(required.allSatisfy { fields[$0] != nil }, "规则 \(rule.id) 缺少字段：\(required.joined(separator: "、"))")
                    let arrayField = ["comic": "chapters", "chapter": "images", "tags": "tags"][rule.role]
                    if let arrayField { try require(fields[arrayField]?.all == true, "字段 \(arrayField) 需要 all: true") }
                }
            }
            if let pagination = rule.pagination {
                try require(["none", "nextLink", "webNavigation", "ajax"].contains(pagination.mode), "未知分页方式：\(pagination.mode)")
                try require(pagination.mode == "none" || pagination.selector != nil || pagination.script != nil || pagination.expression != nil, "分页需要选择器或脚本")
            }
            if let request = rule.request {
                _ = try NSRegularExpression(pattern: request.capturePattern)
                _ = try NSRegularExpression(pattern: request.responsePattern)
            }
        }
        if let portal { try portal.validate() }
        if let images { try images.validate() }
    }

    func rule(for url: URL, role: String) -> SiteRule? {
        rules.filter { $0.role == role && ($0.match?.matches(url) ?? true) }
            .sorted {
                if ($0.priority ?? 0) != ($1.priority ?? 0) { return ($0.priority ?? 0) > ($1.priority ?? 0) }
                if ($0.match?.specificity ?? 0) != ($1.match?.specificity ?? 0) { return ($0.match?.specificity ?? 0) > ($1.match?.specificity ?? 0) }
                return $0.id < $1.id
            }.first
    }

    static func decode(_ yaml: String) throws -> SiteDefinition {
        try SiteSchema.check(yaml)
        let value = try YAMLDecoder().decode(SiteDefinition.self, from: yaml)
        try value.validate()
        return value
    }

    func yaml() throws -> String {
        let encoder = YAMLEncoder()
        encoder.options.allowUnicode = true
        let text = try encoder.encode(self)
        guard var node = try Yams.compose(yaml: text) else { return text }
        let codeKeys: Set<String> = ["script", "expression", "preNavigateScript", "preNavigateExpression", "transformScript", "thumbnailScript"]
        func format(_ node: inout Yams.Node) {
            if var mapping = node.mapping {
                for index in mapping.indices {
                    let key = mapping[index].key
                    var value = mapping[index].value
                    if let name = key.string, codeKeys.contains(name), var scalar = value.scalar {
                        scalar.style = .literal
                        value = .scalar(scalar)
                    } else { format(&value) }
                    mapping[index] = (key: key, value: value)
                }
                node = .mapping(mapping)
            } else if var sequence = node.sequence {
                for index in sequence.indices { format(&sequence[index]) }
                node = .sequence(sequence)
            }
        }
        format(&node)
        return try Yams.serialize(node: node, indent: 2, allowUnicode: true)
    }

    static func starter(name: String, url: URL) -> SiteDefinition {
        SiteDefinition(id: "user." + UUID().uuidString.lowercased(), name: name,
                       match: SiteMatch(hosts: [url.host() ?? ""]),
                       entries: [SiteEntry(id: "main", name: name, path: url.absoluteString, category: "video")],
                       rules: [SiteRule(id: "catalog", role: "catalog", contentType: "video",
                           extract: SiteExtraction(items: ".card", fields: [
                               "title": SiteField(selector: ".title", text: true),
                               "url": SiteField(selector: "a", attribute: "href"),
                               "thumbnail": SiteField(selector: "img", attribute: "src", fallbackAttributes: ["data-src", "data-original"])
                           ]))])
    }
}

struct SiteMatch: Codable, Sendable, Equatable {
    var hosts: [String]?
    var includeSubdomains: Bool?
    /// Explicit regular expression, useful for rotating mirror hosts. Never implicit substring matching.
    var hostPattern: String?
    var pathPrefix: String?
    var pathPattern: String?
    var query: [String: String]?

    var specificity: Int { (pathPrefix?.count ?? 0) + (pathPattern == nil ? 0 : 100) + (query?.count ?? 0) * 100 }

    func validate(requireHost: Bool = true) throws {
        if requireHost && (hosts ?? []).isEmpty && hostPattern == nil {
            throw SiteDefinitionError.invalid("需要匹配域名或 hostPattern")
        }
        for host in hosts ?? [] {
            if host.isEmpty || host.contains(":") || host.contains("/") || host.contains(" ") {
                throw SiteDefinitionError.invalid("hosts 应填写域名：\(host)")
            }
        }
        if let hostPattern { _ = try NSRegularExpression(pattern: hostPattern) }
        if let pathPattern { _ = try NSRegularExpression(pattern: pathPattern) }
    }

    func matches(_ url: URL) -> Bool {
        let host = url.host()?.lowercased() ?? ""
        let components = URLComponents(url: url, resolvingAgainstBaseURL: true)
        let path = components?.path ?? url.path
        let hasHostCondition = !(hosts ?? []).isEmpty || hostPattern != nil
        let hostMatches = (hosts ?? []).contains {
            let value = $0.lowercased()
            return host == value || (includeSubdomains == true && host.hasSuffix("." + value))
        } || hostPattern.map { host.range(of: $0, options: .regularExpression) != nil } == true
        if hasHostCondition && !hostMatches { return false }
        if let pathPrefix, !path.hasPrefix(pathPrefix) { return false }
        if let pathPattern, path.range(of: pathPattern, options: .regularExpression) == nil { return false }
        let items = components?.queryItems ?? []
        return (query ?? [:]).allSatisfy { key, value in items.contains { $0.name == key && $0.value == value } }
    }
}

struct SiteEntry: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var name: String
    var path: String
    var category: String
    func url(in definition: SiteDefinition) -> URL? {
        let base = definition.match.hosts?.first.flatMap { URL(string: "https://" + $0 + "/") }
        guard let url = URL(string: path, relativeTo: base)?.absoluteURL,
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host() != nil else { return nil }
        return url
    }
}

struct SiteRule: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var role: String
    var contentType: String?
    var priority: Int?
    var match: SiteMatch?
    var load: SiteLoad?
    var presentation: SitePresentation?
    var extract: SiteExtraction?
    var pagination: SitePagination?
    var categories: [SiteRuleCategory]?
    var searchURLTemplate: String?
    var request: SiteTextRequest?
}

struct SiteLoad: Codable, Sendable, Equatable {
    var mode: String?
    var waitSeconds: Double?
    var preNavigateScript: String?
    var preNavigateExpression: String?
    /// Receives `html`, returns transformed HTML before resource tags are removed.
    var transformScript: String?
    var headers: [String: String]?
}

struct SitePresentation: Codable, Sendable, Equatable {
    var layout: String?
    var mixedMedia: Bool?
    var episodeCountField: String?
    var episodeURLTemplate: String?
}

struct SiteRuleCategory: Codable, Sendable, Equatable {
    var name: String
    var path: String
}

struct SiteExtraction: Codable, Sendable, Equatable {
    var items: String?
    var fields: [String: SiteField]?
    /// Function body; `return` native objects/arrays. Async JavaScript is supported.
    var script: String?
    /// A complete JavaScript expression.
    var expression: String?

    func validate() throws {
        let choices = (script == nil ? 0 : 1) + (expression == nil ? 0 : 1) + (fields == nil ? 0 : 1)
        guard choices == 1 else { throw SiteDefinitionError.invalid("提取配置需要且只能选择 fields、script 或 expression 中的一种") }
        if let script, script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw SiteDefinitionError.invalid("JavaScript 不能为空") }
        if let expression, expression.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw SiteDefinitionError.invalid("JavaScript 表达式不能为空") }
        if let items, items.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw SiteDefinitionError.invalid("列表选择器不能为空") }
        if let fields {
            guard !fields.isEmpty else { throw SiteDefinitionError.invalid("提取字段不能为空") }
            for field in fields.values { try field.validate() }
        }
    }

    var javascript: String {
        if let expression { return SiteScript.jsonExpression(expression) }
        if let script { return SiteScript.jsonExpression("(async function(){\n" + script + "\n})()") }
        let config = SiteScript.json(self)
        return """
        (async function() {
            const config = \(config);
            \(Self.selectorEngine)
            const roots = config.items ? [...document.querySelectorAll(config.items)] : [document];
            const result = roots.map(root => readFields(root, config.fields));
            return JSON.stringify(config.items ? result : result[0]);
        })()
        """
    }

    static let selectorEngine = #"""
    function readFields(root, fields) {
        const result = {};
        for (const [name, field] of Object.entries(fields || {})) {
            const elements = field.selector ? [...root.querySelectorAll(field.selector)] : [root];
            const values = elements.map(el => {
                if (field.fields) return readFields(el, field.fields);
                if (field.value !== undefined) return field.value;
                let value = field.attribute ? el.getAttribute(field.attribute) : (el.textContent || '').trim();
                for (const attribute of field.fallbackAttributes || []) {
                    if (!value) value = el.getAttribute(attribute);
                }
                if (field.pattern && value) value = value.match(new RegExp(field.pattern))?.[field.capture ?? 1] || '';
                if (value && (field.resolveURL === true || ['url','thumbnail','cover','nextPageURL','prevChapter','nextChapter','images'].includes(name))) {
                    try { value = new URL(value, document.baseURI).href; } catch (_) { value = ''; }
                }
                if (field.number === true || ['episodeNumber','episodeCount'].includes(name)) {
                    const number = Number(value);
                    return value && Number.isFinite(number) ? number : null;
                }
                return value || '';
            });
            result[name] = field.all ? values.filter(v => v !== '') : (values[0] ?? field.value ?? '');
        }
        return result;
    }
    """#
}

struct SiteField: Codable, Sendable, Equatable {
    var selector: String?
    var text: Bool?
    var attribute: String?
    var fallbackAttributes: [String]?
    var all: Bool?
    var number: Bool?
    var resolveURL: Bool?
    var pattern: String?
    var capture: Int?
    var value: String?
    var fields: [String: SiteField]?
    func validate() throws {
        if let selector, selector.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw SiteDefinitionError.invalid("字段选择器不能为空") }
        if let pattern { _ = try NSRegularExpression(pattern: pattern) }
        for nested in fields?.values ?? Dictionary<String, SiteField>().values { try nested.validate() }
    }
}

/// Catch misspelled keys and duplicate YAML keys before Codable can silently discard them.
enum SiteSchema {
    private static let keys: [String: Set<String>] = [
        "site": ["schemaVersion", "id", "name", "match", "entries", "rules", "portal", "images"],
        "match": ["hosts", "includeSubdomains", "hostPattern", "pathPrefix", "pathPattern", "query"],
        "entry": ["id", "name", "path", "category"],
        "rule": ["id", "role", "contentType", "priority", "match", "load", "presentation", "extract", "pagination", "categories", "searchURLTemplate", "request"],
        "load": ["mode", "waitSeconds", "preNavigateScript", "preNavigateExpression", "transformScript", "headers"],
        "presentation": ["layout", "mixedMedia", "episodeCountField", "episodeURLTemplate"],
        "extract": ["items", "fields", "script", "expression"],
        "field": ["selector", "text", "attribute", "fallbackAttributes", "all", "number", "resolveURL", "pattern", "capture", "value", "fields"],
        "pagination": ["mode", "selector", "attribute", "script", "expression", "thumbnailScript"],
        "category": ["name", "path"],
        "request": ["capturePattern", "urlTemplate", "responsePattern", "exclude"],
        "portal": ["url", "base64Pattern", "dataPattern", "keyPattern", "urlPaths", "identityPaths", "identityPattern", "excludedHosts", "headers"],
        "images": ["hosts", "key", "iv"]
    ]

    static func check(_ yaml: String) throws {
        guard let root = try Yams.compose(yaml: yaml), root.mapping != nil else { throw SiteDefinitionError.invalid(".site 顶层必须是 YAML 配置对象") }
        try visit(root, type: "site", path: "site", depth: 0)
    }

    private static func visit(_ node: Yams.Node, type: String?, path: String, depth: Int) throws {
        guard depth < 40 else { throw SiteDefinitionError.invalid("配置嵌套过深") }
        if let mapping = node.mapping {
            var seen: Set<String> = []
            for (key, value) in mapping {
                guard let name = key.string else { throw SiteDefinitionError.invalid("\(path) 的字段名必须是文本") }
                guard seen.insert(name).inserted else { throw SiteDefinitionError.invalid("重复字段：\(path).\(name)") }
                if let type, let allowed = keys[type], !allowed.contains(name) { throw SiteDefinitionError.invalid("未知字段：\(path).\(name)") }
                let childType: String?
                switch (type, name) {
                case ("fields", _): childType = "field"
                case (_, "match"), (_, "load"), (_, "presentation"), (_, "extract"), (_, "pagination"), (_, "portal"), (_, "images"), (_, "request"): childType = name
                case (_, "fields"): childType = "fields"
                case (_, "entries"): childType = "entry"
                case (_, "rules"): childType = "rule"
                case (_, "categories"): childType = "category"
                default: childType = nil
                }
                try visit(value, type: childType, path: path + "." + name, depth: depth + 1)
            }
        } else if let sequence = node.sequence {
            for (index, value) in sequence.enumerated() { try visit(value, type: type, path: path + "[\(index)]", depth: depth + 1) }
        }
    }
}

struct SitePagination: Codable, Sendable, Equatable {
    var mode: String
    var selector: String?
    var attribute: String?
    var script: String?
    var expression: String?
    var thumbnailScript: String?
}

struct SiteTextRequest: Codable, Sendable, Equatable {
    var capturePattern: String
    var urlTemplate: String
    var responsePattern: String
    var exclude: [String]?
}

struct SitePortal: Codable, Sendable, Equatable {
    var url: String
    var base64Pattern: String?
    var dataPattern: String?
    var keyPattern: String?
    var urlPaths: [String]?
    var identityPaths: [String]?
    var identityPattern: String?
    var excludedHosts: [String]?
    var headers: [String: String]?
    func validate() throws {
        guard let value = URL(string: url), ["http", "https"].contains(value.scheme ?? ""), value.host() != nil else { throw SiteDefinitionError.invalid("门户地址无效") }
        for pattern in [base64Pattern, dataPattern, keyPattern, identityPattern].compactMap({ $0 }) { _ = try NSRegularExpression(pattern: pattern) }
    }
}

struct SiteImageTransform: Codable, Sendable, Equatable {
    var hosts: [String]?
    var key: String
    var iv: String
    func validate() throws {
        guard [16, 24, 32].contains(key.utf8.count), iv.utf8.count == 16 else { throw SiteDefinitionError.invalid("AES 密钥或 IV 长度无效") }
    }
}

enum SiteDefinitionError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let value) = self { return value }; return nil }
}

enum SiteScript {
    static func json<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) else { return "null" }
        return text
    }
    static func jsonExpression(_ expression: String) -> String {
        "(async function(){ const value = await (\(expression)); return typeof value === 'string' ? value : JSON.stringify(value); })()"
    }
}

extension SiteCategory {
    init?(configurationValue value: String) {
        switch value {
        case "video": self = .video
        case "comic": self = .comic
        case "image": self = .image
        case "novel": self = .novel
        case "news": self = .news
        case "other": self = .other
        default:
            guard let category = Self(rawValue: value) else { return nil }
            self = category
        }
    }
    var configurationValue: String {
        switch self {
        case .video: "video"
        case .comic: "comic"
        case .image: "image"
        case .novel: "novel"
        case .news: "news"
        case .other: "other"
        }
    }
}
