import Foundation
import Yams

/// A transient edit buffer. The only saved format remains SiteDefinition.
indirect enum SiteFormValue: Codable, Equatable, Sendable {
    case object([String: SiteFormValue]), array([SiteFormValue]), string(String), number(Double), bool(Bool), null
    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let v = try? value.decode(Bool.self) { self = .bool(v) }
        else if let v = try? value.decode(Double.self) { self = .number(v) }
        else if let v = try? value.decode(String.self) { self = .string(v) }
        else if let v = try? value.decode([String: Self].self) { self = .object(v) }
        else { self = .array(try value.decode([Self].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .object(let v): try value.encode(v)
        case .array(let v): try value.encode(v)
        case .string(let v): try value.encode(v)
        case .number(let v): try value.encode(v)
        case .bool(let v): try value.encode(v)
        case .null: try value.encodeNil()
        }
    }
    var object: [String: Self] { if case .object(let v) = self { return v }; return [:] }
    var array: [Self] { if case .array(let v) = self { return v }; return [] }
    var string: String { if case .string(let v) = self { return v }; return "" }
    var bool: Bool { if case .bool(let v) = self { return v }; return false }
}

enum SiteFormPart: Hashable { case key(String), index(Int) }
typealias SiteFormPath = [SiteFormPart]

@Observable @MainActor final class SiteFormModel {
    private(set) var root: SiteFormValue = .object([:])
    private var numberText: [SiteFormPath: String] = [:]

    func load(_ definition: SiteDefinition) throws {
        root = try JSONDecoder().decode(SiteFormValue.self, from: JSONEncoder().encode(definition))
        numberText = [:]
    }
    func definition(validate: Bool = true) throws -> SiteDefinition {
        for (path, text) in numberText where value(at: path) != nil {
            guard let number = Double(text), number.isFinite else {
                throw SiteDefinitionError.invalid("请填写有效数值：\(path.compactMap { if case .key(let key) = $0 { return SiteFormSpec.label(key) }; return nil }.last ?? "数值")")
            }
        }
        let value = try JSONDecoder().decode(SiteDefinition.self, from: JSONEncoder().encode(root))
        if validate { try value.validate() }
        return value
    }
    static func sourceDraft(_ text: String) throws -> SiteDefinition {
        // Structural checks prevent unknown fields from disappearing on a form round trip.
        try SiteSchema.check(text)
        return try YAMLDecoder().decode(SiteDefinition.self, from: text)
    }
    func value(at path: SiteFormPath) -> SiteFormValue? {
        var current = root
        for part in path {
            switch part {
            case .key(let key): guard let value = current.object[key] else { return nil }; current = value
            case .index(let index): guard current.array.indices.contains(index) else { return nil }; current = current.array[index]
            }
        }
        return current
    }
    func set(_ value: SiteFormValue?, at path: SiteFormPath) {
        func replacing(_ node: SiteFormValue, _ parts: ArraySlice<SiteFormPart>) -> SiteFormValue {
            guard let part = parts.first else { return value ?? .null }
            switch part {
            case .key(let key):
                var object = node.object
                if parts.count == 1 { object[key] = value }
                else { object[key] = replacing(object[key] ?? .object([:]), parts.dropFirst()) }
                return .object(object)
            case .index(let index):
                var array = node.array
                guard array.indices.contains(index) else { return node }
                if parts.count == 1, value == nil { array.remove(at: index) }
                else { array[index] = replacing(array[index], parts.dropFirst()) }
                return .array(array)
            }
        }
        root = replacing(root, path[...])
        if value == nil {
            let parent = Array(path.dropLast())
            if case .index(let removed)? = path.last {
                var updated: [SiteFormPath: String] = [:]
                for (key, text) in numberText {
                    var newPath = key
                    if key.starts(with: parent), key.count > parent.count, case .index(let index) = key[parent.count] {
                        if index == removed { continue }
                        if index > removed { newPath[parent.count] = .index(index - 1) }
                    }
                    updated[newPath] = text
                }
                numberText = updated
            } else { numberText = numberText.filter { !$0.key.starts(with: path) } }
        }
    }
    func numericText(at path: SiteFormPath) -> String {
        if let text = numberText[path] { return text }
        if case .number(let v)? = value(at: path) { return NSNumber(value: v).stringValue }
        return ""
    }
    func setNumber(_ text: String, at path: SiteFormPath) {
        numberText[path] = text
        if let value = Double(text), value.isFinite { set(.number(value), at: path) }
    }
    func append(_ value: SiteFormValue, at path: SiteFormPath) {
        set(.array((self.value(at: path)?.array ?? []) + [value]), at: path)
    }
    func reorder(_ order: [Int], at path: SiteFormPath) {
        let values = value(at: path)?.array ?? []
        guard order.sorted() == Array(values.indices) else { return }
        set(.array(order.map { values[$0] }), at: path)
        var updated: [SiteFormPath: String] = [:]
        for (key, text) in numberText {
            var newPath = key
            if key.starts(with: path), key.count > path.count, case .index(let index) = key[path.count], let position = order.firstIndex(of: index) {
                newPath[path.count] = .index(position)
            }
            updated[newPath] = text
        }
        numberText = updated
    }
}

/// UI metadata uses the same field names as the validator, never a second wire schema.
enum SiteFormSpec {
    indirect enum Kind { case text, inlineCode, code, number, bool, choices([(String, String)]), object(String), list(Kind), map(Kind) }
    static func label(_ key: String) -> String {
        ["blocks":"正文图文块", "publishedAt":"发布时间", "sourceURL":"原文地址", "commentsURL":"评论地址", "schemaVersion":"格式版本", "id":"标识", "name":"名称", "match":"匹配条件", "hosts":"域名", "includeSubdomains":"包含子域名", "hostPattern":"域名正则", "pathPrefix":"路径前缀", "pathPattern":"路径正则", "query":"查询参数", "entries":"入口", "path":"地址 / 路径", "category":"分类", "rules":"解析规则", "role":"页面角色", "contentType":"内容类型", "priority":"优先级", "load":"加载方式", "mode":"方式", "waitSeconds":"等待秒数", "preNavigateScript":"跳转脚本", "preNavigateExpression":"跳转表达式", "transformScript":"HTML 转换脚本", "headers":"请求头", "presentation":"展示与交互", "layout":"布局", "mixedMedia":"混合图文", "episodeCountField":"集数字段", "episodeURLTemplate":"分集地址模板", "extract":"内容提取", "items":"列表卡片选择器", "fields":"字段", "script":"JavaScript 函数体", "expression":"JavaScript 表达式", "selector":"CSS 选择器", "text":"读取文本", "attribute":"读取属性", "fallbackAttributes":"备用属性", "all":"返回数组", "number":"转换为数值", "content":"提取原生图文块", "resolveURL":"补全地址", "pattern":"提取正则", "capture":"捕获组", "value":"固定值", "pagination":"分页", "thumbnailScript":"缩略图脚本", "categories":"分类入口", "searchURLTemplate":"搜索地址模板", "request":"请求解析", "capturePattern":"页面捕获正则", "urlTemplate":"请求地址模板", "responsePattern":"响应捕获正则", "exclude":"排除内容", "portal":"门户解析", "url":"地址", "base64Pattern":"Base64 捕获正则", "dataPattern":"加密数据正则", "keyPattern":"密钥捕获正则", "urlPaths":"地址字段路径", "identityPaths":"身份字段路径", "identityPattern":"身份正则", "excludedHosts":"排除域名", "images":"图片解码", "key":"AES 密钥", "iv":"IV"][key] ?? key
    }
    static func names(_ type: String) -> [String] {
        let first = ["schemaVersion", "id", "name", "role", "category", "match", "entries", "rules", "portal", "images"]
        return SiteSchema.fieldNames(for: type).sorted {
            let a = first.firstIndex(of: $0) ?? first.count, b = first.firstIndex(of: $1) ?? first.count
            return a == b ? $0 < $1 : a < b
        }
    }
    static func required(_ key: String, type: String) -> Bool {
        ["site": ["schemaVersion", "id", "name", "match", "entries", "rules"], "entry": ["id", "name", "path", "category"], "rule": ["id", "role"], "category": ["name", "path"], "pagination": ["mode"], "portal": ["url"], "images": ["key", "iv"], "request": ["capturePattern", "urlTemplate", "responsePattern"]][type]?.contains(key) == true
    }
    static func kind(_ key: String, type: String) -> Kind {
        switch (type, key) {
        case ("entry", "category"): return .choices(SiteCategory.allCases.map { ($0.configurationValue, $0.rawValue) })
        case ("rule", "role"): return .choices([("catalog","列表"),("video","视频详情"),("comic","漫画详情"),("chapter","章节"),("tags","标签"),("article","图文详情")])
        case ("rule", "contentType"): return .choices([("video","视频"),("comic","漫画"),("navLink","目录导航"),("article","图文")])
        case ("load", "mode"): return .choices([("auto","自动"),("webView","网页渲染")])
        case ("pagination", "mode"): return .choices([("none","无分页"),("nextLink","下一页链接"),("webNavigation","网页导航"),("ajax","AJAX")])
        case ("presentation", "layout"): return .choices(BrowserLayout.allCases.map { ($0.rawValue, $0.label) })
        default: break
        }
        if ["match","load","presentation","extract","pagination","request","portal","images"].contains(key) { return .object(key) }
        if key == "entries" { return .list(.object("entry")) }
        if key == "rules" { return .list(.object("rule")) }
        if key == "categories" { return .list(.object("category")) }
        if key == "fields" { return .map(.object("field")) }
        if ["headers","query"].contains(key) { return .map(.text) }
        if ["hosts","fallbackAttributes","urlPaths","identityPaths","excludedHosts","exclude"].contains(key) { return .list(.text) }
        if ["schemaVersion","waitSeconds","priority","capture"].contains(key) { return .number }
        if ["includeSubdomains","mixedMedia","text","all","number","resolveURL","content"].contains(key) { return .bool }
        if ["script","expression","preNavigateScript","preNavigateExpression","transformScript","thumbnailScript"].contains(key) { return .code }
        if key == "selector" || key.hasSuffix("Pattern") || key == "pattern" { return .inlineCode }
        return .text
    }
    static func initial(_ kind: Kind) -> SiteFormValue {
        switch kind {
        case .text, .inlineCode, .code: return .string("")
        case .number: return .number(0)
        case .bool: return .bool(false)
        case .choices(let options): return .string(options.first?.0 ?? "")
        case .list: return .array([])
        case .map: return .object([:])
        case .object(let type):
            if type == "entry" { return .object(["id":.string("entry." + String(UUID().uuidString.prefix(8))), "name":.string("新入口"), "path":.string("/"), "category":.string("video")]) }
            if type == "rule" {
                let rule = SiteDefinition.starter(name: "示例", url: URL(string: "https://media.example/")!).rules[0]
                var value = (try? JSONDecoder().decode(SiteFormValue.self, from: JSONEncoder().encode(rule))) ?? .object([:])
                var object = value.object; object["id"] = .string("rule." + String(UUID().uuidString.prefix(8))); value = .object(object)
                return value
            }
            if type == "field" { return .object(["text":.bool(true)]) }
            return .object(Dictionary(uniqueKeysWithValues: names(type).filter { required($0, type: type) }.map { ($0, initial(Self.kind($0, type: type))) }))
        }
    }
}
