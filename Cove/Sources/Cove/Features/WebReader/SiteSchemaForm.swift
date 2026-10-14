import SwiftUI

struct SiteSchemaForm: View {
    let model: SiteFormModel
    var readonlyID = false
    var body: some View {
        SiteFormNode(model: model, path: [], kind: .object("site"), title: "配置表单", readonlyID: readonlyID)
    }
}

private struct SiteFormNode: View {
    let model: SiteFormModel
    let path: SiteFormPath
    let kind: SiteFormSpec.Kind
    let title: String
    var readonlyID = false
    @State private var addingKey = false
    @State private var newKey = ""
    @State private var keyError: String?
    @State private var ordering: EditMode = .inactive
    private var value: SiteFormValue { model.value(at: path) ?? .null }

    var body: some View {
        Form {
            switch kind {
            case .object(let type): object(type)
            case .list(let item): list(item)
            case .map(let item): map(item)
            default: SiteFormField(model: model, path: path, kind: kind, title: title)
            }
        }
        .appSurface()
        .navigationTitle(path.isEmpty ? "站点配置" : title)
        .navigationBarTitleDisplayMode(.inline)
        .environment(\.editMode, $ordering)
        .toolbar {
            if case .list = kind {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(ordering.isEditing ? "完成" : "排序") {
                        withAnimation { ordering = ordering.isEditing ? .inactive : .active }
                    }
                }
            }
        }
        .alert("添加字段", isPresented: $addingKey) {
            TextField("字段名", text: $newKey).textInputAutocapitalization(.never)
            Button("取消", role: .cancel) {}
            Button("添加") { addMapKey() }
        }
        .alert("无法添加", isPresented: Binding(get: { keyError != nil }, set: { if !$0 { keyError = nil } })) {
            Button("好") { keyError = nil }
        } message: { Text(keyError ?? "") }
    }

    @ViewBuilder private func object(_ type: String) -> some View {
        if type == "extract" {
            Section {
                Picker("提取方式", selection: Binding(get: {
                    value.object["script"] != nil ? "script" : value.object["expression"] != nil ? "expression" : "fields"
                }, set: { mode in
                    let content: SiteFormValue = mode == "fields" ? .object(["title":.object(["text":.bool(true)]), "url":.object(["attribute":.string("href")])]) : .string(mode == "script" ? "return [];" : "JSON.stringify([])")
                    var replacement: [String: SiteFormValue] = [mode: content]
                    if mode == "fields", model.value(at: Array(path.dropLast()) + [.key("role")])?.string == "catalog" { replacement["items"] = .string(".card") }
                    model.set(.object(replacement), at: path)
                })) {
                    Text("CSS 字段").tag("fields"); Text("JavaScript 函数体").tag("script"); Text("JavaScript 表达式").tag("expression")
                }
                Text("更换提取方式会替换当前提取配置；其他规则保持不变。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        Section {
            ForEach(SiteFormSpec.names(type).filter { value.object[$0] != nil }, id: \.self) { key in
                let fieldPath = path + [.key(key)]
                if type == "site" && (key == "schemaVersion" || (key == "id" && readonlyID)) {
                    LabeledContent(SiteFormSpec.label(key), value: key == "schemaVersion" ? model.numericText(at: fieldPath) : value.object[key]?.string ?? "")
                        .textSelection(.enabled)
                } else {
                    SiteFormField(model: model, path: fieldPath, kind: SiteFormSpec.kind(key, type: type), title: SiteFormSpec.label(key))
                        .swipeActions { if !SiteFormSpec.required(key, type: type) {
                            Button("移除", role: .destructive) { model.set(nil, at: fieldPath) }
                        } }
                }
            }
        } header: { Text(title) }
        let absent = SiteFormSpec.names(type).filter { key in
            guard value.object[key] == nil else { return false }
            if type == "extract" { return key == "items" && value.object["fields"] != nil }
            if type == "rule" && key == "extract" { return value.object["request"] == nil }
            if type == "rule" && key == "request" { return value.object["extract"] == nil }
            return true
        }
        if !absent.isEmpty {
            Section {
                Menu("添加可选配置", systemImage: "plus") {
                    ForEach(absent, id: \.self) { key in
                        Button(SiteFormSpec.label(key)) { model.set(SiteFormSpec.initial(SiteFormSpec.kind(key, type: type)), at: path + [.key(key)]) }
                    }
                }.foregroundColor(.accentColor)
            }
        }
        if type == "rule" {
            Section {
                Button(value.object["request"] == nil ? "改用请求解析" : "改用页面提取") {
                    if value.object["request"] == nil {
                        model.set(nil, at: path + [.key("extract")]); model.set(SiteFormSpec.initial(.object("request")), at: path + [.key("request")])
                    } else {
                        model.set(nil, at: path + [.key("request")]); model.set(.object(["script":.string("return [];" )]), at: path + [.key("extract")])
                    }
                }
            }
        }
    }

    @ViewBuilder private func list(_ item: SiteFormSpec.Kind) -> some View {
        Section {
            ForEach(value.array.indices, id: \.self) { index in
                SiteFormField(model: model, path: path + [.index(index)], kind: item, title: rowName(value.array[index], fallback: "第 \(index + 1) 项"))
            }
            .onDelete { indices in
                for index in indices.sorted(by: >) { model.set(nil, at: path + [.index(index)]) }
            }
            .onMove { indices, offset in
                var order = Array(value.array.indices); order.move(fromOffsets: indices, toOffset: offset); model.reorder(order, at: path)
            }
            Button("添加项目", systemImage: "plus") { model.append(SiteFormSpec.initial(item), at: path) }
                .foregroundColor(.accentColor)
        } footer: { Text("左滑可删除；点击排序后拖动手柄可调整顺序。") }
    }

    @ViewBuilder private func map(_ item: SiteFormSpec.Kind) -> some View {
        Section {
            ForEach(value.object.keys.sorted(), id: \.self) { key in
                SiteFormField(model: model, path: path + [.key(key)], kind: item, title: key)
                    .swipeActions { Button("移除", role: .destructive) { model.set(nil, at: path + [.key(key)]) } }
            }
            Button("添加字段", systemImage: "plus") { newKey = ""; addingKey = true }
                .foregroundColor(.accentColor)
        }
    }
    private func addMapKey() {
        let key = newKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, value.object[key] == nil else { keyError = "字段名不能为空或重复"; return }
        if case .map(let item) = kind { model.set(SiteFormSpec.initial(item), at: path + [.key(key)]) }
    }
    private func rowName(_ value: SiteFormValue, fallback: String) -> String {
        let object = value.object
        return object["name"]?.string.nonEmpty ?? object["id"]?.string.nonEmpty ?? fallback
    }
}

private struct SiteFormField: View {
    let model: SiteFormModel
    let path: SiteFormPath
    let kind: SiteFormSpec.Kind
    let title: String
    private var value: SiteFormValue { model.value(at: path) ?? .null }
    private var text: Binding<String> { Binding(get: { value.string }, set: { model.set(.string($0), at: path) }) }
    private var identifier: String {
        "schema-form-" + path.map { part in
            switch part { case .key(let key): key; case .index(let index): String(index) }
        }.joined(separator: ".")
    }
    var body: some View {
        switch kind {
        case .text:
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                TextField(title, text: text, axis: .vertical)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier(identifier)
                    .accessibilityLabel(title)
            }
        case .code:
            NavigationLink {
                VStack(alignment: .leading) {
                    CodeTextEditor(text: text, label: title)
                }.appSurface().navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            } label: { Label(title, systemImage: "chevron.left.forwardslash.chevron.right") }
        case .inlineCode:
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                CodeTextEditor(text: text, label: title).frame(minHeight: 64, maxHeight: 96)
            }
        case .bool:
            Toggle(title, isOn: Binding(get: { value.bool }, set: { model.set(.bool($0), at: path) }))
        case .number:
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                TextField(title, text: Binding(get: { model.numericText(at: path) }, set: { model.setNumber($0, at: path) }))
                    .keyboardType(.numbersAndPunctuation).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier(identifier)
                    .accessibilityLabel(title)
            }
        case .choices(let options):
            Picker(title, selection: text) {
                if !options.contains(where: { $0.0 == value.string }) { Text(value.string).tag(value.string) }
                ForEach(options, id: \.0) { key, label in Text(label).tag(key) }
            }
        case .object, .list, .map:
            NavigationLink {
                AnyView(SiteFormNode(model: model, path: path, kind: kind, title: title))
            } label: {
                LabeledContent(title, value: countLabel)
            }
            .accessibilityIdentifier(identifier)
        }
    }
    private var countLabel: String {
        switch kind {
        case .list: return "\(value.array.count) 项"
        case .object, .map: return "\(value.object.count) 项"
        default: return ""
        }
    }
}

private extension String { var nonEmpty: String? { isEmpty ? nil : self } }
