import SwiftUI
import WebKit
struct GalleryEpisodePickerTarget: Identifiable {
    let item: ParsedItem
    let count: Int
    var id: URL { item.pageURL }
}

struct GalleryEpisodePickerSheet: View {
    let target: GalleryEpisodePickerTarget
    let onSelect: (Int) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 64), spacing: 12)],
                    spacing: 12
                ) {
                    ForEach(1...target.count, id: \.self) { number in
                        Button {
                            onSelect(number)
                        } label: {
                            Text("\(number)")
                                .font(.headline.monospacedDigit())
                                .frame(maxWidth: .infinity, minHeight: 52)
                                .background(Color.secondary.opacity(0.12),
                                            in: RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("第 \(number) 集")
                    }
                }
                .padding()
            }
            .appSurface()
            .navigationTitle("选集 · 共 \(target.count) 集")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Parsed items debug sheet

struct ParsedItemsDebugSheet: View {
    let loader: PageLoader
    let parser: SiteParser
    let pageURL: URL?
    @Environment(\.dismiss) private var dismiss

    private var items: [ParsedItem] {
        if case .done(let items) = loader.state { return items }
        return []
    }

    private var stateLabel: String {
        switch loader.state {
        case .idle:            return "空闲"
        case .loading:         return "加载中…"
        case .extracting:      return "提取中…"
        case .done(let items): return "完成（\(items.count) 项）"
        case .failed(let msg): return "失败：\(msg)"
        }
    }

    private var stateIcon: String {
        switch loader.state {
        case .idle:       return "moon.zzz"
        case .loading:    return "arrow.down.circle"
        case .extracting: return "gearshape.2"
        case .done:       return "checkmark.circle.fill"
        case .failed:     return "xmark.circle.fill"
        }
    }

    private var stateColor: Color {
        switch loader.state {
        case .idle:       return .secondary
        case .loading:    return .orange
        case .extracting: return .blue
        case .done:       return .green
        case .failed:     return .red
        }
    }

    private var paginationLabel: String {
        switch parser.paginationMode {
        case .none:          return "无"
        case .ajax:          return "AJAX"
        case .webNavigation: return "WebNavigation"
        }
    }

    var body: some View {
        NavigationStack {
            List {
                // ── Parse log ──────────────────────────────
                if !loader.parseLog.isEmpty {
                    Section("解析日志") {
                        ForEach(Array(loader.parseLog.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }

                // ── Request status ──────────────────────────
                Section("请求状态") {
                    LabeledContent("状态") {
                        Label(stateLabel, systemImage: stateIcon)
                            .foregroundColor(stateColor)
                    }
                    LabeledContent("翻页模式", value: paginationLabel)
                    LabeledContent("当前页", value: "\(loader.currentPage)")
                    LabeledContent("加载翻页中", value: loader.isLoadingMore ? "是" : "否")
                    if case .ajax = parser.paginationMode {
                        LabeledContent("有下一页", value: loader.hasNextPage ? "是" : "否")
                    }
                    if let next = loader.nextPageURL {
                        LabeledContent("下一页 URL") {
                            Text(next.absoluteString)
                                .font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                }

                Section("页面信息") {
                    LabeledContent("请求 URL") {
                        Text(pageURL?.absoluteString ?? "—")
                            .font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    if let webURL = loader.webView.url, webURL != pageURL {
                        LabeledContent("WebView URL") {
                            Text(webURL.absoluteString)
                                .font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                    LabeledContent("解析项数", value: "\(items.count)")
                }

                // ── Parsed items ────────────────────────────
                ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                    Section("[\(idx + 1)] \(item.title)") {
                        LabeledContent("pageURL") {
                            Text(item.pageURL.absoluteString)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        LabeledContent("thumbnail") {
                            if let thumb = item.thumbnail {
                                VStack(alignment: .trailing, spacing: 6) {
                                    Text(thumb.absoluteString)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                    CachedThumbnail(url: thumb, placeholder: "photo")
                                        .frame(width: 80, height: 50)
                                        .clipShape(RoundedRectangle(cornerRadius: 6))
                                }
                            } else {
                                Text("nil")
                                    .font(.caption2)
                                    .foregroundStyle(.red)
                            }
                        }
                        if !item.duration.isEmpty {
                            LabeledContent("duration", value: item.duration)
                        }
                        if !item.extra.isEmpty {
                            LabeledContent("extra", value: item.extra)
                        }
                    }
                }
            }
            .appSurface()
            .navigationTitle("解析结果")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button {
                            UIPasteboard.general.string = loader.parseLog.joined(separator: "\n")
                        } label: {
                            Label("复制日志", systemImage: "doc.plaintext")
                        }
                        Button {
                            let text = items.enumerated().map { idx, item in
                                """
                                [\(idx + 1)] \(item.title)
                                pageURL: \(item.pageURL.absoluteString)
                                thumbnail: \(item.thumbnail?.absoluteString ?? "nil")
                                duration: \(item.duration)
                                extra: \(item.extra)
                                """
                            }.joined(separator: "\n---\n")
                            UIPasteboard.general.string = text
                        } label: {
                            Label("复制解析结果", systemImage: "doc.on.clipboard")
                        }
                    } label: {
                        Image(systemName: "doc.on.clipboard")
                    }
                }
            }
        }
    }
}

// MARK: - Mixed media detail sheet

struct MixedMediaDetailSheet: View {
    let item: ParsedItem
    let isFavorited: Bool
    let onToggleFavorite: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var webCoordinator = WebCoordinator()
    @State private var pageTitle = ""
    @State private var isLoading = false

    var body: some View {
        ZStack(alignment: .bottom) {
            WebViewRepresentable(
                url: item.pageURL,
                webCoordinator: webCoordinator,
                onTitleChange: { pageTitle = $0 },
                onLoading: { isLoading = $0 }
            )
            .ignoresSafeArea()
            .padding(.top, 52)
                .padding(.bottom, 86)

            VStack(spacing: 0) {
                topBar
                Spacer()
                favoriteBar
            }
        }
        .task {
            await webCoordinator.loadBlocker()
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .frame(width: 32, height: 32)
                    .background(.ultraThinMaterial, in: Circle())
            }
            if isLoading { ProgressView().scaleEffect(0.8) }
            Text(navTitle)
                .font(.headline)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    private var navTitle: String {
        pageTitle.isEmpty ? item.title : pageTitle
    }

    private var favoriteBar: some View {
        Button {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            onToggleFavorite()
        } label: {
            Label(isFavorited ? "取消收藏" : "收藏",
                  systemImage: isFavorited ? "heart.fill" : "heart")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
        }
        .buttonStyle(.borderedProminent)
        .tint(isFavorited ? .pink : .accentColor)
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background(.ultraThinMaterial)
    }
}

// MARK: - Navigation modifier (extracted to reduce body complexity)

struct GalleryNavigationModifier: ViewModifier {
    @Binding var showJSConfig: Bool
    @Binding var showDebugSheet: Bool
    @Binding var extraNavTarget: ExtraNavItem?
    @Binding var videoFullScreen: ParsedItem?
    let bookmarkSite: BookmarkSite?
    /// Derived flag — drives fullScreenCover(isPresented:) for reliability.
    private var isVideoPresented: Binding<Bool> {
        Binding(
            get: { videoFullScreen != nil },
            set: { if !$0 { videoFullScreen = nil } }
        )
    }
    let loader: PageLoader
    let parser: SiteParser
    let pageURL: URL?

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $showJSConfig) {
                if let site = bookmarkSite {
                    SiteConfigSheet(site: site)
                }
            }
            .navigationDestination(item: $extraNavTarget) { target in
                SiteGalleryView(name: target.name, urlString: target.urlString, definitionID: parser.definitionID)
            }
            .sheet(isPresented: $showDebugSheet) {
                ParsedItemsDebugSheet(loader: loader, parser: parser, pageURL: pageURL)
            }
            .fullScreenCover(isPresented: isVideoPresented) {
                if let item = videoFullScreen {
                    VideoDetailView(item: item, definitionID: parser.definitionID)
                }
            }
    }
}

