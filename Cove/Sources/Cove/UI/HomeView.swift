import SwiftUI
import SwiftData

struct HomeView: View {
    @Query(sort: \BookmarkSite.sortOrder) private var sites: [BookmarkSite]
    @Query(sort: \ReadingHistory.lastReadAt, order: .reverse) private var histories: [ReadingHistory]
    @Query(sort: \OfflineItem.savedAt, order: .reverse) private var offlineItems: [OfflineItem]

    @Environment(\.modelContext) private var context
    @Environment(\.horizontalSizeClass) private var hSize
    @AppStorage(AppTheme.storageKey) private var theme: AppTheme = .cinemaDark
    @Namespace private var zoomNS

    @State private var viewerTarget: ViewerTarget?

    private var columns: Int { hSize == .regular ? 3 : 2 }
    private var latestHistory: ReadingHistory? { histories.first }
    private var recentHistories: [ReadingHistory] { Array(histories.prefix(hSize == .regular ? 12 : 6)) }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    if !sites.isEmpty {
                        sectionHeader("快速访问")
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 16) {
                                ForEach(sites) { site in
                                    NavigationLink { FeedView(site: site) } label: { SiteQuickTile(site: site) }
                                        .buttonStyle(SpringPressButtonStyle())
                                }
                            }
                            .padding(.horizontal)
                        }
                    }

                    if let latest = latestHistory {
                        sectionHeader("继续观看")
                        continueCard(latest)
                    }

                    if !recentHistories.isEmpty {
                        sectionHeader("最近")
                        BentoGrid(items: recentHistories, columns: columns) { item, size in
                            recentCard(item, large: size == .large)
                        }
                    }

                    if !offlineItems.isEmpty {
                        sectionHeader("离线文件")
                        LazyVStack(spacing: 8) {
                            ForEach(offlineItems) { item in
                                offlineRow(item)
                            }
                        }
                        .padding(.horizontal)
                    }

                    if sites.isEmpty && histories.isEmpty && offlineItems.isEmpty {
                        ContentUnavailableView(
                            "还没有内容",
                            systemImage: "sparkles",
                            description: Text("去「设置」导入 .site 站点配置或连接 NAS")
                        )
                        .padding(.top, 60)
                    }
                }
                .padding(.vertical)
            }
            .appSurface(theme)
            .navigationTitle("主页")
            .navigationDestination(item: $viewerTarget) { target in
                ResourceRouter(target: target)
                    .coveZoomDestination(id: target.id, in: zoomNS)
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title).font(.title3.bold()).padding(.horizontal)
    }

    private func continueCard(_ item: ReadingHistory) -> some View {
        let target = ViewerTarget.history(item)
        return Button { viewerTarget = target } label: {
            HStack(spacing: 14) {
                historyThumb(item)
                    .frame(width: 96, height: 60)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.displayTitle).font(.headline).foregroundStyle(theme.textColor).lineLimit(2)
                    if !item.isWebVideoPlayback {
                        ProgressView(value: item.clampedFraction).tint(.accentColor)
                    }
                    Text("\(item.progressSummary) · \(item.lastReadAt.formatted(.relative(presentation: .named)))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "play.circle.fill").font(.title2).foregroundStyle(.tint)
            }
            .padding(12)
            .background(theme.cardColor, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .coveZoomSource(id: target.id, in: zoomNS)
        }
        .buttonStyle(SpringPressButtonStyle())
        .padding(.horizontal)
    }

    private func recentCard(_ item: ReadingHistory, large: Bool) -> some View {
        let target = ViewerTarget.history(item)
        return Button { viewerTarget = target } label: {
            VStack(alignment: .leading, spacing: 0) {
                historyThumb(item)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.displayTitle)
                        .font(large ? .subheadline.weight(.semibold) : .caption.weight(.medium))
                        .foregroundStyle(theme.textColor)
                        .lineLimit(1)
                    if item.isWebVideoPlayback {
                        Text(item.progressSummary).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    } else {
                        ProgressView(value: item.clampedFraction).tint(.accentColor)
                    }
                }
                .padding(.horizontal, 4).padding(.vertical, 6)
            }
            .coveZoomSource(id: target.id, in: zoomNS)
        }
        .buttonStyle(SpringPressButtonStyle())
        .contextMenu {
            Button(role: .destructive) {
                context.delete(item); try? context.save()
            } label: { Label("删除记录", systemImage: "trash") }
        }
    }

    private func offlineRow(_ item: OfflineItem) -> some View {
        let target = ViewerTarget.offline(item)
        return Button { viewerTarget = target } label: {
            HStack(spacing: 12) {
                Image(systemName: item.fileType.systemImage)
                    .frame(width: 38, height: 38)
                    .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).font(.subheadline.weight(.medium)).foregroundStyle(theme.textColor).lineLimit(1)
                    Text(item.formattedSize).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(12)
            .background(theme.cardColor, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(SpringPressButtonStyle())
        .contextMenu {
            Button(role: .destructive) {
                let path = item.localPath
                context.delete(item); try? context.save()
                if !path.isEmpty { OfflineFiles.shared.deleteFile(path: path) }
            } label: { Label("删除离线文件", systemImage: "trash") }
        }
    }

    @ViewBuilder
    private func historyThumb(_ item: ReadingHistory) -> some View {
        if let url = item.thumbnailURL {
            CoveImage(url: url, referer: item.url.flatMap(URL.init(string:)), definitionID: item.definitionID, placeholder: item.fileType.systemImage)
        } else if let data = item.thumbnailData, let img = UIImage(data: data) {
            Image(uiImage: img).resizable().scaledToFill()
        } else {
            Color.secondary.opacity(0.14)
                .overlay { Image(systemName: item.fileType.systemImage).foregroundStyle(.secondary) }
        }
    }
}
