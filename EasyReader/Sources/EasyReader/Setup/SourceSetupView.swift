import SwiftUI
import UniformTypeIdentifiers

struct SourceSetupView: View {
    var existing: SourceDefinition?
    @Environment(SourceStore.self) private var sources
    @Environment(\.dismiss) private var dismiss
    @State private var draft = SourceDefinition.starter(name: "", adapter: .web, url: "https://")
    @State private var step = 0
    @State private var password = ""
    @State private var folder: URL?
    @State private var choosingFolder = false
    @State private var picker: SiteElementPicker?
    @State private var showingPicker = false
    @State private var selectedField = "items"
    @State private var role = "catalog"
    @State private var previewURL = ""
    @State private var previewItems: [ResourceItem] = []
    @State private var previewJSON = ""
    @State private var previewMessage = ""
    @State private var testing = false
    @State private var yaml = ""
    @State private var script = ""
    @State private var editingScript = false
    @State private var error: String?
    @State private var exporting = false
    @State private var exportFile = TextDocument(text: "")
    @State private var initialized = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("配置步骤", selection: $step) {
                    Text("来源").tag(0); Text("模块").tag(1); Text("预览").tag(2); Text("高级").tag(3)
                }.pickerStyle(.segmented).padding()
                if step == 0 { sourceForm }
                else if step == 1 { moduleForm }
                else if step == 2 { previewView }
                else { advancedView }
                if let error { Text(error).font(.caption).foregroundStyle(.red).padding().textSelection(.enabled) }
            }
            .navigationTitle(existing == nil ? "添加来源" : "配置来源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { save() } }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("收起键盘") { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
                }
            }
            .task {
                guard !initialized else { return }; initialized = true
                if let existing { draft = existing; password = CredentialVault.load(id: existing.id) ?? "" }
                previewURL = draft.source.url ?? ""
                yaml = (try? draft.yaml()) ?? ""
            }
            .onChange(of: step) { _, value in
                error = nil
                if value == 3 { yaml = (try? draft.yaml()) ?? "" }
            }
            .sheet(isPresented: $showingPicker) { pickerSheet }
            .sheet(isPresented: $editingScript) { scriptSheet }
            .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
                do { folder = try result.get() } catch { self.error = error.localizedDescription }
            }
            .fileExporter(isPresented: $exporting, document: exportFile, contentType: .coveSite, defaultFilename: draft.id) { result in
                if case .failure(let error) = result { self.error = error.localizedDescription }
            }
        }
    }
    private var sourceForm: some View {
        Form {
            Section("资源来源") {
                TextField("名称", text: $draft.name)
                Picker("访问方式", selection: adapterBinding) {
                    ForEach(SourceAdapter.allCases) { Text($0.label).tag($0) }
                }.pickerStyle(.segmented)
                if draft.source.adapter == .web {
                    TextField("入口地址", text: connectionBinding(\.url)).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                } else if draft.source.adapter == .smb {
                    TextField("主机", text: connectionBinding(\.host)).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("共享名", text: connectionBinding(\.share)).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("用户名", text: connectionBinding(\.username)).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("密码（仅存本机）", text: $password)
                } else {
                    Button(folder?.lastPathComponent ?? "选择文件夹") { choosingFolder = true }
                    Text("文件夹授权保存在本机，导出配置不包含授权。").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("入口") {
                ForEach(Array(draft.startingEntries.enumerated()), id: \.element.id) { index, entry in
                    TextField("入口名称", text: entryBinding(index: index, key: \.name))
                    TextField("路径", text: entryBinding(index: index, key: \.path)).textInputAutocapitalization(.never).autocorrectionDisabled()
                    if draft.startingEntries.count > 1 { Button("删除入口", role: .destructive) { var values = draft.startingEntries; values.remove(at: index); draft.entries = values } }
                }
                Button("添加入口") {
                    var values = draft.startingEntries
                    values.append(SourceEntry(id: "entry." + UUID().uuidString.lowercased(), name: "新入口", path: "/"))
                    draft.entries = values
                }
            }
            Button("配置模块") { step = 1 }
        }
    }
    private var moduleForm: some View {
        Form {
            if draft.source.adapter == .web {
                Section("内容模块") {
                    Picker("当前模块", selection: $role) {
                        Text("列表").tag("catalog"); Text("视频").tag("video"); Text("音乐").tag("audio"); Text("电子书").tag("ebook"); Text("漫画详情").tag("comic"); Text("漫画章节").tag("chapter")
                    }.pickerStyle(.navigationLink)
                    Toggle("启用当前模块", isOn: moduleEnabled)
                    if let module = module {
                        if role == "catalog" {
                            Picker("内容类型", selection: kindBinding) {
                                ForEach(ResourceKind.allCases.filter { $0 != .unknown }) { Text($0.label).tag($0) }
                            }.pickerStyle(.navigationLink)
                        }
                        if module.script != nil || module.expression != nil {
                            Text("此模块使用 JavaScript。").font(.caption).foregroundStyle(.secondary)
                            Button("编辑 JavaScript") { openScript() }
                            Button("改用 CSS 选择器") { setModule(Self.defaultModule(role)) }
                        } else {
                            if role == "catalog" { selectorRow("items", label: "列表卡片") }
                            ForEach(fieldsForRole, id: \.self) { selectorRow($0, label: Self.fieldLabel($0)) }
                            Text("文本：.title · 链接：a@href · 多张图片：img@src[]").font(.caption).foregroundStyle(.secondary)
                            Button("使用 JavaScript") { openScript() }
                        }
                    }
                }
                Section("可选能力") {
                    Toggle("分页", isOn: paginationEnabled)
                    if draft.modules?.pagination != nil {
                        TextField("下一页", text: nextBinding).font(.system(.body, design: .monospaced)).textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    Toggle("搜索", isOn: searchEnabled).accessibilityIdentifier("module.search")
                    if draft.modules?.search != nil {
                        TextField("搜索地址，包含 {query}", text: searchBinding).textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    Toggle("网页登录", isOn: loginEnabled)
                    if draft.modules?.login != nil { TextField("登录入口", text: loginBinding).textInputAutocapitalization(.never).autocorrectionDisabled() }
                }
            } else {
                Section { Text("目录浏览、文件识别和阅读播放由 App 提供。") }
            }
            Section("浏览与播放") {
                Picker("列表布局", selection: layoutBinding) {
                    Text("网格").tag("grid"); Text("封面").tag("portrait"); Text("列表").tag("list")
                }.pickerStyle(.segmented)
                Picker("打开视频", selection: openBinding) {
                    Text("单个播放").tag("reader"); Text("滑动播放").tag("videoFeed")
                }.pickerStyle(.segmented).accessibilityIdentifier("presentation.open")
                if draft.presentation?.openItem == "videoFeed" {
                    Picker("进入下一项", selection: gestureBinding) {
                        Text("向上划").tag("swipeUp"); Text("向下划").tag("swipeDown")
                    }.pickerStyle(.segmented)
                    Toggle("自动播放", isOn: autoplayBinding)
                    Picker("播放结束", selection: endBinding) { Text("停留").tag("stop"); Text("列表下一项").tag("nextItem"); Text("下一集").tag("nextEpisode") }.pickerStyle(.segmented)
                }
            }
            Button("预览配置") { step = 2 }
        }
    }
    private func selectorRow(_ field: String, label: String) -> some View {
        HStack {
            Text(label).font(.subheadline).frame(width: 72, alignment: .leading)
            TextField("CSS 选择器", text: selectorBinding(field)).accessibilityLabel(label)
                .font(.system(.body, design: .monospaced)).textInputAutocapitalization(.never).autocorrectionDisabled()
            Button { selectedField = field; openPicker() } label: { Image(systemName: "hand.tap") }
                .accessibilityLabel("点选" + label)
        }
    }
    private var previewView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if draft.source.adapter == .web {
                    TextField("测试页面地址", text: $previewURL).textFieldStyle(.roundedBorder).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("运行解析预览", systemImage: "play.fill") { preview() }.buttonStyle(.borderedProminent).disabled(testing)
                    HStack {
                        if draft.modules?.pagination != nil { Button("测试下一页") { testCapability(search: nil) }.disabled(testing) }
                        if draft.modules?.search != nil { Button("测试搜索") { testCapability(search: "测试") }.disabled(testing) }
                    }
                    if testing { ProgressView("正在解析…") }
                    if !previewMessage.isEmpty { Text(previewMessage).font(.subheadline) }
                    ForEach(previewItems.prefix(6)) { item in
                        HStack {
                            PreviewThumbnail(item: item, definition: draft).frame(width: 100, height: 70).clipShape(RoundedRectangle(cornerRadius: 8))
                            VStack(alignment: .leading) {
                                Text(item.title).lineLimit(2)
                                Text(item.locator).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                    Text(previewJSON).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                } else { Text("保存后打开来源，检查目录内容与阅读器。") }
            }.padding()
        }
    }
    private var advancedView: some View {
        VStack(spacing: 12) {
            Text("完整配置 · schemaVersion: 2").font(.caption).foregroundStyle(.secondary)
            CodeTextEditor(text: $yaml, label: "完整来源 YAML")
            HStack {
                Button("校验并应用") { applyYAML() }
                Spacer()
                Button("导出 .site") {
                    do { exportFile = TextDocument(text: try draft.yaml()); exporting = true }
                    catch { self.error = error.localizedDescription }
                }
            }.padding()
        }
    }
    private var pickerSheet: some View {
        NavigationStack {
            VStack {
                if let picker {
                    SitePickerWebView(picker: picker)
                    Text("点选：" + Self.fieldLabel(selectedField)).font(.subheadline)
                    if let error = picker.error { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle("点选网页字段").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { showingPicker = false; picker?.stop() } } }
            .onChange(of: picker?.selection) { _, value in
                guard let value else { return }
                let shorthand = value.selector + (value.attribute.map { "@" + $0 } ?? "") + (["images", "tags", "chapters"].contains(selectedField) ? "[]" : "")
                selectorBinding(selectedField).wrappedValue = shorthand
                showingPicker = false
            }
        }
    }
    private var scriptSheet: some View {
        NavigationStack {
            CodeTextEditor(text: $script, label: "模块 JavaScript")
                .navigationTitle("JavaScript · " + role)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { editingScript = false } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("应用") {
                            var value = module ?? Self.defaultModule(role)
                            value.items = nil; value.fields = nil; value.expression = nil; value.request = nil; value.script = script
                            setModule(value); editingScript = false
                        }
                    }
                }
        }
    }
    private var module: PageModule? {
        switch role { case "video": draft.modules?.video; case "audio": draft.modules?.audio; case "ebook": draft.modules?.ebook; case "comic": draft.modules?.comic; case "chapter": draft.modules?.chapter; default: draft.modules?.catalog }
    }
    private func setModule(_ value: PageModule?) {
        if draft.modules == nil { draft.modules = SourceModules() }
        switch role { case "video": draft.modules?.video = value; case "audio": draft.modules?.audio = value; case "ebook": draft.modules?.ebook = value; case "comic": draft.modules?.comic = value; case "chapter": draft.modules?.chapter = value; default: draft.modules?.catalog = value }
    }
    private var fieldsForRole: [String] {
        switch role { case "video", "audio": ["url", "title"]; case "ebook": ["url", "format"]; case "comic": ["title", "cover", "chapters"]; case "chapter": ["images"]; default: ["title", "url", "thumbnail", "tags", "duration"] }
    }
    private static func fieldLabel(_ field: String) -> String {
        ["items": "列表卡片", "title": "标题", "url": "内容地址", "thumbnail": "封面", "tags": "标签", "duration": "时长", "cover": "封面", "chapters": "章节", "images": "漫画图片"][field] ?? field
    }
    private static func defaultModule(_ role: String) -> PageModule {
        switch role {
        case "audio": return PageModule(fields: ["url": .init(shorthand: "audio@src")])
        case "ebook": return PageModule(fields: ["url": .init(shorthand: "a.download@href")])
        case "video": return PageModule(fields: ["url": .init(shorthand: "video@src")])
        case "comic":
            var field = SelectorField(selector: ".chapter a", all: true)
            field.fields = ["title": SelectorField(), "url": SelectorField(attribute: "href")]
            return PageModule(fields: ["title": .init(shorthand: "h1"), "chapters": field])
        case "chapter": return PageModule(fields: ["images": .init(shorthand: "img@src[]")])
        default: return PageModule(items: ".card", fields: ["title": .init(shorthand: ".title"), "url": .init(shorthand: "a@href"), "thumbnail": .init(shorthand: "img@src")], kind: .video)
        }
    }
    private func entryBinding(index: Int, key: WritableKeyPath<SourceEntry, String>) -> Binding<String> {
        Binding(get: { draft.startingEntries.indices.contains(index) ? draft.startingEntries[index][keyPath: key] : "" }, set: {
            var values = draft.startingEntries
            guard values.indices.contains(index) else { return }
            values[index][keyPath: key] = $0; draft.entries = values
        })
    }
    private func connectionBinding(_ key: WritableKeyPath<SourceConnection, String?>) -> Binding<String> {
        Binding(get: { draft.source[keyPath: key] ?? "" }, set: { draft.source[keyPath: key] = $0 })
    }
    private var adapterBinding: Binding<SourceAdapter> {
        Binding(get: { draft.source.adapter }, set: {
            draft.source = SourceConnection(adapter: $0, url: $0 == .web ? "https://" : nil)
            draft.modules = $0 == .web ? SourceModules(catalog: Self.defaultModule("catalog")) : nil
            draft.entries = nil
        })
    }
    private var moduleEnabled: Binding<Bool> { Binding(get: { module != nil }, set: { setModule($0 ? Self.defaultModule(role) : nil) }) }
    private var kindBinding: Binding<ResourceKind> {
        Binding(get: { module?.kind ?? .video }, set: { var value = module ?? Self.defaultModule(role); value.kind = $0; setModule(value) })
    }
    private func selectorBinding(_ field: String) -> Binding<String> {
        Binding(get: { field == "items" ? (module?.items ?? "") : (module?.fields?[field]?.editorShorthand ?? "") }, set: { text in
            var value = module ?? Self.defaultModule(role)
            if field == "items" { value.items = text }
            else {
                if value.fields == nil { value.fields = [:] }
                if text.isEmpty { value.fields?.removeValue(forKey: field) }
                else {
                    let edited = (value.fields?[field] ?? SelectorField()).editingShorthand(text)
                    value.fields?[field] = edited
                }
            }
            setModule(value)
        })
    }
    private var paginationEnabled: Binding<Bool> {
        Binding(get: { draft.modules?.pagination != nil }, set: { if draft.modules == nil { draft.modules = SourceModules() }; draft.modules?.pagination = $0 ? PaginationModule(next: .init(shorthand: "a[rel=next]@href")) : nil })
    }
    private var searchEnabled: Binding<Bool> {
        Binding(get: { draft.modules?.search != nil }, set: { if draft.modules == nil { draft.modules = SourceModules() }; draft.modules?.search = $0 ? SearchModule(url: "/search?q={query}") : nil })
    }
    private var loginEnabled: Binding<Bool> {
        Binding(get: { draft.modules?.login != nil }, set: { if draft.modules == nil { draft.modules = SourceModules() }; draft.modules?.login = $0 ? LoginModule(url: "/login") : nil })
    }
    private var nextBinding: Binding<String> { Binding(get: { draft.modules?.pagination?.next?.shorthand ?? "" }, set: { draft.modules?.pagination?.next = .init(shorthand: $0) }) }
    private var searchBinding: Binding<String> { Binding(get: { draft.modules?.search?.url ?? "" }, set: { draft.modules?.search?.url = $0 }) }
    private var loginBinding: Binding<String> { Binding(get: { draft.modules?.login?.url ?? "" }, set: { draft.modules?.login?.url = $0 }) }
    private func presentationBinding(_ key: WritableKeyPath<SourcePresentation, String?>, default value: String) -> Binding<String> {
        Binding(get: { draft.presentation?[keyPath: key] ?? value }, set: { if draft.presentation == nil { draft.presentation = SourcePresentation() }; draft.presentation?[keyPath: key] = $0 })
    }
    private var layoutBinding: Binding<String> { presentationBinding(\.layout, default: "grid") }
    private var openBinding: Binding<String> { presentationBinding(\.openItem, default: "reader") }
    private func updateFeed(_ update: (inout FeedPresentation) -> Void) {
        if draft.presentation == nil { draft.presentation = SourcePresentation() }
        var value = draft.presentation?.feed ?? FeedPresentation()
        update(&value); draft.presentation?.feed = value
    }
    private var gestureBinding: Binding<String> { Binding(get: { draft.presentation?.feed?.nextGesture ?? "swipeUp" }, set: { value in updateFeed { $0.nextGesture = value } }) }
    private var autoplayBinding: Binding<Bool> { Binding(get: { draft.presentation?.feed?.autoplay ?? true }, set: { value in updateFeed { $0.autoplay = value } }) }
    private var endBinding: Binding<String> { Binding(get: { draft.presentation?.feed?.onPlaybackEnd ?? "stop" }, set: { value in updateFeed { $0.onPlaybackEnd = value } }) }
    private func openScript() { script = module?.script ?? module?.expression.map { "return await (\($0));" } ?? "return [];"; editingScript = true }
    private func openPicker() {
        guard let url = draft.absoluteURL(previewURL.isEmpty ? (draft.source.url ?? "") : previewURL) else { error = "请输入测试页面地址"; return }
        let next = SiteElementPicker(sourceID: draft.id)
        next.load(url)
        picker = next; showingPicker = true
        next.pick(field: selectedField, items: module?.items)
    }
    private func preview() {
        error = nil; previewMessage = ""; testing = true
        Task {
            defer { testing = false }
            do {
                try draft.validate()
                guard let url = draft.absoluteURL(previewURL), let selected = module?.selected(for: url) else { throw CoveError.message("请选择已配置模块和测试页面") }
                let engine = WebEngine(sourceID: draft.id)
                defer { engine.cancel() }
                try await engine.load(url, headers: selected.load?.headers ?? [:], wait: selected.load?.waitSeconds ?? 0)
                let result = try await engine.execute(selected.javascript)
                previewJSON = result
                if role == "catalog" {
                    previewItems = try ResourceParser.catalog(result, sourceID: draft.id, base: url, defaultKind: selected.kind ?? .web)
                    previewMessage = "提取 \(previewItems.count) 项"
                } else { previewItems = []; previewMessage = "模块解析完成" }
            } catch { self.error = error.localizedDescription }
        }
    }
    private func testCapability(search: String?) {
        testing = true; error = nil
        Task {
            defer { testing = false }
            let provider = WebSourceProvider(definition: draft)
            defer { provider.close() }
            do {
                let first = try await provider.list(CollectionRequest(locator: previewURL, query: search, forceRefresh: true))
                if search != nil { previewItems = first.items; previewMessage = "搜索返回 \(first.items.count) 项" }
                else if let cursor = first.nextCursor {
                    let next = try await provider.list(CollectionRequest(locator: previewURL, cursor: cursor, forceRefresh: true))
                    previewItems = next.items; previewMessage = "下一页返回 \(next.items.count) 项"
                } else { previewMessage = "未找到下一页" }
            } catch { self.error = error.localizedDescription }
        }
    }
    private func applyYAML() {
        let text = yaml
        Task {
            do { draft = try await Task.detached { try SourceDefinition.decode(text) }.value; error = nil }
            catch { self.error = error.localizedDescription }
        }
    }
    private func save() {
        let text = yaml, advanced = step == 3
        Task {
            do {
                if advanced { draft = try await Task.detached { try SourceDefinition.decode(text) }.value }
                try draft.validate()
                if draft.source.adapter == .files, folder == nil, (try? sources.folder(id: draft.id)) == nil { throw CoveError.message("请先选择本地文件夹") }
                try sources.save(draft)
                if draft.source.adapter == .web { sources.invalidateSession(id: draft.id) }
                if let folder { try sources.bindFolder(folder, id: draft.id) }
                if draft.source.adapter == .smb { try sources.setPassword(password, id: draft.id) }
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}

private struct PreviewThumbnail: View {
    let item: ResourceItem
    let definition: SourceDefinition
    @State private var image: UIImage?
    var body: some View {
        ZStack {
            Color(.secondarySystemBackground)
            if let image { Image(uiImage: image).resizable().scaledToFill() }
            else { Image(systemName: item.kind.icon).foregroundStyle(.secondary) }
        }.clipped().task(id: item.id) {
            guard let url = item.thumbnail.flatMap(URL.init(string:)) else { return }
            let request = ImageRequest(url: url, sourceID: definition.id, sourceRevision: definition.fingerprint, pixels: 300, transform: definition.modules?.images)
            let prepared = await SourceWebSession.imageRequest(request)
            image = await ImagePipeline.shared.image(prepared)?.image
        }
    }
}
