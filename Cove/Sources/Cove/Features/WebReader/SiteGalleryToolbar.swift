import SwiftUI

/// Toolbar for ``SiteGalleryView``: status subtitle, category / jump-to-page menu,
/// layout picker and the tools menu. Extracted verbatim from SiteGalleryView.
struct GalleryToolbar: ToolbarContent {
    let parser: SiteParser
    let loader: PageLoader
    let bookmarkSite: BookmarkSite?
    let siteURLString: String
    @Binding var navigation: SiteCatalogNavigation
    @Binding var searchText: String
    @Binding var showParsingWeb: Bool
    @Binding var showWeb: Bool
    @Binding var showPageInput: Bool
    @Binding var pageInputText: String
    @Binding var showJSConfig: Bool
    @Binding var showDebugSheet: Bool
    @Binding var layout: BrowserLayout
    var onRefreshParser: () -> Void

    private var effectiveURLString: String { navigation.categoryURLString }

    // Category binding for Picker
    private var categorySelection: Binding<String> {
        Binding(
            get: {
                // Return matching category's raw urlString for Picker tag matching
                let active = effectiveURLString
                if let cat = parser.categories.first(where: {
                    $0.urlString == active || active.hasSuffix($0.urlString)
                }) {
                    return cat.urlString
                }
                return active
            },
            set: { newURL in
                // Resolve relative category paths against the WebView's actual domain
                // Handles redirects from a portal to its current content host.
                let resolved: URL?
                if newURL.hasPrefix("http") {
                    resolved = URL(string: newURL)
                } else if let base = loader.resolvedBaseURL ?? URL(string: siteURLString) {
                    resolved = URL(string: newURL, relativeTo: base)?.absoluteURL
                } else {
                    resolved = nil
                }
                guard let url = resolved else { return }
                var nav = navigation
                nav.selectCategory(url)
                navigation = nav
                searchText = ""
                onRefreshParser()
            }
        )
    }

    /// Current category name for status subtitle.
    private var activeCategoryName: String {
        let active = effectiveURLString
        if let cat = parser.categories.first(where: {
            $0.urlString == active || active.hasSuffix($0.urlString)
        }) {
            return cat.name
        }
        return ""
    }

    /// Status subtitle: "60 项 · 中文字幕" or "搜索: keyword" or "加载第3页…"
    private var statusSubtitle: String {
        if parser.itemKind == .navLink { return "" }
        var parts: [String] = []
        if loader.isLoadingMore {
            parts.append("加载第\(loader.currentPage + 1)页…")
        } else if case .done(let items) = loader.state, !items.isEmpty {
            parts.append("\(items.count) 项")
        }
        if parser.categories.count > 1, !activeCategoryName.isEmpty {
            parts.append(activeCategoryName)
        }
        return parts.joined(separator: " · ")
    }

    @ToolbarContentBuilder
    var body: some ToolbarContent {
        // ── Status subtitle ─────────────────────────────────────
        if !statusSubtitle.isEmpty {
            ToolbarItem(placement: .status) {
                Text(statusSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        // ── Menu 1: category + jump to page ─────────────────────
        if parser.itemKind != .navLink {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if parser.categories.count > 1 {
                        Picker(activeCategoryName, selection: categorySelection) {
                            ForEach(parser.categories, id: \.urlString) { cat in
                                Text(cat.name).tag(cat.urlString)
                            }
                        }
                        Divider()
                    }
                    Button {
                        pageInputText = "\(loader.currentPage)"
                        showPageInput = true
                    } label: {
                        Label("跳转页码", systemImage: "number")
                    }
                } label: {
                    Image(systemName: "book.pages")
                }
            }
        }
        if !showWeb {
            ToolbarItem(placement: .topBarTrailing) { BrowserLayoutMenu(layout: $layout) }
        }
        // ── Menu 2: tools ───────────────────────────────────────
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button("查看原始网页", systemImage: "safari") { showParsingWeb = true }
                    .accessibilityIdentifier("inspect-current-webpage-menu")
                Button { loader.reload() } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                Button { showWeb.toggle() } label: {
                    Label(showWeb ? "解析模式" : "网页模式", systemImage: "safari")
                }
                Divider()
                if bookmarkSite != nil {
                    Button { showJSConfig = true } label: {
                        Label("解析规则", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                }
                Button { showDebugSheet = true } label: {
                    Label("解析结果", systemImage: "ant")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("站点工具")
        }
    }
}
