import SwiftUI
import SwiftData

struct LibraryView: View {
    enum Segment: String, CaseIterable { case favorites = "收藏", history = "历史" }
    enum KindFilter: String, CaseIterable { case all = "全部", video = "视频", comic = "漫画", article = "图文" }

    @Query(sort: \FavoriteVideo.addedAt, order: .reverse) private var favorites: [FavoriteVideo]
    @Query(sort: \ReadingHistory.lastReadAt, order: .reverse) private var histories: [ReadingHistory]

    @Environment(\.modelContext) private var context
    @Environment(\.horizontalSizeClass) private var hSize
    @AppStorage(AppTheme.storageKey) private var theme: AppTheme = .cinemaDark
    @Namespace private var zoomNS

    @State private var segment: Segment = .favorites
    @State private var filter: KindFilter = .all
    @State private var viewerTarget: ViewerTarget?
    @State private var showClearHistory = false

    private var filteredFavorites: [FavoriteVideo] {
        favorites.filter { fav in
            switch filter {
            case .all: true
            case .video: !fav.isComic && !fav.isArticle
            case .comic: fav.isComic
            case .article: fav.isArticle
            }
        }
    }

    private var pinned: [FavoriteVideo] {
        filteredFavorites.filter(\.isPinned).sorted { $0.pinOrder < $1.pinOrder }
    }

    private var unpinned: [FavoriteVideo] {
        filteredFavorites.filter { !$0.isPinned }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $segment) {
                    ForEach(Segment.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal).padding(.vertical, 8)

                if segment == .favorites {
                    favoritesContent
                } else {
                    historyContent
                }
            }
            .appSurface(theme)
            .navigationTitle(segment.rawValue)
            .toolbar {
                if segment == .history && !histories.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("清除", role: .destructive) { showClearHistory = true }
                    }
                }
            }
            .confirmationDialog("确定清除所有历史记录？", isPresented: $showClearHistory, titleVisibility: .visible) {
                Button("全部清除", role: .destructive) {
                    try? context.delete(model: ReadingHistory.self); try? context.save()
                }
            }
            .navigationDestination(item: $viewerTarget) { target in
                ResourceRouter(target: target).coveZoomDestination(id: target.id, in: zoomNS)
            }
        }
    }

    @ViewBuilder
    private var favoritesContent: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(KindFilter.allCases, id: \.self) { kind in
                    Button { filter = kind } label: {
                        Text(kind.rawValue)
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(filter == kind ? Color.accentColor : theme.cardColor, in: Capsule())
                            .foregroundStyle(filter == kind ? .white : theme.textColor)
                    }.buttonStyle(.plain)
                }
            }.padding(.horizontal).padding(.bottom, 8)
        }

        if filteredFavorites.isEmpty {
            ContentUnavailableView("暂无收藏", systemImage: "heart")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if !pinned.isEmpty {
                        Text("置顶").font(.headline).padding(.horizontal)
                        favoriteGrid(pinned)
                    }
                    if !unpinned.isEmpty {
                        if !pinned.isEmpty { Text("全部").font(.headline).padding(.horizontal) }
                        favoriteGrid(unpinned)
                    }
                }.padding(.vertical, 8)
            }
        }
    }

    private func favoriteGrid(_ items: [FavoriteVideo]) -> some View {
        let cols = Array(repeating: GridItem(.flexible(), spacing: 10), count: hSize == .regular ? 3 : 2)
        return LazyVGrid(columns: cols, spacing: 12) {
            ForEach(items) { fav in
                if let url = fav.pageURL {
                    let parsed = ParsedItem(title: fav.title, pageURL: url, thumbnail: fav.thumbnailURL,
                                            duration: fav.duration, extra: fav.siteName)
                    let target = ViewerTarget.webItem(parsed, kind: fav.contentKind, definitionID: fav.definitionID, siteName: fav.siteName)
                    MediaCard(item: parsed, mode: .bento(.small), isFavorited: true, definitionID: fav.definitionID) {
                        viewerTarget = target
                    }
                    .frame(height: 155)
                    .coveZoomSource(id: target.id, in: zoomNS)
                    .contextMenu {
                        Button(fav.isPinned ? "取消置顶" : "置顶", systemImage: fav.isPinned ? "pin.slash" : "pin") {
                            fav.isPinned.toggle(); try? context.save()
                        }
                        Button("取消收藏", systemImage: "heart.slash", role: .destructive) {
                            context.delete(fav); try? context.save()
                        }
                    }
                }
            }
        }.padding(.horizontal, 12)
    }

    @ViewBuilder
    private var historyContent: some View {
        if histories.isEmpty {
            ContentUnavailableView("暂无历史记录", systemImage: "clock.arrow.circlepath")
        } else {
            List {
                ForEach(groupedHistory, id: \.title) { section, items in
                    Section(section) {
                        ForEach(items) { item in
                            Button { viewerTarget = .history(item) } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: item.fileType.systemImage)
                                        .frame(width: 34, height: 34)
                                        .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
                                        .foregroundStyle(.tint)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.displayTitle).foregroundStyle(theme.textColor).lineLimit(1)
                                        Text(item.lastReadAt.formatted(date: .omitted, time: .shortened))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(item.progressSummary).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                }
                            }
                            .swipeActions {
                                Button(role: .destructive) { context.delete(item); try? context.save() } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
    }

    private var groupedHistory: [(title: String, items: [ReadingHistory])] {
        let cal = Calendar.current
        var groups: [String: [ReadingHistory]] = [:]
        for item in histories {
            let key = cal.isDateInToday(item.lastReadAt) ? "今天" : (cal.isDateInYesterday(item.lastReadAt) ? "昨天" : "更早")
            groups[key, default: []].append(item)
        }
        return ["今天", "昨天", "更早"].compactMap { key in groups[key].map { (key, $0) } }
    }
}
