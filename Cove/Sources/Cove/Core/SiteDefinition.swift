import Foundation
import Yams

/// Portable `.site` definition (`schemaVersion: 1`).
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
        func check(_ condition: Bool, _ message: String) throws {
            if !condition { throw SiteDefinitionError.invalid(message) }
        }
        try check(schemaVersion == 1, "不支持的格式版本：\(schemaVersion)")
        try check(id.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#, options: .regularExpression) != nil,
                  "站点 id 只能包含字母、数字、点、下划线和连字符")
        try check(!name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "站点名称不能为空")
        try match.validate()
        try check(!entries.isEmpty && !rules.isEmpty, "至少需要一个入口和一条解析规则")
        try check(Set(entries.map(\.id)).count == entries.count, "入口 id 重复")
        try check(Set(rules.map(\.id)).count == rules.count, "规则 id 重复")
        for entry in entries {
            try check(!entry.id.isEmpty && !entry.name.isEmpty, "入口 id 和名称不能为空")
            try check(entry.url(in: self) != nil, "入口地址无效：\(entry.path)")
            try check(SiteCategory(configurationValue: entry.category) != nil, "入口分类无效：\(entry.category)")
        }
        for rule in rules {
            try check(!rule.id.isEmpty, "规则 id 不能为空")
            try check(["catalog", "video", "comic", "chapter", "tags", "article"].contains(rule.role), "未知页面角色：\(rule.role)")
            if let match = rule.match { try match.validate(requireHost: false) }
            if let kind = rule.contentType { try check(ItemKind(string: kind) != nil, "未知内容类型：\(kind)") }
            if let layout = rule.presentation?.layout { try check(BrowserLayout(rawValue: layout) != nil, "未知布局：\(layout)") }
            if let seconds = rule.load?.waitSeconds { try check(seconds.isFinite && (0...30).contains(seconds), "等待时间必须在 0–30 秒之间") }
            if let mode = rule.load?.mode { try check(["auto", "webView"].contains(mode), "未知加载方式：\(mode)") }
            try check((rule.extract != nil) != (rule.request != nil), "规则 \(rule.id) 需要且只能选择 extract 或 request")
            if let extract = rule.extract {
                try extract.validate()
                if let fields = extract.fields {
                    if rule.role != "catalog" { try check(extract.items == nil, "非列表页面请通过字段 all 返回数组") }
                    let required: [String] = switch rule.role {
                    case "catalog": ["title", "url"]
                    case "video": ["url"]
                    case "comic": ["chapters"]
                    case "chapter": ["images"]
                    case "tags": ["tags"]
                    case "article": ["blocks"]
                    default: []
                    }
                    if rule.role == "catalog" { try check(extract.items != nil, "列表规则需要 items 选择器") }
                    try check(required.allSatisfy { fields[$0] != nil }, "规则 \(rule.id) 缺少字段：\(required.joined(separator: "、"))")
                    if let arrayField = ["comic": "chapters", "chapter": "images", "tags": "tags"][rule.role] {
                        try check(fields[arrayField]?.all == true, "字段 \(arrayField) 需要 all: true")
                    }
                    if rule.role == "article" {
                        try check(fields["blocks"]?.content == true || fields["blocks"]?.all == true, "图文详情 blocks 需要 content: true 或 all: true")
                    }
                }
            }
            if rule.role == "article" { try check(rule.extract != nil, "图文详情需要 extract") }
            if let pagination = rule.pagination {
                try check(["none", "nextLink", "webNavigation", "ajax"].contains(pagination.mode), "未知分页方式：\(pagination.mode)")
                try check(pagination.mode == "none" || pagination.selector != nil || pagination.script != nil || pagination.expression != nil, "分页需要选择器或脚本")
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
}

struct SiteMatch: Codable, Sendable, Equatable {
    var hosts: [String]?
    var includeSubdomains: Bool?
    var hostPattern: String?
    var pathPrefix: String?
    var pathPattern: String?
    var query: [String: String]?

    var specificity: Int { (pathPrefix?.count ?? 0) + (pathPattern == nil ? 0 : 100) + (query?.count ?? 0) * 100 }

    func validate(requireHost: Bool = true) throws {
        if requireHost && (hosts ?? []).isEmpty && hostPattern == nil {
            throw SiteDefinitionError.invalid("需要匹配域名或 hostPattern")
        }
        for host in hosts ?? [] where host.isEmpty || host.contains(":") || host.contains("/") || host.contains(" ") {
            throw SiteDefinitionError.invalid("hosts 应填写域名：\(host)")
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
        return WebURLSafety.resolveURL(path, relativeTo: base)
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
    var script: String?
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

    static var selectorEngine: String { ArticleDOM.script + #"""
    function readFields(root, fields) {
        const result = {};
        for (const [name, field] of Object.entries(fields || {})) {
            const elements = field.selector ? [...root.querySelectorAll(field.selector)] : [root];
            const values = elements.map(el => {
                if (field.content === true) return readArticleContent(el);
                if (field.fields) return readFields(el, field.fields);
                if (field.value !== undefined) return field.value;
                let value = field.attribute ? el.getAttribute(field.attribute) : (el.textContent || '').trim();
                for (const attribute of field.fallbackAttributes || []) {
                    if (!value) value = el.getAttribute(attribute);
                }
                if (field.pattern && value) value = value.match(new RegExp(field.pattern))?.[field.capture ?? 1] || '';
                if (value && (field.resolveURL === true || ['url','thumbnail','titleImage','cover','nextPageURL','prevChapter','nextChapter','images','sourceURL','commentsURL'].includes(name))) {
                    try { value = new URL(value, document.baseURI).href; } catch (_) { value = ''; }
                }
                if (field.number === true || ['episodeNumber','episodeCount'].includes(name)) {
                    const number = Number(value);
                    return value && Number.isFinite(number) ? number : null;
                }
                return value || '';
            });
            result[name] = field.all ? values.filter(v => v !== '') : (values[0] ?? field.value ?? (field.content === true ? [] : ''));
        }
        return result;
    }
    """# }
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
    var content: Bool?

    func validate() throws {
        if let selector, selector.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw SiteDefinitionError.invalid("字段选择器不能为空") }
        if let pattern { _ = try NSRegularExpression(pattern: pattern) }
        if content == true && (attribute != nil || fields != nil || all == true || value != nil || pattern != nil || number == true) {
            throw SiteDefinitionError.invalid("content 图文提取只需 selector 和 content: true")
        }
        for nested in fields?.values ?? Dictionary<String, SiteField>().values { try nested.validate() }
    }
}

enum SiteSchema {
    private static let keys: [String: Set<String>] = [
        "site": ["schemaVersion", "id", "name", "match", "entries", "rules", "portal", "images"],
        "match": ["hosts", "includeSubdomains", "hostPattern", "pathPrefix", "pathPattern", "query"],
        "entry": ["id", "name", "path", "category"],
        "rule": ["id", "role", "contentType", "priority", "match", "load", "presentation", "extract", "pagination", "categories", "searchURLTemplate", "request"],
        "load": ["mode", "waitSeconds", "preNavigateScript", "preNavigateExpression", "transformScript", "headers"],
        "presentation": ["layout", "mixedMedia", "episodeCountField", "episodeURLTemplate"],
        "extract": ["items", "fields", "script", "expression"],
        "field": ["selector", "text", "attribute", "fallbackAttributes", "all", "number", "resolveURL", "pattern", "capture", "value", "fields", "content"],
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
                let childType: String? = switch (type, name) {
                case ("fields", _): "field"
                case (_, "match"), (_, "load"), (_, "presentation"), (_, "extract"), (_, "pagination"), (_, "portal"), (_, "images"), (_, "request"): name
                case (_, "fields"): "fields"
                case (_, "entries"): "entry"
                case (_, "rules"): "rule"
                case (_, "categories"): "category"
                default: nil
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
        guard let value = URL(string: url), WebURLSafety.isWebURL(value) else { throw SiteDefinitionError.invalid("门户地址无效") }
        for pattern in [base64Pattern, dataPattern, keyPattern, identityPattern].compactMap({ $0 }) {
            _ = try NSRegularExpression(pattern: pattern)
        }
    }
}

struct SiteImageTransform: Codable, Sendable, Hashable {
    var hosts: [String]?
    var key: String
    var iv: String

    func validate() throws {
        guard [16, 24, 32].contains(key.utf8.count), iv.utf8.count == 16 else {
            throw SiteDefinitionError.invalid("AES 密钥或 IV 长度无效")
        }
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
}

// MARK: - Article Content & Safe DOM Extraction

struct ArticleDocument: Equatable, Sendable {
    let title: String
    let author: String
    let publishedAt: String
    let sourceURL: URL?
    let commentsURL: URL?
    let blocks: [ArticleBlock]

    static func decode(_ data: Data, base: URL, fallbackTitle: String) throws -> Self {
        guard data.count <= 2 * 1024 * 1024 else { throw SiteDefinitionError.invalid("图文内容超过大小限制") }
        let raw = try JSONDecoder().decode(RawArticle.self, from: data)
        guard raw.blocks.count <= 2000 else { throw SiteDefinitionError.invalid("图文块数量超过限制") }
        var characters = 0
        let blocks = try raw.blocks.enumerated().compactMap { index, block -> ArticleBlock? in
            guard let kind = ArticleBlock.Kind(rawValue: block.type) else { throw SiteDefinitionError.invalid("未知图文块类型：\(block.type)") }
            var attributed = AttributedString()
            for run in block.runs ?? [.init(text: block.text ?? "", url: nil)] {
                characters += run.text.count
                var text = AttributedString(run.text)
                text.link = address(run.url, base: base)
                attributed.append(text)
            }
            guard characters <= 1_000_000 else { throw SiteDefinitionError.invalid("正文文字超过限制") }
            let blockURL = address(block.url, base: base)
            if kind == .image || kind == .link {
                guard blockURL != nil else { return nil }
            } else if String(attributed.characters).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return nil
            }
            return ArticleBlock(
                id: "block-\(index)", kind: kind, text: attributed, url: blockURL,
                alt: String((block.alt ?? "").prefix(1024)), level: min(6, max(1, block.level ?? 2)),
                aspectRatio: (block.width ?? 0) > 0 && (block.height ?? 0) > 0 ? min(100, max(0.01, block.width! / block.height!)) : 16.0 / 9
            )
        }
        let source = address(raw.sourceURL, base: base)
        guard !blocks.isEmpty || (source != nil && source != base) else {
            throw SiteDefinitionError.invalid("此页未提取到正文，可查看原始网页")
        }
        let resolvedTitle = raw.title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? raw.title! : fallbackTitle
        return Self(
            title: String(resolvedTitle.prefix(4096)),
            author: String((raw.author ?? "").prefix(1024)),
            publishedAt: String((raw.publishedAt ?? "").prefix(1024)),
            sourceURL: source,
            commentsURL: address(raw.commentsURL, base: base),
            blocks: blocks
        )
    }

    static func address(_ value: String?, base: URL) -> URL? {
        guard let value, !value.isEmpty, value.utf8.count <= 32_768,
              let url = URL(string: value, relativeTo: base)?.absoluteURL,
              WebURLSafety.isWebURL(url), url.user == nil, url.password == nil else { return nil }
        return url
    }

    private struct RawArticle: Decodable {
        let title: String?; let author: String?; let publishedAt: String?
        let sourceURL: String?; let commentsURL: String?; let blocks: [RawArticleBlock]
    }
    private struct RawArticleBlock: Decodable {
        let type: String; let text: String?; let runs: [ArticleRun]?
        let url: String?; let alt: String?; let level: Int?; let width: Double?; let height: Double?
    }
    private struct ArticleRun: Decodable { let text: String; let url: String? }
}

struct ArticleBlock: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable { case paragraph, heading, image, quote, code, link }
    let id: String
    let kind: Kind
    let text: AttributedString
    let url: URL?
    let alt: String
    let level: Int
    let aspectRatio: Double
}

enum ArticleDOM {
    static let script = #"""
    function readArticleContent(root) {
        const blocks = []; let runs = [], type = 'paragraph', level = 2, characters = 0;
        const ignored = new Set(['SCRIPT','STYLE','IFRAME','FORM','INPUT','BUTTON','NAV','FOOTER','NOSCRIPT','TEMPLATE']);
        const containers = new Set(['P','DIV','SECTION','ARTICLE','MAIN','UL','OL','LI','TABLE','TR','TD']);
        function address(value) {
            if (!value || value.length > 32768) return null;
            try { const u = new URL(value, document.baseURI); return ['http:','https:'].includes(u.protocol) && !u.username && !u.password ? u.href : null; }
            catch (_) { return null; }
        }
        function flush() {
            if (runs.length && runs.map(r => r.text).join('').trim()) {
                runs[0].text = runs[0].text.replace(/^\s+/, '');
                runs[runs.length - 1].text = runs[runs.length - 1].text.replace(/\s+$/, '');
                blocks.push({type, runs, level});
                if (blocks.length > 2000) throw new Error('图文块数量超过限制');
            }
            runs = [];
        }
        function walk(node, link = null) {
            if (node.nodeType === 3) {
                const text = type === 'code' ? node.textContent : node.textContent.replace(/\s+/g, ' ');
                characters += text.length;
                if (characters > 1000000) throw new Error('正文文字超过限制');
                if (text) runs.push({text, url: link});
                return;
            }
            if (node.nodeType !== 1 || ignored.has(node.tagName) || node.hidden || node.getAttribute('aria-hidden') === 'true') return;
            if (node.tagName === 'IMG') {
                flush(); const url = address(node.currentSrc || node.getAttribute('src') || node.getAttribute('data-src'));
                if (url) blocks.push({type:'image', url, alt:node.getAttribute('alt') || '', width:node.naturalWidth || Number(node.getAttribute('width')) || 0, height:node.naturalHeight || Number(node.getAttribute('height')) || 0});
                if (blocks.length > 2000) throw new Error('图文块数量超过限制');
                return;
            }
            if (node.tagName === 'BR') { runs.push({text:'\n', url:link}); return; }
            const heading = /^H[1-6]$/.test(node.tagName);
            const boundary = containers.has(node.tagName) || heading || ['PRE','BLOCKQUOTE'].includes(node.tagName);
            const oldType = type, oldLevel = level;
            if (boundary) flush();
            if (heading) { type = 'heading'; level = Number(node.tagName[1]); }
            else if (node.tagName === 'PRE') type = 'code';
            else if (node.tagName === 'BLOCKQUOTE') type = 'quote';
            const target = node.tagName === 'A' ? address(node.getAttribute('href')) : link;
            for (const child of node.childNodes) walk(child, target);
            if (boundary) flush();
            type = oldType; level = oldLevel;
        }
        walk(root); flush(); return blocks;
    }
    """#
}
