import SwiftUI
import SwiftData

/// Root container — iPhone uses TabView, iPad uses NavigationSplitView.
struct ContentView: View {
    @Environment(\.horizontalSizeClass) private var hSizeClass
    @State private var openedSite: SiteDefinition?
    @State private var importError: String?

    var body: some View {
        Group {
            if hSizeClass == .regular { iPadRootView() }
            else { iPhoneRootView() }
        }
        .onOpenURL { url in
            guard url.pathExtension.lowercased() == "site" else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do { openedSite = try SiteDefinition.decode(String(contentsOf: url, encoding: .utf8)) }
            catch { importError = error.localizedDescription }
        }
        .sheet(item: $openedSite) { SiteImportSheet(definition: $0) }
        .alert("导入失败", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("好") { importError = nil }
        } message: { Text(importError ?? "") }
    }
}

// MARK: - iPhone: TabView

private struct iPhoneRootView: View {
    @State private var selectedTab: AppTab = .home

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("主页", systemImage: "house.fill", value: AppTab.home) {
                HomeView()
            }
            Tab("收藏", systemImage: "heart.fill", value: AppTab.favorites) {
                FavoritesView()
            }
            Tab("NAS", systemImage: "externaldrive.fill.badge.wifi", value: AppTab.nas) {
                NASBrowserView()
            }
            Tab("设置", systemImage: "gearshape.fill", value: AppTab.settings) {
                SettingsView()
            }
        }
        .overlay { PersistenceObserver() }
    }
}

// MARK: - iPad: NavigationSplitView (3-column)

private struct iPadRootView: View {
    @State private var selectedTab: AppTab? = .home

    var body: some View {
        NavigationSplitView {
            List(AppTab.allCases, selection: $selectedTab) { tab in
                Label(tab.label, systemImage: tab.icon)
                    .tag(tab)
            }
            .navigationTitle("EasyReader")
        } detail: {
            switch selectedTab {
            case .home:      HomeView()
            case .favorites: FavoritesView()
            case .nas:       NASBrowserView()
            case .settings:  SettingsView()
            case nil:        HomeView()
            }
        }
        .overlay { PersistenceObserver() }
    }
}

// MARK: - Supporting types

enum AppTab: String, CaseIterable, Identifiable {
    case home, favorites, nas, settings
    var id: String { rawValue }

    var label: String {
        switch self {
        case .home:     "主页"
        case .favorites: "收藏"
        case .nas:       "NAS"
        case .settings:  "设置"
        }
    }

    var icon: String {
        switch self {
        case .home:     "house.fill"
        case .favorites: "heart.fill"
        case .nas:       "externaldrive.fill.badge.wifi"
        case .settings:  "gearshape.fill"
        }
    }
}

struct ContentPlaceholderView: View {
    var body: some View {
        ContentUnavailableView("选择内容", systemImage: "book.closed", description: Text("从左侧选择一个项目开始阅读"))
    }
}

/// Observes pendingSave / pendingPersist and persists to SwiftData.
/// Isolated from the root view so download progress doesn't trigger full tab re-evaluation.
private struct PersistenceObserver: View {
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .onChange(of: DownloadManager.shared.pendingPersist.count) { _, count in
                guard count > 0 else { return }
                let batch = DownloadManager.shared.drainPendingPersist()
                for dl in batch {
                    let item = OfflineItem(
                        title: dl.title,
                        sourceURL: dl.isNAS ? nil : dl.sourceURL,
                        localPath: dl.localPath,
                        fileType: dl.fileType,
                        fileSizeBytes: dl.fileSizeBytes
                    )
                    item.thumbnailData = dl.thumbnailData
                    modelContext.insert(item)
                }
            }
    }
}
