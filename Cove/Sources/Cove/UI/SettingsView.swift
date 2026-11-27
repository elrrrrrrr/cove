import SwiftUI
import SwiftData
import UniformTypeIdentifiers
@preconcurrency import WebKit

struct SettingsView: View {
    @Query(sort: \BookmarkSite.sortOrder) private var sites: [BookmarkSite]
    @Query private var nasConfigs: [NASConfig]
    @Environment(\.modelContext) private var context

    @AppStorage(AppTheme.storageKey) private var theme: AppTheme = .cinemaDark
    @State private var store = SiteDefinitionStore.shared
    @State private var sync = FolderSyncManager.shared

    @State private var showSiteImporter = false
    @State private var showSyncFolderPicker = false
    @State private var showBackupExporter = false
    @State private var showBackupImporter = false
    @State private var backupDocument: JSONBackupDocument?
    @State private var nasFormTarget: NASFormTarget?
    @State private var showClearConfirm = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                // 1. Theme Switcher (Cinema Dark A / Warm Editorial B / Sepia / System)
                Section("外观主题") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 10)], spacing: 10) {
                        ForEach(AppTheme.allCases) { option in
                            Button {
                                theme = option
                                ToastCenter.shared.show("已切换为\(option.label)", icon: "paintbrush.fill")
                            } label: {
                                VStack(spacing: 6) {
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(option.backgroundColor)
                                        .frame(height: 44)
                                        .overlay(alignment: .bottomLeading) {
                                            RoundedRectangle(cornerRadius: 4).fill(option.cardColor)
                                                .frame(width: 28, height: 14).padding(5)
                                        }
                                        .overlay {
                                            RoundedRectangle(cornerRadius: 10)
                                                .stroke(theme == option ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: theme == option ? 2.5 : 1)
                                        }
                                    Text(option.label).font(.caption2).foregroundStyle(theme.textColor)
                                }
                            }.buttonStyle(.plain)
                        }
                    }.padding(.vertical, 4)
                }

                // 2. Site Management
                Section("站点配置（.site）") {
                    Button("导入 .site 配置", systemImage: "square.and.arrow.down") { showSiteImporter = true }
                    ForEach(sites) { site in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(site.name)
                                Text(URL(string: site.urlString)?.host() ?? site.urlString)
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if site.definitionID != nil {
                                Image(systemName: "checkmark.seal.fill").foregroundStyle(.tint)
                            }
                        }
                    }
                    .onDelete { offsets in
                        for idx in offsets { context.delete(sites[idx]) }
                        try? context.save()
                    }
                }

                // 3. NAS SMB Connections
                Section("NAS 连接（SMB）") {
                    Button("添加 NAS", systemImage: "plus") { nasFormTarget = .new }
                    ForEach(nasConfigs) { cfg in
                        Button { nasFormTarget = .edit(cfg) } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(cfg.name).foregroundStyle(theme.textColor)
                                    Text("\(cfg.host):\(cfg.port) / \(cfg.shareName)")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                            }
                        }
                    }
                }

                // 4. SideStore-Compatible Folder Sync + JSON Backup
                Section("iCloud Drive 文件夹同步（SideStore 兼容）") {
                    if let name = sync.folderName {
                        LabeledContent("同步目录", value: name)
                        if let date = sync.lastSyncAt {
                            LabeledContent("上次同步", value: date.formatted(.relative(presentation: .named)))
                        }
                        Button(sync.isSyncing ? "同步中…" : "立即同步", systemImage: "arrow.triangle.2.circlepath") {
                            Task { await sync.syncNow(context: context) }
                        }.disabled(sync.isSyncing)
                        Button("断开目录同步", role: .destructive) { sync.disconnect() }
                    } else {
                        Button("选择 iCloud Drive 同步目录", systemImage: "folder") { showSyncFolderPicker = true }
                    }
                    if let syncErr = sync.lastError { Text(syncErr).font(.caption).foregroundStyle(.red) }
                    Button("导出 JSON 备份（不含密码）", systemImage: "square.and.arrow.up") { exportBackup() }
                    Button("导入 JSON 备份", systemImage: "square.and.arrow.down") { showBackupImporter = true }
                }

                // 5. Storage & Reset
                Section("存储") {
                    Button("清除图片与网页缓存", systemImage: "trash") { clearCaches() }
                    Button("清空全部本地数据", systemImage: "exclamationmark.triangle", role: .destructive) {
                        showClearConfirm = true
                    }
                }
            }
            .appSurface(theme)
            .navigationTitle("设置")
            .sheet(item: $store.pendingImport) { def in importConfirmSheet(def) }
            .sheet(item: $nasFormTarget) { target in NASFormSheet(target: target) }
            .fileImporter(isPresented: $showSiteImporter, allowedContentTypes: [.coveSite, .plainText, .data]) { res in
                handleSiteFile(res)
            }
            .fileImporter(isPresented: $showSyncFolderPicker, allowedContentTypes: [.folder]) { res in
                if case .success(let url) = res { Task { await sync.connect(folderURL: url, context: context) } }
            }
            .fileImporter(isPresented: $showBackupImporter, allowedContentTypes: [.json]) { res in
                handleBackupImport(res)
            }
            .fileExporter(isPresented: $showBackupExporter, document: backupDocument, contentType: .json, defaultFilename: "cove-backup.json") { _ in }
            .confirmationDialog("清空全部站点、收藏、历史、离线与 NAS 记录？", isPresented: $showClearConfirm, titleVisibility: .visible) {
                Button("确认清空", role: .destructive) { clearAllData() }
            }
            .alert("操作失败", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("好") { error = nil }
            } message: { Text(error ?? "") }
        }
    }

    private func importConfirmSheet(_ def: SiteDefinition) -> some View {
        let exists = store.definition(id: def.id) != nil
        return NavigationStack {
            Form {
                Section("站点信息") {
                    LabeledContent("名称", value: def.name)
                    LabeledContent("ID", value: def.id)
                    LabeledContent("入口数", value: "\(def.entries.count)")
                    LabeledContent("规则数", value: "\(def.rules.count)")
                }
                Section {
                    Button(exists ? "替换现有配置" : "导入站点") {
                        do {
                            try store.importDefinition(def, context: context)
                            store.pendingImport = nil
                            ToastCenter.shared.show("已导入 \(def.name)")
                        } catch { self.error = error.localizedDescription }
                    }
                    if exists {
                        Button("另存为副本") {
                            do {
                                try store.importDefinition(def, context: context, asCopy: true)
                                store.pendingImport = nil
                            } catch { self.error = error.localizedDescription }
                        }
                    }
                }
            }
            .navigationTitle("导入 .site")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { store.pendingImport = nil } } }
        }
    }

    private func handleSiteFile(_ res: Result<URL, Error>) {
        do {
            let url = try res.get()
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            store.pendingImport = try SiteDefinition.decode(String(contentsOf: url, encoding: .utf8))
        } catch { self.error = error.localizedDescription }
    }

    private func exportBackup() {
        do {
            let data = try CoveSyncPayload.encode(try CoveSyncPayload.snapshot(from: context))
            backupDocument = JSONBackupDocument(data: data)
            showBackupExporter = true
        } catch { self.error = error.localizedDescription }
    }

    private func handleBackupImport(_ res: Result<URL, Error>) {
        do {
            let url = try res.get()
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            try CoveSyncPayload.merge(try CoveSyncPayload.decode(Data(contentsOf: url)), into: context)
            ToastCenter.shared.show("已导入备份")
        } catch { self.error = error.localizedDescription }
    }

    private func clearCaches() {
        CoveImagePipeline.clearCache()
        WKWebsiteDataStore.default().removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {}
        ToastCenter.shared.show("已清除缓存")
    }

    private func clearAllData() {
        for cfg in nasConfigs { NASKeychain.delete(for: cfg.id) }
        try? context.delete(model: BookmarkSite.self)
        try? context.delete(model: FavoriteVideo.self)
        try? context.delete(model: ReadingHistory.self)
        try? context.delete(model: OfflineItem.self)
        try? context.delete(model: NASConfig.self)
        try? context.save()
        try? OfflineFiles.shared.clear()
        sync.disconnect()
        clearCaches()
    }
}

private enum NASFormTarget: Identifiable {
    case new, edit(NASConfig)
    var id: String { switch self { case .new: "new"; case .edit(let c): c.id.uuidString } }
}

private struct NASFormSheet: View {
    let target: NASFormTarget
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var host = ""
    @State private var port = "445"
    @State private var username = ""
    @State private var password = ""
    @State private var shareName = ""
    @State private var testing = false
    @State private var statusMessage: String?

    private var existing: NASConfig? { if case .edit(let c) = target { c } else { nil } }
    private var validPort: Int? { Int(port).flatMap { (1...65535).contains($0) ? $0 : nil } }
    private var canSave: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty && !host.trimmingCharacters(in: .whitespaces).isEmpty && !shareName.trimmingCharacters(in: .whitespaces).isEmpty && validPort != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section("SMB 连接") {
                    TextField("名称", text: $name)
                    TextField("IP / 主机名", text: $host).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("端口（默认 445）", text: $port).keyboardType(.numberPad)
                    TextField("共享名", text: $shareName).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Section("凭据") {
                    TextField("用户名", text: $username).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("密码", text: $password)
                }
                Section {
                    Button { test() } label: { if testing { ProgressView() } else { Text("测试连接") } }.disabled(!canSave || testing)
                    if let statusMessage { Text(statusMessage).font(.caption).foregroundStyle(.secondary) }
                }
                if let existing {
                    Section {
                        Button("删除 NAS", role: .destructive) {
                            NASKeychain.delete(for: existing.id)
                            context.delete(existing); try? context.save(); dismiss()
                        }
                    }
                }
            }
            .navigationTitle(existing == nil ? "添加 NAS" : "编辑 NAS")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { save() }.disabled(!canSave) }
            }
            .onAppear {
                guard let c = existing else { return }
                name = c.name; host = c.host; port = "\(c.port)"; username = c.username; shareName = c.shareName
                password = NASKeychain.load(for: c.id) ?? ""
            }
        }
    }

    private func test() {
        testing = true; statusMessage = nil
        let snap = NASConfigSnapshot(config: NASConfig(name: name, host: host, port: validPort ?? 445, username: username, shareName: shareName))
        let pwd = password
        Task {
            let client = SMBClient(snapshot: snap)
            do {
                try await client.connect(password: pwd)
                await client.disconnect()
                statusMessage = "连接成功"
            } catch { statusMessage = error.localizedDescription }
            testing = false
        }
    }

    private func save() {
        let cfg = existing ?? NASConfig(name: name, host: host, port: validPort ?? 445, username: username, shareName: shareName)
        cfg.name = name; cfg.host = host; cfg.port = validPort ?? 445; cfg.username = username; cfg.shareName = shareName
        if existing == nil { context.insert(cfg) }
        if password.isEmpty { NASKeychain.delete(for: cfg.id) } else { NASKeychain.save(password: password, for: cfg.id) }
        try? context.save(); dismiss()
    }
}

private struct JSONBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
