import SwiftUI
import UniformTypeIdentifiers

struct FolderSyncView: View {
    @State private var manager = FolderSyncManager.shared
    @State private var chooseFolder = false
    @State private var selectionError: String?
    @State private var showSyncError = false
    var body: some View {
        Form {
            Section {
                if let folder = manager.folderName { LabeledContent("同步文件夹", value: folder) }
                if !manager.isSyncing {
                    HStack {
                        Text(manager.message).font(.callout).foregroundStyle(.secondary).accessibilityIdentifier("folder-sync-status")
                        if manager.errorDetails != nil {
                            Spacer()
                            Button("查看原因") { showSyncError = true }.foregroundColor(.accentColor)
                        }
                    }
                }
                if let date = manager.lastSync {
                    LabeledContent("最近同步") { Text(date, format: .dateTime.month().day().hour().minute()) }
                }
                Button { chooseFolder = true } label: {
                    Label(manager.isConnected ? "重新选择文件夹" : "选择 iCloud Drive 文件夹", systemImage: "folder.badge.plus")
                }
                .foregroundColor(.accentColor).accessibilityIdentifier("folder-sync-choose").disabled(manager.isSyncing)
                if manager.isConnected {
                    Toggle("打开应用时自动同步", isOn: $manager.automatic)
                    Button { Task { await manager.synchronize() } } label: {
                        HStack {
                            Label(manager.isSyncing ? "同步中…" : "立即同步", systemImage: "arrow.triangle.2.circlepath")
                            if manager.isSyncing { Spacer(); ProgressView() }
                        }
                    }.disabled(manager.isSyncing)
                    Button("断开同步", role: .destructive) { manager.disconnect() }.disabled(manager.isSyncing)
                }
            } header: { Text("iCloud Drive") } footer: {
                Text("在各设备上选择同一个 iCloud Drive 文件夹。")
            }
            Section {
                Label("站点与收藏", systemImage: "star")
                Label("阅读记录与设置", systemImage: "book")
                Label("NAS 信息与离线文件", systemImage: "externaldrive")
            } header: { Text("同步内容") } footer: { Text("NAS 密码仅保存在本机。") }
        }
        .appSurface().navigationTitle("文件夹同步")
        .fileImporter(isPresented: $chooseFolder, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let url): Task { await manager.connect(url) }
            case .failure(let error): selectionError = error.localizedDescription
            }
        }
        .alert("文件夹选择失败", isPresented: Binding(get: { selectionError != nil }, set: { if !$0 { selectionError = nil } })) {
            Button("确定") { selectionError = nil }
        } message: { Text(selectionError ?? "") }
        .alert("同步失败", isPresented: $showSyncError) {
            Button("确定", role: .cancel) { }
        } message: { Text(manager.errorDetails ?? "") }
    }
}
