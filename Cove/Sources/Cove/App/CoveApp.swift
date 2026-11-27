import SwiftUI
import SwiftData

@main
struct CoveApp: App {
    let modelContainer: ModelContainer
    private let freshInstall: Bool

    @AppStorage(AppTheme.storageKey) private var theme: AppTheme = .cinemaDark
    @State private var store = SiteDefinitionStore.shared
    @State private var activeTab = 0

    init() {
        do {
            let prep = try LocalAppStorage.prepareModelStore()
            self.freshInstall = prep.freshInstall
            let config = ModelConfiguration(url: prep.url)
            self.modelContainer = try ModelContainer(
                for: BookmarkSite.self, FavoriteVideo.self, ReadingHistory.self, OfflineItem.self, NASConfig.self,
                configurations: config
            )
        } catch {
            fatalError("无法打开数据库：\(error.localizedDescription)")
        }
    }

    var body: some Scene {
        WindowGroup {
            TabView(selection: $activeTab) {
                Tab("主页", systemImage: "house.fill", value: 0) {
                    HomeView()
                }
                Tab("收藏", systemImage: "heart.fill", value: 1) {
                    LibraryView()
                }
                Tab("NAS", systemImage: "externaldrive.connected.to.line.below.fill", value: 2) {
                    NASRootView()
                }
                Tab("设置", systemImage: "gearshape.fill", value: 3) {
                    SettingsView()
                }
            }
            .tabBarMinimizeBehavior(.onScrollDown)
            .preferredColorScheme(theme.colorScheme)
            .tint(.accentColor)
            .overlay(alignment: .top) { ToastOverlay() }
            .task {
                store.initialize(context: modelContainer.mainContext, freshInstall: freshInstall)
                if FolderSyncManager.shared.isConnected {
                    await FolderSyncManager.shared.syncNow(context: modelContainer.mainContext)
                }
            }
            .onOpenURL { url in
                guard url.pathExtension.lowercased() == "site" else { return }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                if let text = try? String(contentsOf: url, encoding: .utf8),
                   let def = try? SiteDefinition.decode(text) {
                    store.pendingImport = def
                    activeTab = 3
                }
            }
        }
        .modelContainer(modelContainer)
    }
}
