import SwiftUI
import SwiftData
import os

/// Root container — iPhone uses TabView, iPad uses NavigationSplitView.
struct ContentView: View {
    var downloadManager: DownloadManager = .shared
    @Environment(\.horizontalSizeClass) private var hSizeClass
    @State private var openedSite: SiteDefinition?
    @State private var importError: String?

    var body: some View {
        Group {
            if hSizeClass == .regular { iPadRootView(downloadManager: downloadManager) }
            else { iPhoneRootView(downloadManager: downloadManager) }
        }
        .overlay { PersistenceObserver(manager: downloadManager) }
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
    let downloadManager: DownloadManager
    @State private var selectedTab: AppTab = .home

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab(AppTab.home.label, systemImage: AppTab.home.icon, value: AppTab.home) {
                HomeView(downloadManager: downloadManager)
            }
            Tab(AppTab.favorites.label, systemImage: AppTab.favorites.icon, value: AppTab.favorites) {
                FavoritesView()
            }
            Tab(AppTab.nas.label, systemImage: AppTab.nas.icon, value: AppTab.nas) {
                NASBrowserView()
            }
            Tab(AppTab.settings.label, systemImage: AppTab.settings.icon, value: AppTab.settings) {
                SettingsView()
            }
        }
    }
}

// MARK: - iPad: NavigationSplitView (3-column)

private struct iPadRootView: View {
    let downloadManager: DownloadManager
    @State private var selectedTab: AppTab? = .home

    var body: some View {
        NavigationSplitView {
            List(AppTab.allCases, selection: $selectedTab) { tab in
                Label(tab.label, systemImage: tab.icon)
                    .tag(tab)
            }
            .appSurface()
            .navigationTitle("Cove")
        } detail: {
            switch selectedTab {
            case .home:      HomeView(downloadManager: downloadManager)
            case .favorites: FavoritesView()
            case .nas:       NASBrowserView()
            case .settings:  SettingsView()
            case nil:        HomeView(downloadManager: downloadManager)
            }
        }
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

/// Observes pendingSave / pendingPersist and persists to SwiftData.
/// Isolated from the root view so download progress doesn't trigger full tab re-evaluation.
private struct PersistenceObserver: View {
    let manager: DownloadManager
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .onChange(of: manager.pendingPersist.map(\.id), initial: true) { _, ids in
                guard !ids.isEmpty else { return }
                let batch = manager.pendingPersist
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
                do {
                    try modelContext.save()
                    _ = manager.drainPendingPersist()
                } catch {
                    modelContext.rollback()
                    Logger(subsystem: "Cove", category: "Storage").error("保存离线记录失败：\(error.localizedDescription, privacy: .private)")
                }
            }
    }
}
