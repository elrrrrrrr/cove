import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct SiteListView: View {
    @Query(sort: \BookmarkSite.sortOrder)
    private var sites: [BookmarkSite]

    @Environment(\.modelContext) private var context

    @State private var library = SiteDefinitionStore.shared
    @State private var showImport = false
    @State private var operationError: String?
    @State private var showAddSheet    = false
    @State private var editTarget: BookmarkSite?   // nil = add, non-nil = edit
    @State private var jsTarget: BookmarkSite?     // site whose JS is being edited
    @State private var editMode: EditMode = .inactive
    @State private var filterCategory: SiteCategory? = nil

    // Sites filtered by selected category tab
    private var displayed: [BookmarkSite] {
        guard let cat = filterCategory else { return sites }
        return sites.filter { $0.category == cat }
    }

    // Categories that actually have sites
    private var usedCategories: [SiteCategory] {
        let used = Set(sites.map(\.category))
        return SiteCategory.allCases.filter { used.contains($0) }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Category filter bar
                if !usedCategories.isEmpty {
                    categoryBar
                }

                Group {
                    if sites.isEmpty {
                        emptyState
                    } else if displayed.isEmpty {
                        ContentUnavailableView("该分类暂无站点", systemImage: "safari")
                    } else {
                        siteList
                    }
                }
            }
            .navigationTitle("网站")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("创建站点规则", systemImage: "wand.and.stars") { editTarget = nil; showAddSheet = true }
                        Button("导入 .site", systemImage: "square.and.arrow.down") { showImport = true }
                    } label: { Image(systemName: "plus") }
                        .accessibilityLabel("添加或导入站点")
                }
                ToolbarItem(placement: .topBarLeading) {
                    EditButton()
                }
            }
            .environment(\.editMode, $editMode)
            .sheet(isPresented: $showAddSheet) {
                if let editTarget { SiteEditSheet(existing: editTarget) }
                else { SiteSetupWizard() }
            }
            .sheet(item: $jsTarget) { site in
                SiteSetupWizard(existing: site)
            }
            .sheet(item: $library.pendingImport) { SiteImportSheet(definition: $0) }
            .fileImporter(isPresented: $showImport, allowedContentTypes: [.coveSite, .plainText, .data]) { result in
                do {
                    let url = try result.get()
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    library.pendingImport = try SiteDefinition.decode(String(contentsOf: url, encoding: .utf8))
                } catch { operationError = error.localizedDescription }
            }
            .alert("操作失败", isPresented: Binding(get: { operationError != nil }, set: { if !$0 { operationError = nil } })) {
                Button("好") { operationError = nil }
            } message: { Text(operationError ?? "") }
            .safeAreaInset(edge: .bottom) {
                if !library.issues.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(library.issues.enumerated()), id: \.offset) { _, issue in Text(issue).font(.caption) }
                        Button("关闭提示") { library.issues = [] }
                    }.padding().frame(maxWidth: .infinity, alignment: .leading).background(.regularMaterial)
                }
            }
        }
    }

    // MARK: - Category filter bar

    private var categoryBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                categoryChip(nil, label: "全部")
                ForEach(usedCategories) { cat in
                    categoryChip(cat, label: cat.rawValue)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .background(Color(.secondarySystemBackground))
    }

    private func categoryChip(_ cat: SiteCategory?, label: String) -> some View {
        Button {
            withAnimation { filterCategory = cat }
        } label: {
            Text(label)
                .font(.subheadline)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(filterCategory == cat ? Color.accentColor : Color(.tertiarySystemBackground),
                            in: Capsule())
                .foregroundStyle(filterCategory == cat ? .white : .primary)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Site list

    private var siteList: some View {
        List {
            ForEach(displayed) { site in
                NavigationLink(destination: SiteGalleryView(site: site)) {
                    SiteRow(site: site)
                }
                // Long-press to edit
                .contextMenu {
                    Button {
                        editTarget = site
                        showAddSheet = true
                    } label: {
                        Label("编辑", systemImage: "pencil")
                    }
                    Button {
                        jsTarget = site
                    } label: {
                        Label("解析规则", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                    Button(role: .destructive) {
                        context.delete(site)
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                }
                .swipeActions(edge: .leading) {
                    Button {
                        jsTarget = site
                    } label: {
                        Label("解析规则", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                    .tint(.blue)
                    Button {
                        editTarget = site
                        showAddSheet = true
                    } label: {
                        Label("编辑", systemImage: "pencil")
                    }
                    .tint(.orange)
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        context.delete(site)
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                }
            }
            .onMove { indices, newOffset in
                do {
                    try SiteOrder.move(sites, category: filterCategory, from: indices, to: newOffset, context: context)
                } catch {
                    operationError = "排序失败：\(error.localizedDescription)"
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        ContentUnavailableView {
            Label("还没有收藏站点", systemImage: "safari")
        } description: {
            Text("点击右上角 + 添加站点")
        } actions: {
            Button("添加站点") {
                editTarget = nil
                showAddSheet = true
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

@MainActor enum SiteOrder {
    static func move(_ sites: [BookmarkSite], category: SiteCategory?, from indices: IndexSet,
                     to offset: Int, context: ModelContext) throws {
        var visible = sites.filter { category == nil || $0.category == category }
        guard indices.allSatisfy({ visible.indices.contains($0) }), (0...visible.count).contains(offset) else { return }
        visible.move(fromOffsets: indices, toOffset: offset)
        var iterator = visible.makeIterator()
        let reordered = sites.map { category == nil || $0.category == category ? iterator.next()! : $0 }
        try context.save()
        for (index, site) in reordered.enumerated() { site.sortOrder = index }
        do { try context.save() }
        catch { context.rollback(); throw error }
    }
}

// MARK: - Site row

struct SiteRow: View {
    let site: BookmarkSite

    var body: some View {
        HStack(spacing: 12) {
            // Favicon or category icon
            Group {
                if let data = site.faviconData, let img = UIImage(data: data) {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: site.category.icon)
                        .foregroundStyle(Color.accentColor)
                }
            }
            .frame(width: 32, height: 32)
            .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text(site.name)
                    .font(.body)
                HStack(spacing: 4) {
                    Text(site.category.rawValue)
                        .font(.caption2)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.15), in: Capsule())
                    Text(hostDisplay(site.urlString))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if !site.note.isEmpty {
                    Text(site.note)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func hostDisplay(_ urlString: String) -> String {
        URL(string: urlString)?.host() ?? urlString
    }
}

// MARK: - Add / Edit sheet

struct SiteEditSheet: View {
    /// nil means "add new", non-nil means "edit existing"
    let existing: BookmarkSite?

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss)      private var dismiss

    @State private var name      = ""
    @State private var urlString = "https://"
    @State private var category: SiteCategory = .other
    @State private var note      = ""
    @State private var isFetching = false

    private var isNew: Bool { existing == nil }
    private var isValid: Bool {
        !name.isEmpty && URL(string: urlString) != nil && urlString.hasPrefix("http")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("基本信息") {
                    TextField("站点名称", text: $name)

                    HStack {
                        TextField("入口地址 (https://...)", text: $urlString)
                            .keyboardType(.URL)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        if isFetching {
                            ProgressView().scaleEffect(0.8)
                        }
                    }

                    // URL preview chip
                    if let url = URL(string: urlString), urlString != "https://" {
                        Text(url.absoluteString)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }

                Section("分类") {
                    Picker("分类", selection: $category) {
                        ForEach(SiteCategory.allCases) { cat in
                            Label(cat.rawValue, systemImage: cat.icon).tag(cat)
                        }
                    }
                    .pickerStyle(.menu)
                }

                Section("备注（可选）") {
                    TextField("例如：需要梯子、每日更新…", text: $note, axis: .vertical)
                        .lineLimit(3)
                }

            }
            .navigationTitle(isNew ? "添加站点" : "编辑站点")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(!isValid)
                }
            }
            .onAppear { loadExisting() }
        }
    }

    // MARK: - Actions

    private func loadExisting() {
        guard let site = existing else { return }
        name      = site.name
        urlString = site.urlString
        category  = site.category
        note      = site.note
    }

    private func save() {
        if let site = existing {
            site.name      = name
            site.urlString = urlString
            site.category  = category
            site.note      = note
        } else {
            let site = BookmarkSite(
                name: name,
                urlString: urlString,
                category: category,
                note: note
            )
            context.insert(site)
            // Async favicon fetch
            Task { await fetchFavicon(for: site) }
        }
        dismiss()
    }

    private func fetchFavicon(for site: BookmarkSite) async {
        guard let host = URL(string: site.urlString)?.host() else { return }
        let faviconURL = URL(string: "https://\(host)/favicon.ico")!
        guard let (data, _) = try? await URLSession.shared.data(from: faviconURL),
              UIImage(data: data) != nil else { return }
        await MainActor.run { site.faviconData = data }
    }
}

// Compatibility entry point for gallery configuration sheets.
struct SiteConfigSheet: View {
    let site: BookmarkSite
    var body: some View { SiteSetupWizard(existing: site) }
}
