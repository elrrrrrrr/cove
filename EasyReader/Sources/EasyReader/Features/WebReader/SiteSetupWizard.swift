import SwiftUI
import SwiftData

/// The normal path edits CSS selectors; the advanced path edits the same complete YAML definition.
struct SiteSetupWizard: View {
    var existing: BookmarkSite?
    var imported: SiteDefinition?
    var initialURL: URL?
    var onSaved: (() -> Void)?
    var opensConfiguration = false
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var library = SiteDefinitionStore.shared
    @State private var picker = SiteElementPicker()
    @State private var draft: SiteDefinition?
    @State private var name = ""
    @State private var address = "https://"
    @State private var step = 0
    @State private var activeRuleID = "catalog"
    @State private var selectedField: String?
    @State private var preview = ""
    @State private var previewCount: Int?
    @State private var testing = false
    @State private var yamlText = ""
    @State private var advancedMode = 0
    @State private var scriptText = ""
    @State private var error: String?
    @State private var exporting = false
    @State private var exportDocument = SiteFileDocument(text: "")
    @State private var configurationNeedsSaving = false
    @State private var formModel = SiteFormModel()

    private var ruleIndex: Int? { draft?.rules.firstIndex { $0.id == activeRuleID } }
    private var activeRule: SiteRule? { ruleIndex.flatMap { draft?.rules[$0] } }
    private var fieldNames: [String] {
        switch activeRule?.role {
        case "video": ["url", "title", "nextPageURL", "episodeNumber", "episodeCount"]
        case "article": ["title", "author", "publishedAt", "blocks", "sourceURL", "commentsURL"]
        case "comic": ["title", "author", "status", "desc", "cover", "tags", "chapters"]
        case "chapter": ["images", "bookName", "chapterName", "prevChapter", "nextChapter"]
        case "tags": ["tags"]
        default: ["title", "url", "thumbnail", "duration", "extra"]
        }
    }
    private var isScriptRule: Bool { activeRule?.extract?.script != nil || activeRule?.extract?.expression != nil }
    private var editorName: String {
        switch advancedMode { case 2: "表单"; case 0: "源码"; default: "JavaScript" }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !opensConfiguration {
                    Picker("设置步骤", selection: Binding(get: { step }, set: changeStep)) {
                        Text("基本").tag(0); Text("点选").tag(1); Text("预览").tag(2); Text("高级").tag(3)
                    }.pickerStyle(.segmented).padding()
                }
                if step == 0 { basics }
                else if step == 1 { selectorEditor }
                else if step == 2 { previewView }
                else { advancedEditor }
                if let error { Text(error).font(.caption).foregroundStyle(.red).padding().textSelection(.enabled) }
            }
            .appSurface()
            .navigationTitle(opensConfiguration ? "站点配置" : (existing == nil ? "站点解析引导" : "编辑解析规则"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                if opensConfiguration || step == 3 {
                    ToolbarItem(placement: .topBarTrailing) { configurationMenu }
                }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { save() }.disabled(draft == nil) }
                ToolbarItem(placement: .bottomBar) {
                    Button("导出 .site", systemImage: "square.and.arrow.up") { export() }.disabled(draft == nil)
                }
            }
            .onAppear { initialize() }
            .onDisappear { picker.stop() }
            .onChange(of: picker.selection) { _, value in if let value { applySelection(value) } }
            .fileExporter(isPresented: $exporting, document: exportDocument, contentType: .coveSite,
                          defaultFilename: (draft?.id ?? "site") + ".site") { result in
                if case .failure(let issue) = result { error = issue.localizedDescription }
            }
        }
    }

    private var configurationMenu: some View {
        Menu {
            Section("编辑配置") {
                Button("表单编辑", systemImage: "slider.horizontal.3") { showEditor(2) }
                Button("查看源码", systemImage: "chevron.left.forwardslash.chevron.right") { showEditor(0) }
                if !opensConfiguration {
                    Button("JavaScript", systemImage: "curlybraces") { showEditor(1) }
                }
            }
            if opensConfiguration {
                Section("解析工具") {
                    Button("基本设置", systemImage: "gearshape") { changeStep(0) }
                    Button("网页点选", systemImage: "hand.tap") { changeStep(1) }
                    Button("解析预览", systemImage: "play") { changeStep(2) }
                }
            }
        } label: {
            Text(step == 3 ? editorName : "配置工具")
        }
        .accessibilityLabel("配置工具")
        .accessibilityIdentifier("site-configuration-tools")
        .accessibilityValue(step == 3 ? editorName : "解析工具")
    }

    private var basics: some View {
        Form {
            Section("站点") {
                TextField("站点名称", text: $name)
                TextField("入口 URL", text: $address).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button(draft == nil ? "创建配置并打开页面" : "打开页面") { openPage() }
            }
            if let draft {
                Section("配置身份") {
                    Text(draft.id).font(.caption).textSelection(.enabled)
                    Text("一份配置可以包含多个入口和页面规则。修改完整 YAML 可调整入口、匹配域名和分类。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                rulePicker
                Section("添加页面规则") {
                    ForEach(["catalog", "video", "comic", "chapter", "tags", "article"], id: \.self) { role in
                        Button("添加\(roleName(role))规则") { addRule(role: role) }
                    }
                }
            }
        }
    }

    private var rulePicker: some View {
        Section("当前规则") {
            Picker("规则", selection: $activeRuleID) {
                ForEach(draft?.rules ?? []) { rule in Text("\(roleName(rule.role)) · \(rule.id)").tag(rule.id) }
            }
            if activeRule?.role == "catalog" {
                Picker("内容类型", selection: contentTypeBinding) {
                    Text("视频").tag("video"); Text("漫画").tag("comic"); Text("目录导航").tag("navLink"); Text("图文").tag("article")
                }
                Picker("布局", selection: layoutBinding) {
                    Text("视频网格").tag("bento"); Text("竖版网格").tag("portrait"); Text("列表").tag("list")
                }
            }
            TextField("路径匹配正则（留空匹配全部路径）", text: pathBinding)
                .font(.system(.caption, design: .monospaced)).textInputAutocapitalization(.never).autocorrectionDisabled()
            Toggle("等待网页 JavaScript 渲染", isOn: needsJSBinding)
        }
    }

    private var selectorEditor: some View {
        VStack(spacing: 0) {
            HStack {
                Text(picker.currentURL?.absoluteString ?? address).font(.caption).lineLimit(1)
                Spacer()
                if picker.isLoading { ProgressView() }
                Button("打开") { openPage() }
            }.padding(.horizontal)
            SitePickerWebView(picker: picker).frame(minHeight: 180).layoutPriority(1)
            Form {
                rulePicker
                if isScriptRule {
                    Section {
                        Text("此规则使用 JavaScript，可以在高级模式编辑并预览。")
                        Button("改用 CSS 选择器") { updateRule { $0.extract = defaultExtraction(role: $0.role); $0.request = nil } }
                    }
                } else {
                    if activeRule?.role == "catalog" { selectorRow("items", label: "列表卡片") }
                    ForEach(fieldNames, id: \.self) { field in selectorRow(field, label: fieldName(field)) }
                    if activeRule?.role == "catalog" { selectorRow("nextPage", label: "下一页链接") }
                }
                if let selectedField {
                    Section { Text("请在网页中点选：\(fieldName(selectedField))。再次点击同一按钮可退出点选。") }
                }
                if let pickerError = picker.error { Section { Text(pickerError).foregroundStyle(.red) } }
            }.frame(minHeight: 200, maxHeight: 360)
        }
    }

    private func selectorRow(_ field: String, label: String) -> some View {
        Section(label) {
            HStack {
                TextField("CSS 选择器", text: selectorBinding(field)).font(.system(.caption, design: .monospaced))
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Button {
                    selectedField = selectedField == field ? nil : field
                    picker.pick(field: selectedField, items: activeRule?.extract?.items)
                } label: { Image(systemName: selectedField == field ? "hand.tap.fill" : "hand.tap") }
                    .accessibilityLabel("点选\(label)")
            }
            if field != "items" && field != "nextPage" && field != "chapters" {
                TextField("读取属性（留空读取文本）", text: attributeBinding(field)).font(.system(.caption, design: .monospaced))
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            }
        }
    }

    private var previewView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("在当前网页执行所选规则，检查标题、地址、图片与分页。")
                Button { runPreview() } label: {
                    if testing { ProgressView() } else { Label("运行解析预览", systemImage: "play.fill") }
                }.buttonStyle(.borderedProminent).disabled(draft == nil || testing || picker.isLoading)
                if let previewCount { Text("提取结果：\(previewCount) 项").font(.headline) }
                Text(preview.isEmpty ? "尚未运行预览" : preview).font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }.padding()
        }
    }

    private var advancedEditor: some View {
        VStack(alignment: .leading) {
            if advancedMode == 2 {
                if configurationNeedsSaving {
                    Text("尚未保存站点规则，以下为配置草稿。")
                        .font(.caption).foregroundStyle(.secondary).padding(.horizontal)
                }
                SiteSchemaForm(model: formModel, readonlyID: existing != nil)
            } else if advancedMode == 0 {
                if opensConfiguration {
                    Text(configurationNeedsSaving ? "尚未保存站点规则，以下为配置草稿。" : "当前完整配置 · schemaVersion \(draft?.schemaVersion ?? 1)")
                        .font(.caption).foregroundStyle(.secondary).padding(.horizontal)
                }
                Text("完整 YAML：常规提取使用 fields，复杂提取使用 script: | 和 return。")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal)
                CodeTextEditor(text: $yamlText, label: "完整站点 YAML")
                Button("校验并应用 YAML") { applyYAML() }.buttonStyle(.bordered).padding()
            } else {
                Text("当前规则：\(activeRuleID)。脚本支持 await，使用 return 返回解析结果。")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal)
                CodeTextEditor(text: Binding(get: { scriptText }, set: { text in
                    scriptText = text
                    updateRule { $0.extract = .init(script: text); $0.request = nil }
                }), label: "自定义 JavaScript")
                HStack {
                    Button("清空脚本") { scriptText = "" }
                    Spacer()
                    Button("预览脚本结果") { changeStep(2); if step == 2 { runPreview() } }
                }.padding()
            }
        }
    }

    private func initialize() {
        guard draft == nil else { return }
        if let imported { draft = imported }
        else if let existing, let url = existing.url {
            let saved = library.definition(id: existing.definitionID) ?? SiteParserRegistry.definition(for: url)
            configurationNeedsSaving = saved == nil
            draft = saved ?? .starter(name: existing.name, url: url)
            if saved == nil { draft?.entries[0].category = existing.category.configurationValue }
            if let overrides = existing.parserOverrides { materialize(overrides, url: url) }
        } else if let initialURL { draft = .starter(name: initialURL.host() ?? "新站点", url: initialURL) }
        if let draft {
            name = draft.name
            address = existing?.urlString ?? draft.entries.first?.url(in: draft)?.absoluteString ?? "https://"
            activeRuleID = draft.rules.first?.id ?? "catalog"
            if opensConfiguration {
                advancedMode = 2
                do { try formModel.load(draft) } catch { self.error = error.localizedDescription }
                step = 3
            } else if let url = URL(string: address) { picker.load(url) }
        }
    }

    private func openPage() {
        guard let url = URL(string: address), ["http", "https"].contains(url.scheme ?? ""), url.host() != nil else {
            error = "请输入有效的网页 URL"; return
        }
        if draft == nil { draft = .starter(name: name.isEmpty ? url.host() ?? "新站点" : name, url: url) }
        let alreadyLoaded = picker.currentURL == url
        changeStep(1)
        if step == 1 && (alreadyLoaded || picker.currentURL != url) { picker.load(url) }
    }

    private func editorDraft() throws -> SiteDefinition {
        let value: SiteDefinition
        switch advancedMode {
        case 2: value = try formModel.definition(validate: false)
        case 0: value = try SiteFormModel.sourceDraft(yamlText)
        default:
            guard var current = draft, let index = ruleIndex else { throw SiteDefinitionError.invalid("请选择需要编辑的规则") }
            current.rules[index].extract = .init(script: scriptText); current.rules[index].request = nil
            value = current
        }
        return value
    }
    private func adopt(_ value: SiteDefinition) {
        draft = value; name = value.name
        if !value.rules.contains(where: { $0.id == activeRuleID }) { activeRuleID = value.rules.first?.id ?? "catalog" }
        preview = ""; previewCount = nil
    }
    private func prepareEditor(_ mode: Int) throws {
        guard let draft else { return }
        switch mode {
        case 2: try formModel.load(draft)
        case 0: yamlText = try draft.yaml()
        default: scriptText = activeRule?.extract?.script ?? activeRule?.extract?.expression.map { "return await (\($0));" } ?? "return [];"
        }
    }
    private func changeEditor(_ mode: Int) {
        guard mode != advancedMode else { return }
        do {
            adopt(try editorDraft())
            try prepareEditor(mode)
            advancedMode = mode; error = nil
        } catch { self.error = error.localizedDescription }
    }
    private func showEditor(_ mode: Int) {
        changeStep(3)
        if step == 3 { changeEditor(mode) }
    }
    private func changeStep(_ next: Int) {
        guard next != step else { return }
        do {
            if step == 3, draft != nil { adopt(try editorDraft()) }
            if step == 0, draft != nil, !name.isEmpty { draft?.name = name }
            if next == 3 { try prepareEditor(advancedMode) }
            step = next; error = nil
            if (next == 1 || next == 2), picker.currentURL == nil, !picker.isLoading, let url = URL(string: address) { picker.load(url) }
            if next != 1 { selectedField = nil; if picker.currentURL != nil { picker.pick(field: nil, items: nil) } }
        } catch { self.error = error.localizedDescription }
    }

    private func updateRule(_ body: (inout SiteRule) -> Void) {
        guard var value = draft, let index = value.rules.firstIndex(where: { $0.id == activeRuleID }) else { return }
        body(&value.rules[index]); draft = value; preview = ""; previewCount = nil
    }

    private func defaultExtraction(role: String) -> SiteExtraction {
        switch role {
        case "video": .init(fields: ["url": .init(selector: "video source", attribute: "src", resolveURL: true)])
        case "article": .init(fields: ["title": .init(selector: "h1", text: true), "blocks": .init(selector: "article, main", content: true)])
        case "comic": .init(fields: ["title": .init(selector: "h1", text: true), "chapters": .init(selector: "a[data-chapter]", all: true, fields: ["title": .init(text: true), "url": .init(attribute: "href", resolveURL: true)])])
        case "chapter": .init(fields: ["images": .init(selector: "main img", attribute: "src", all: true, resolveURL: true)])
        case "tags": .init(fields: ["tags": .init(selector: "a[rel=tag]", text: true, all: true)])
        default: SiteDefinition.starter(name: "示例", url: URL(string: "https://media.example")!).rules[0].extract!
        }
    }

    private func addRule(role: String) {
        guard var value = draft else { return }
        let id = role + "." + String(value.rules.count + 1)
        value.rules.append(SiteRule(id: id, role: role, contentType: role == "catalog" ? "video" : nil,
            match: SiteMatch(pathPrefix: picker.currentURL?.path), extract: defaultExtraction(role: role)))
        draft = value; activeRuleID = id; changeStep(1)
    }

    private func applySelection(_ value: SitePickedElement) {
        selectorBinding(value.field).wrappedValue = value.selector
        if let attribute = value.attribute, value.field != "items" && value.field != "nextPage" && value.field != "chapters" {
            attributeBinding(value.field).wrappedValue = attribute
        }
        selectedField = nil
        picker.pick(field: nil, items: nil)
    }

    private func selectorBinding(_ field: String) -> Binding<String> {
        Binding(get: {
            if field == "items" { return activeRule?.extract?.items ?? "" }
            if field == "nextPage" { return activeRule?.pagination?.selector ?? "" }
            return activeRule?.extract?.fields?[field]?.selector ?? ""
        }, set: { text in
            updateRule { rule in
                if field == "items" { rule.extract?.items = text.isEmpty ? nil : text; return }
                if field == "nextPage" {
                    rule.pagination = text.isEmpty ? .init(mode: "none") : .init(mode: "nextLink", selector: text, attribute: "href")
                    return
                }
                if rule.extract?.fields == nil { rule.extract = .init(fields: [:]); rule.request = nil }
                if text.isEmpty { rule.extract?.fields?.removeValue(forKey: field); return }
                var value = rule.extract?.fields?[field] ?? SiteField(text: true)
                value.selector = text
                if field == "tags" || field == "images" { value.all = true }
                if field == "images" { value.resolveURL = true; value.attribute = value.attribute ?? "src" }
                if field == "chapters" {
                    value.all = true; value.fields = ["title": .init(text: true), "url": .init(attribute: "href", resolveURL: true)]
                }
                rule.extract?.fields?[field] = value
            }
        })
    }

    private func attributeBinding(_ field: String) -> Binding<String> {
        Binding(get: { activeRule?.extract?.fields?[field]?.attribute ?? "" }, set: { text in
            updateRule { rule in
                guard var value = rule.extract?.fields?[field] else { return }
                value.attribute = text.isEmpty ? nil : text; value.text = text.isEmpty
                rule.extract?.fields?[field] = value
            }
        })
    }

    private var contentTypeBinding: Binding<String> {
        Binding(get: { activeRule?.contentType ?? "video" }, set: { text in updateRule { $0.contentType = text } })
    }
    private var layoutBinding: Binding<String> {
        Binding(get: { activeRule?.presentation?.layout ?? "bento" }, set: { text in updateRule {
            if $0.presentation == nil { $0.presentation = .init() }; $0.presentation?.layout = text
        } })
    }
    private var pathBinding: Binding<String> {
        Binding(get: { activeRule?.match?.pathPattern ?? activeRule?.match?.pathPrefix.map { "^" + NSRegularExpression.escapedPattern(for: $0) } ?? "" }, set: { text in updateRule {
            if $0.match == nil { $0.match = .init() }; $0.match?.pathPrefix = nil; $0.match?.pathPattern = text.isEmpty ? nil : text
        } })
    }
    private var needsJSBinding: Binding<Bool> {
        Binding(get: { activeRule?.load?.mode == "webView" }, set: { value in updateRule {
            if $0.load == nil { $0.load = .init() }; $0.load?.mode = value ? "webView" : "auto"
        } })
    }

    private func runPreview() {
        guard let rule = activeRule, let extraction = rule.extract else { error = "此规则使用请求解析，请通过实际章节页面验证"; return }
        selectedField = nil; picker.pick(field: nil, items: nil)
        testing = true; error = nil
        Task {
            defer { testing = false }
            do {
                guard let raw = try await WebScript.string(extraction.javascript, in: picker.webView),
                      let bytes = raw.data(using: .utf8) else { throw SiteDefinitionError.invalid("解析结果为空") }
                let object = try JSONSerialization.jsonObject(with: bytes, options: [.fragmentsAllowed])
                previewCount = (object as? [Any])?.count ?? (object is NSNull ? 0 : 1)
                let formatted = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed])
                preview = String(data: formatted, encoding: .utf8) ?? raw
                if let pagination = rule.pagination, pagination.mode == "nextLink", let selector = pagination.selector {
                    let next = try await WebScript.string("document.querySelector(\(SiteScript.json(selector)))?.getAttribute(\(SiteScript.json(pagination.attribute ?? "href"))) || ''", in: picker.webView)
                    preview += "\n\n下一页：" + (next?.isEmpty == false ? next! : "未找到")
                }
            } catch { self.error = "预览失败：\(error.localizedDescription)" }
        }
    }

    private func applyYAML() {
        do {
            let value = try SiteDefinition.decode(yamlText)
            adopt(value)
            error = nil; preview = ""; previewCount = nil
        } catch { self.error = error.localizedDescription }
    }

    private func validatedDraft() throws -> SiteDefinition {
        if step == 3 { adopt(try editorDraft()) }
        guard var value = draft else { throw SiteDefinitionError.invalid("请先创建配置") }
        value.name = name.isEmpty ? value.name : name
        try value.validate()
        return value
    }

    private func save() {
        let previousDefinitions = library.definitions
        do {
            let value = try validatedDraft()
            if let existing {
                try library.saveConfiguration(value, for: existing, context: context)
            } else { try library.importDefinition(value, context: context) }
            onSaved?(); dismiss()
        } catch {
            context.rollback()
            try? library.replace(previousDefinitions)
            self.error = error.localizedDescription
        }
    }
    private func export() {
        do { let value = try validatedDraft(); exportDocument = SiteFileDocument(text: try value.yaml()); exporting = true }
        catch { self.error = error.localizedDescription }
    }

    private func materialize(_ overrides: SiteParserOverrides, url: URL) {
        guard let value = draft, let rule = value.rule(for: url, role: "catalog") else { return }
        activeRuleID = rule.id
        let parser = SiteParserRegistry.parser(definition: value, rule: rule).applying(overrides)
        draft?.portal = parser.portal
        updateRule {
            $0.contentType = parser.itemKind.stringValue
            $0.load = .init(mode: parser.needsJS ? "webView" : "auto", waitSeconds: parser.waitSeconds,
                           preNavigateExpression: parser.preNavigateJS, transformScript: parser.transformScript, headers: parser.requestHeaders)
            $0.extract = .init(expression: parser.extractItemsJS)
            $0.presentation = parser.presentation; $0.presentation?.layout = parser.galleryLayout.rawValue
            $0.categories = parser.categories.map { .init(name: $0.name, path: $0.urlString) }
            $0.pagination = .init(mode: parser.paginationMode.typeString,
                script: parser.paginationMode.typeString == "ajax" ? parser.paginationMode.js : nil,
                expression: parser.paginationMode.typeString == "webNavigation" ? parser.paginationMode.js : nil)
        }
    }

    private func roleName(_ value: String) -> String {
        ["catalog": "列表", "video": "视频详情", "comic": "漫画详情", "chapter": "章节图片", "tags": "标签", "article": "图文详情"][value] ?? value
    }
    private func fieldName(_ value: String) -> String {
        ["items": "列表卡片", "title": "标题", "url": "内容链接 / 播放地址", "thumbnail": "缩略图", "duration": "时长", "extra": "附加信息",
         "nextPage": "下一页链接", "nextPageURL": "下一集链接", "episodeNumber": "当前集数", "episodeCount": "总集数", "author": "作者",
         "status": "状态", "desc": "简介", "cover": "封面", "tags": "标签", "article": "图文详情", "chapters": "章节链接", "images": "章节图片",
         "bookName": "作品名", "chapterName": "章节名", "prevChapter": "上一章", "nextChapter": "下一章"][value] ?? value
    }
}
