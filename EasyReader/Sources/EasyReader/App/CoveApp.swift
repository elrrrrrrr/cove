import SwiftUI
import SwiftData
import Observation

@Observable @MainActor final class CoveRuntime {
    let container: ModelContainer
    let sources: SourceStore
    let library: LibraryStore
    let audio = AudioPlayback()
    let offline = OfflineService()
    init() throws {
        try CoveStorage.prepare()
        container = try ModelContainer(for: LibraryEntry.self, configurations: ModelConfiguration(url: CoveStorage.data.appendingPathComponent("library.store")))
        sources = SourceStore()
        library = LibraryStore(context: container.mainContext)
        sources.onProviderClosed = { [weak audio] in audio?.stop(sourceID: $0) }
    }
}

@main struct CoveApp: App {
    @State private var runtime: CoveRuntime?
    private let startupError: String?
    init() {
        do { _runtime = State(initialValue: try CoveRuntime()); startupError = nil }
        catch { _runtime = State(initialValue: nil); startupError = error.localizedDescription }
    }
    var body: some Scene {
        WindowGroup {
            if let runtime {
                CoveShell().environment(runtime.sources).environment(runtime.library).environment(runtime.audio).environment(runtime.offline).modelContainer(runtime.container)
                    .task {
                        do { try runtime.sources.bootstrap(library: runtime.library) }
                        catch { runtime.sources.error = error.localizedDescription }
                        Task.detached(priority: .utility) { ArchiveService.cleanAbandoned() }
                    }
            } else { ContentUnavailableView("无法打开资料库", systemImage: "externaldrive.badge.exclamationmark", description: Text(startupError ?? "")) }
        }
    }
}

private enum RootTab: String, CaseIterable, Identifiable {
    case home, sources, favorites, settings
    var id: String { rawValue }
    var label: String { switch self { case .home: "首页"; case .sources: "资源"; case .favorites: "收藏"; case .settings: "设置" } }
    var icon: String { switch self { case .home: "house"; case .sources: "square.stack.3d.up"; case .favorites: "heart"; case .settings: "gearshape" } }
}

private struct CoveShell: View {
    @Environment(SourceStore.self) private var sources
    @Environment(LibraryStore.self) private var library
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.scenePhase) private var phase
    @State private var tab = RootTab.home
    @State private var imported: SourceDefinition?
    var body: some View {
        Group {
            if sizeClass == .regular {
                NavigationSplitView {
                    List(RootTab.allCases, selection: Binding<RootTab?>(get: { tab }, set: { if let value = $0 { tab = value } })) { Label($0.label, systemImage: $0.icon).tag($0) }.navigationTitle("Cove")
                } detail: { destination(tab) }
            } else {
                TabView(selection: $tab) {
                    Tab("首页", systemImage: RootTab.home.icon, value: .home) { CoveHome() }
                    Tab("资源", systemImage: RootTab.sources.icon, value: .sources) { SourcesView() }
                    Tab("收藏", systemImage: RootTab.favorites.icon, value: .favorites) { LibraryView() }
                    Tab("设置", systemImage: RootTab.settings.icon, value: .settings) { CoveSettings() }
                }
            }
        }
        .safeAreaInset(edge: .bottom) { MiniAudioPlayer() }
        .onOpenURL { url in
            guard url.pathExtension.lowercased() == "site" else { return }
            Task {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do { imported = try await Task.detached { try SourceDefinition.read(url) }.value }
                catch { sources.error = error.localizedDescription }
            }
        }
        .sheet(item: $imported) { SourceSetupView(existing: $0) }
        .onChange(of: phase) { _, value in
            if value != .active { do { try library.persist() } catch { library.error = error.localizedDescription } }
        }
        .alert("无法完成操作", isPresented: Binding(get: { sources.error != nil || library.error != nil }, set: { if !$0 { sources.error = nil; library.error = nil } })) {
            Button("好") { sources.error = nil; library.error = nil }
        } message: { Text(sources.error ?? library.error ?? "") }
    }
    @ViewBuilder private func destination(_ tab: RootTab) -> some View {
        switch tab { case .home: CoveHome(); case .sources: SourcesView(); case .favorites: LibraryView(); case .settings: CoveSettings() }
    }
}

private struct CoveHome: View {
    @Environment(SourceStore.self) private var sources
    @Environment(LibraryStore.self) private var library
    @Environment(OfflineService.self) private var offline
    @State private var selected: ResourceItem?
    var body: some View {
        NavigationStack {
            List {
                if let item = library.continuableItems.first {
                    Section("继续阅读") {
                        Button { selected = item } label: {
                            HStack {
                                ResourceThumbnail(item: item).frame(width: 64, height: 64).clipShape(RoundedRectangle(cornerRadius: 10))
                                VStack(alignment: .leading) {
                                    Text(item.title).foregroundStyle(.primary)
                                    ProgressView(value: library.progress[item.id] ?? 0)
                                }
                            }
                        }.buttonStyle(.plain)
                    }
                }
                Section("资源来源") {
                    ForEach(sources.definitions.prefix(6)) { source in
                        NavigationLink {
                            if let entry = source.startingEntries.first { CollectionView(sourceID: source.id, locator: entry.path, title: source.name) }
                        } label: { Label(source.name, systemImage: source.source.adapter.icon) }
                    }
                    if sources.definitions.isEmpty { Text("在“资源”中添加文件夹、SMB 或网站。").foregroundStyle(.secondary) }
                }
                if !offline.jobs.isEmpty {
                    Section("下载") {
                        ForEach(offline.jobs) { job in
                            HStack { VStack(alignment: .leading) { Text(job.item.title); Text(job.status).font(.caption).foregroundStyle(.secondary) }; Spacer(); Button("取消") { offline.cancel(job.id) } }
                        }
                    }
                }
                if !library.offlineItems.isEmpty {
                    Section("离线内容") { ForEach(library.offlineItems) { item in Button(item.title) { selected = item } } }
                }
                if !library.recentItems.isEmpty {
                    Section("最近阅读") {
                        ForEach(library.recentItems.prefix(8)) { item in
                            Button { selected = item } label: { Label(item.title, systemImage: item.kind.icon).foregroundStyle(.primary) }
                        }
                        NavigationLink("查看全部") { LibraryView(favoritesOnly: false) }
                    }
                }
            }.navigationTitle("Cove")
            .fullScreenCover(item: $selected) { item in NavigationStack { ReaderRouter(item: item) } }
        }
    }
}
