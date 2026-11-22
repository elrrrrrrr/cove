import SwiftUI
import SwiftData

/// Unified `.site` YAML configuration editor for creating, inspecting, validating, and exporting site definitions.
struct SiteConfigEditor: View {
    var existing: BookmarkSite?
    var imported: SiteDefinition?
    var onSaved: (() -> Void)?

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var library = SiteDefinitionStore.shared
    @State private var yamlText = ""
    @State private var loaded = false
    @State private var configurationNeedsSaving = false
    @State private var statusMessage: String?
    @State private var error: String?
    @State private var exporting = false
    @State private var exportDocument = SiteFileDocument(text: "")
    @State private var exportFilename = "site.site"

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 8) {
                Text(headerSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
                    .padding(.top, 8)
                CodeTextEditor(text: $yamlText, label: "完整站点 YAML")
                if let error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.horizontal)
                        .padding(.bottom, 8)
                        .textSelection(.enabled)
                } else if let statusMessage {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                        .padding(.bottom, 8)
                }
            }
            .appSurface()
            .navigationTitle("站点配置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("校验") { validate() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                }
                ToolbarItem(placement: .bottomBar) {
                    Button("导出 .site", systemImage: "square.and.arrow.up") { export() }
                }
            }
            .onAppear { initialize() }
            .fileExporter(
                isPresented: $exporting,
                document: exportDocument,
                contentType: .coveSite,
                defaultFilename: exportFilename
            ) { result in
                if case .failure(let issue) = result { error = issue.localizedDescription }
            }
        }
    }

    private var headerSubtitle: String {
        if configurationNeedsSaving {
            return "尚未保存站点规则，以下为配置草稿。常规提取使用 fields，复杂提取使用 script: |。"
        }
        return "完整 .site YAML（schemaVersion 1）：常规提取使用 fields，复杂提取使用 script: |。"
    }

    private func initialize() {
        guard !loaded else { return }
        loaded = true
        let initial: SiteDefinition
        if let imported {
            initial = imported
        } else if let existing, let url = existing.url {
            let saved = library.definition(id: existing.definitionID) ?? SiteParserRegistry.definition(for: url)
            configurationNeedsSaving = saved == nil
            var draft = saved ?? .starter(name: existing.name, url: url)
            if saved == nil { draft.entries[0].category = existing.category.configurationValue }
            initial = draft
        } else {
            configurationNeedsSaving = true
            initial = .starter(name: "新站点", url: URL(string: "https://media.example/")!)
        }
        do {
            yamlText = try initial.yaml()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func validate() {
        do {
            let value = try SiteDefinition.decode(yamlText)
            yamlText = try value.yaml()
            error = nil
            statusMessage = "配置校验通过（\(value.rules.count) 条规则）"
        } catch {
            statusMessage = nil
            self.error = error.localizedDescription
        }
    }

    private func save() {
        let previousDefinitions = library.definitions
        do {
            let value = try SiteDefinition.decode(yamlText)
            if let existing {
                try library.saveConfiguration(value, for: existing, context: context)
            } else {
                try library.importDefinition(value, context: context)
            }
            onSaved?()
            dismiss()
        } catch {
            context.rollback()
            try? library.replace(previousDefinitions)
            statusMessage = nil
            self.error = error.localizedDescription
        }
    }

    private func export() {
        do {
            let value = try SiteDefinition.decode(yamlText)
            exportFilename = value.id + ".site"
            exportDocument = SiteFileDocument(text: try value.yaml())
            error = nil
            exporting = true
        } catch {
            statusMessage = nil
            self.error = error.localizedDescription
        }
    }
}
