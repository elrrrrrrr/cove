import SwiftUI

struct CoveSettings: View {
    @Environment(SourceStore.self) private var sources
    @AppStorage("readerFontSize") private var fontSize = 17.0
    @AppStorage("readerTheme") private var theme = ReaderTheme.system
    @AppStorage("contentBlockerEnabled") private var blocker = true
    @State private var clearing = false
    @State private var exporting = false
    @State private var importing = false
    @State private var document = TextDocument(text: "", type: .json)
    @State private var message: String?
    var body: some View {
        NavigationStack {
            Form {
                Section("阅读") {
                    Toggle("屏蔽网页广告", isOn: $blocker)
                    Picker("主题", selection: $theme) { ForEach(ReaderTheme.allCases) { Text($0.label).tag($0) } }
                    Slider(value: $fontSize, in: 12...30, step: 1) { Text("字体大小") }
                    Text("字体大小：\(Int(fontSize))").font(.caption).foregroundStyle(.secondary)
                }
                Section("来源配置") {
                    Button("导出来源配置") {
                        do {
                            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                            document = TextDocument(text: String(decoding: try encoder.encode(SourceBackup(sources: sources.definitions)), as: UTF8.self), type: .json)
                            exporting = true
                        } catch { message = error.localizedDescription }
                    }
                    Button("导入并合并来源") { importing = true }
                    Text("密码和本地文件夹授权仅保存在本机。收藏可在收藏页单独导入、导出。").font(.caption).foregroundStyle(.secondary)
                }
                Section("缓存") {
                    Button("清理内容缓存") {
                        clearing = true
                        Task {
                            do { try await ImagePipeline.shared.clear(); try await ResourceAccess.shared.clear(); try await CatalogCache.shared.clear(); message = "缓存已清理" }
                            catch { message = error.localizedDescription }
                            clearing = false
                        }
                    }.disabled(clearing)
                }
                Section("关于") {
                    LabeledContent("应用", value: "Cove")
                    LabeledContent("配置格式", value: "2")
                }
            }
            .navigationTitle("设置")
            .fileExporter(isPresented: $exporting, document: document, contentType: .json, defaultFilename: "cove-sources") { result in if case .failure(let error) = result { message = error.localizedDescription } }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
                do {
                    let url = try result.get(), scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    let backup = try JSONDecoder().decode(SourceBackup.self, from: Data(contentsOf: url))
                    guard backup.schemaVersion == 2 else { throw CoveError.message("配置备份需要使用版本 2") }
                    var next = sources.definitions
                    for value in backup.sources {
                        try value.validate()
                        if let index = next.firstIndex(where: { $0.id == value.id }) { next[index] = value } else { next.append(value) }
                    }
                    try sources.replace(next)
                } catch { message = error.localizedDescription }
            }
            .alert("提示", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) { Button("好") { message = nil } } message: { Text(message ?? "") }
        }
    }
}

private struct SourceBackup: Codable {
    var schemaVersion = 2
    var sources: [SourceDefinition]
}
