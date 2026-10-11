import SwiftUI
import SwiftData
import UniformTypeIdentifiers

extension UTType {
    static var coveSite: UTType { UTType(exportedAs: "dev.cove.site", conformingTo: .text) }
}

struct SiteFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.coveSite, .plainText] }
    var text: String
    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents, let value = String(data: data, encoding: .utf8) else { throw CocoaError(.fileReadCorruptFile) }
        text = value
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: Data(text.utf8)) }
}

struct JSONDataDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data = Data()) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct SiteImportSheet: View {
    let definition: SiteDefinition
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?
    @State private var showEditor = false
    private var exists: Bool { SiteDefinitionStore.shared.definition(id: definition.id) != nil }
    var body: some View {
        NavigationStack {
            Form {
                Section("站点配置") {
                    LabeledContent("名称", value: definition.name)
                    LabeledContent("标识", value: definition.id)
                    LabeledContent("解析规则", value: String(definition.rules.count))
                }
                Section("入口") {
                    ForEach(definition.entries) { entry in
                        VStack(alignment: .leading) {
                            Text(entry.name)
                            Text(entry.path).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Section {
                    Button("预览并编辑规则") { showEditor = true }
                    Button(exists ? "替换现有配置" : "导入站点") { save(copy: false) }
                    if exists { Button("另存为新站点") { save(copy: true) } }
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
            }
            .appSurface()
            .navigationTitle("导入 .site")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
            .sheet(isPresented: $showEditor) { SiteSetupWizard(imported: definition, onSaved: { dismiss() }) }
        }
    }
    private func save(copy: Bool) {
        do { try SiteDefinitionStore.shared.importDefinition(definition, context: context, asCopy: copy); dismiss() }
        catch { self.error = error.localizedDescription }
    }
}
