import SwiftUI

struct SourcesView: View {
    @Environment(SourceStore.self) private var sources
    @State private var query = ""
    @State private var adapter: SourceAdapter?
    @State private var visible: [SourceDefinition] = []
    @State private var adding = false
    @State private var editing: SourceDefinition?
    @State private var importing = false
    @State private var imported: SourceDefinition?
    @State private var error: String?
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("来源类型", selection: $adapter) {
                        Text("全部").tag(SourceAdapter?.none)
                        ForEach(SourceAdapter.allCases) { Text($0.label).tag(Optional($0)) }
                    }.pickerStyle(.segmented)
                }
                ForEach(visible) { source in
                    NavigationLink {
                        SourceEntriesView(source: source)
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(source.name)
                                Text(source.source.adapter.label).font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: { Image(systemName: source.source.adapter.icon) }
                    }
                    .swipeActions(edge: .leading) { Button("编辑") { editing = source }.tint(.orange) }
                    .swipeActions {
                        Button("删除", role: .destructive) {
                            do { try sources.remove(id: source.id) } catch { self.error = error.localizedDescription }
                        }
                    }
                }
                .onMove { offsets, destination in
                    var moved = visible; moved.move(fromOffsets: offsets, toOffset: destination)
                    do { try sources.reorder(ids: moved.map(\.id), visible: visible.map(\.id)) }
                    catch { self.error = error.localizedDescription }
                }
                if sources.definitions.isEmpty { ContentUnavailableView("添加第一个来源", systemImage: "square.stack.3d.up", description: Text("选择文件夹、连接 SMB，或配置网站")) }
            }
            .navigationTitle("资源")
            .searchable(text: $query, prompt: "搜索来源")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("添加来源", systemImage: "plus") { adding = true }.accessibilityIdentifier("sources.create")
                        Button("导入 .site", systemImage: "square.and.arrow.down") { importing = true }
                    } label: { Image(systemName: "plus") }
                    .accessibilityLabel("添加来源").accessibilityIdentifier("sources.add")
                }
                ToolbarItem(placement: .topBarLeading) { EditButton() }
            }
            .sheet(isPresented: $adding) { SourceSetupView() }
            .sheet(item: $editing) { SourceSetupView(existing: $0) }
            .sheet(item: $imported) { SourceSetupView(existing: $0) }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.coveSite, .yaml, .plainText]) { result in
                do {
                    let url = try result.get(), scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    imported = try SourceDefinition.read(url)
                } catch { self.error = error.localizedDescription }
            }
            .task { prepare() }
            .onChange(of: sources.definitions) { _, _ in prepare() }
            .onChange(of: query) { _, _ in prepare() }
            .onChange(of: adapter) { _, _ in prepare() }
            .alert("无法完成操作", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("好") { error = nil } } message: { Text(error ?? "") }
        }
    }
    private func prepare() {
        visible = sources.definitions.filter { source in
            (adapter == nil || source.source.adapter == adapter) &&
                (query.isEmpty || source.name.localizedCaseInsensitiveContains(query))
        }
    }
}

private struct SourceEntriesView: View {
    let source: SourceDefinition
    @State private var editing = false
    var body: some View {
        Group {
            if source.startingEntries.count == 1, let entry = source.startingEntries.first {
                CollectionView(sourceID: source.id, locator: entry.path, title: source.name)
            } else { List(source.startingEntries) { entry in
            NavigationLink {
                CollectionView(sourceID: source.id, locator: entry.path, title: entry.name)
            } label: { Label(entry.name, systemImage: (entry.kind ?? .folder).icon) }
        }
            } }
        .navigationTitle(source.name)
        .toolbar { ToolbarItem(placement: .primaryAction) { Button("配置", systemImage: "slider.horizontal.3") { editing = true } } }
        .sheet(isPresented: $editing) { SourceSetupView(existing: source) }
    }
}
