import SwiftUI
import SwiftData

struct SettingsView: View {
    @Query private var nasConfigs: [NASConfig]
    @Query(sort: \BookmarkSite.sortOrder) private var sites: [BookmarkSite]
    @Query private var allHistory: [ReadingHistory]
    @Environment(\.modelContext) private var context

    @AppStorage("readerFontSize") private var fontSize: Double = 17
    @AppStorage(AppTheme.storageKey) private var theme: AppTheme = .system
    @AppStorage(NovelReadingMode.storageKey) private var readingMode: NovelReadingMode = .paged
    @AppStorage("contentBlockerEnabled") private var blockerEnabled: Bool = true

    @State private var showAddNAS = false
    @State private var showSiteList = false
    @State private var showClearConfirm = false
    @State private var isClearing = false

    @State private var exportFileURL: URL?
    @State private var showExportShare = false
    @State private var showImporter = false
    @State private var pendingBackup: ConfigBackup?
    @State private var showImportConfirm = false
    @State private var importError: String?
    @State private var showImportError = false
    @State private var showImportSuccess = false

    var body: some View {
        NavigationStack {
            Form {
                // Site management
                Section {
                    ForEach(sites) { site in
                        HStack {
                            if let data = site.faviconData, let img = UIImage(data: data) {
                                Image(uiImage: img)
                                    .resizable()
                                    .frame(width: 24, height: 24)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                            } else {
                                Image(systemName: site.category.icon)
                                    .frame(width: 24, height: 24)
                                    .foregroundStyle(.secondary)
                            }
                            Text(site.name)
                        }
                    }
                    Button {
                        showSiteList = true
                    } label: {
                        Label("管理网站", systemImage: "pencil")
                    }
                } header: {
                    Text("网站")
                } footer: {
                    Text("首页「快速访问」显示这些站点")
                }

                // NAS configuration
                Section("NAS 连接") {
                    ForEach(nasConfigs) { config in
                        NavigationLink(destination: NASSettingsView(config: config)) {
                            NASConfigRow(config: config)
                        }
                    }
                    Button {
                        showAddNAS = true
                    } label: {
                        Label("添加 NAS", systemImage: "plus.circle")
                    }
                }

                Section("外观") {
                    Picker("全局主题", selection: $theme) {
                        ForEach(AppTheme.allCases) { t in Text(t.label).tag(t) }
                    }
                    .accessibilityIdentifier("app-theme-picker")
                }

                // Reader settings
                Section("阅读设置") {
                    HStack {
                        Text("字体大小")
                        Spacer()
                        Stepper("\(Int(fontSize)) pt", value: $fontSize, in: 12...28, step: 1)
                    }
                    Picker("小说翻页", selection: $readingMode) {
                        ForEach(NovelReadingMode.allCases) { mode in Text(mode.label).tag(mode) }
                    }
                }

                // Ad blocking
                Section("广告拦截") {
                    Toggle("启用内容拦截", isOn: $blockerEnabled)
                    NavigationLink("管理拦截规则") {
                        BlockerRulesView()
                    }
                }

                // Data management
                Section {
                    Button {
                        exportConfig()
                    } label: {
                        Label("导出配置", systemImage: "square.and.arrow.up")
                    }

                    Button {
                        showImporter = true
                    } label: {
                        Label("导入配置", systemImage: "square.and.arrow.down")
                    }

                    NavigationLink {
                        HistoryView()
                    } label: {
                        HStack {
                            Label("阅读记录", systemImage: "clock.arrow.circlepath")
                            Spacer()
                            Text("\(allHistory.count) 条")
                                .foregroundStyle(.secondary)
                        }
                    }

                    Button(role: .destructive) {
                        showClearConfirm = true
                    } label: {
                        HStack {
                            Label("清除所有数据", systemImage: "trash")
                            if isClearing {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isClearing)
                } header: {
                    Text("数据管理")
                } footer: {
                    Text("「清除所有数据」将删除所有阅读记录、收藏、站点、缓存及设置，恢复到初始状态。")
                }

                // Diagnostics
                Section("诊断") {
                    Toggle(isOn: Binding(
                        get: { AppLogger.shared.isEnabled },
                        set: { AppLogger.shared.isEnabled = $0 }
                    )) {
                        Label("启用诊断日志", systemImage: "ant")
                    }
                    if AppLogger.shared.isEnabled {
                        NavigationLink {
                            DiagnosticLogView()
                        } label: {
                            HStack {
                                Label("连接日志", systemImage: "text.alignleft")
                                Spacer()
                                Text("\(AppLogger.shared.entries.count)")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                // About
                Section("关于") {
                    LabeledContent("版本", value: Bundle.main.appVersion)
                    Link("问题反馈", destination: URL(string: "https://github.com")!)
                }
            }
            .appSurface()
            .navigationTitle("设置")
            .sheet(isPresented: $showSiteList) {
                SiteListView()
            }
            .sheet(isPresented: $showAddNAS) {
                NASSettingsView(config: nil)
            }
            .confirmationDialog("确定要清除所有数据吗？此操作不可撤销。", isPresented: $showClearConfirm, titleVisibility: .visible) {
                Button("清除所有数据", role: .destructive) {
                    Task { await clearAllData() }
                }
            }
            .sheet(isPresented: $showExportShare) {
                if let url = exportFileURL {
                    ShareSheet(items: [url])
                }
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json]) { result in
                handleImportFile(result)
            }
            .confirmationDialog(
                "将替换当前 \(sites.count) 个站点和 \(nasConfigs.count) 个 NAS 配置，确定导入？",
                isPresented: $showImportConfirm,
                titleVisibility: .visible
            ) {
                Button("导入并替换", role: .destructive) {
                    applyImport()
                }
            }
            .alert("导入失败", isPresented: $showImportError) {
                Button("确定") {}
            } message: {
                Text(importError ?? "未知错误")
            }
            .alert("导入成功", isPresented: $showImportSuccess) {
                Button("确定") {}
            } message: {
                Text("站点、NAS 配置和阅读设置已恢复。")
            }
        }
    }

    // MARK: - Config export / import

    private func exportConfig() {
        let backup = ConfigBackup.export(
            sites: sites,
            nasConfigs: nasConfigs,
            fontSize: fontSize,
            theme: theme,
            blockerEnabled: blockerEnabled, readingMode: readingMode
        )
        do {
            exportFileURL = try backup.writeToTempFile()
            showExportShare = true
        } catch {
            importError = error.localizedDescription
            showImportError = true
        }
    }

    private func handleImportFile(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            do {
                pendingBackup = try ConfigBackup.read(from: url)
                showImportConfirm = true
            } catch {
                importError = "文件解析失败：\(error.localizedDescription)"
                showImportError = true
            }
        case .failure(let error):
            importError = error.localizedDescription
            showImportError = true
        }
    }

    private func applyImport() {
        guard let backup = pendingBackup else { return }
        do {
            try backup.apply(to: context)
            // Refresh AppStorage bindings from UserDefaults
            fontSize = UserDefaults.standard.double(forKey: "readerFontSize")
            if let raw = UserDefaults.standard.string(forKey: "readerTheme"),
               let t = AppTheme(rawValue: raw) {
                theme = t
            }
            readingMode = NovelReadingMode(rawValue: UserDefaults.standard.string(forKey: NovelReadingMode.storageKey) ?? "") ?? .paged
            blockerEnabled = UserDefaults.standard.bool(forKey: "contentBlockerEnabled")
            pendingBackup = nil
            showImportSuccess = true
        } catch {
            importError = "导入失败：\(error.localizedDescription)"
            showImportError = true
        }
    }

    // MARK: - Clear all data

    private func clearAllData() async {
        isClearing = true
        defer { isClearing = false }

        // 1. Delete all SwiftData models
        try? context.delete(model: ReadingHistory.self)
        try? context.delete(model: FavoriteVideo.self)
        try? context.delete(model: BookmarkSite.self)
        try? context.delete(model: NASConfig.self)
        try? context.delete(model: OfflineItem.self)
        try? context.save()
        try? SiteDefinitionStore.shared.replace([])

        // 2. Clear caches & downloads
        await ThumbnailCache.shared.clearAll()
        await NASThumbnailCache.shared.clear()
        await GalleryCache.clearAll()
        DownloadManager.shared.downloads.removeAll()
        DownloadManager.shared.pendingPersist.removeAll()

        // 3. Delete offline files
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let offlineDir = docs.appendingPathComponent("Offline", isDirectory: true)
        try? FileManager.default.removeItem(at: offlineDir)

        // 4. Reset UserDefaults settings
        for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasPrefix(BrowserLayout.preferencePrefix) {
            UserDefaults.standard.removeObject(forKey: key)
        }
        fontSize = 17
        theme = .system
        readingMode = .paged
        blockerEnabled = true
    }
}

struct NASConfigRow: View {
    let config: NASConfig
    var body: some View {
        VStack(alignment: .leading) {
            Text(config.name).font(.body)
            Text(config.requiresSMBSetup ? "需要重新配置 SMB" : "\(config.host):\(config.port) / \(config.shareName)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct BlockerRulesView: View {
    var body: some View {
        List {
            Text("内置 EasyList 精简规则（已加载）")
                .foregroundStyle(.secondary)
        }
        .appSurface()
        .navigationTitle("拦截规则")
    }
}

// MARK: - Share sheet

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - Bundle extension

extension Bundle {
    var appVersion: String {
        (infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0"
    }
}
