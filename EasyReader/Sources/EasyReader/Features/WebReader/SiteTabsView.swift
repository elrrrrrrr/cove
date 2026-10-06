import SwiftUI
import SwiftData

/// 网站入口 — 站点名称作为可水平滑动的选项卡嵌入导航栏标题区，
/// 内容区域通过横向翻页 TabView 切换，操作与 iOS 照片 App 的分类切换一致。
struct SiteTabsView: View {
    @Query(sort: \BookmarkSite.sortOrder) private var sites: [BookmarkSite]
    @Environment(\.modelContext) private var context

    @State private var selectedIndex: Int = 0
    @State private var showManage = false

    var body: some View {
        NavigationStack {
            Group {
                if sites.isEmpty {
                    ContentUnavailableView {
                        Label("暂无站点", systemImage: "safari")
                    } description: {
                        Text("点击右上角 ⋯ 添加网站")
                    }
                } else {
                    TabView(selection: $selectedIndex) {
                        ForEach(Array(sites.enumerated()), id: \.offset) { i, site in
                            SiteGalleryView(
                                site:       site,
                                isTabPage:  true,
                                isSelected: selectedIndex == i
                            )
                            .tag(i)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                    .ignoresSafeArea(edges: .bottom)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // ── Centre: scrollable site-name tabs (iOS Photos style) ──────
                ToolbarItem(placement: .principal) {
                    if sites.isEmpty {
                        Text("网站").font(.headline)
                    } else {
                        SiteTabPicker(sites: sites, selectedIndex: $selectedIndex)
                    }
                }
                // ── Trailing: site management ─────────────────────────────────
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showManage = true } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .sheet(isPresented: $showManage) {
                SiteListView()
            }
        }
    }
}

// MARK: - iOS Photos-style site tab picker

/// Horizontally scrollable site-name selector embedded in the navigation bar's
/// principal area. Selected item gets a thin accent-coloured underline; tapping
/// any label or swiping the content below updates the selection in sync.
private struct SiteTabPicker: View {
    let sites: [BookmarkSite]
    @Binding var selectedIndex: Int

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(Array(sites.enumerated()), id: \.offset) { i, site in
                        Button {
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.78)) {
                                selectedIndex = i
                            }
                        } label: {
                            tabLabel(site.name, isSelected: selectedIndex == i)
                        }
                        .buttonStyle(.plain)
                        .id(i)
                    }
                }
                .padding(.horizontal, 2)
            }
            // Give the scroll region room to breathe inside the nav bar without
            // crowding the leading back-button or trailing action buttons.
            .frame(maxWidth: 320)
            .onChange(of: selectedIndex) { _, i in
                withAnimation(.spring(response: 0.28)) {
                    proxy.scrollTo(i, anchor: .center)
                }
            }
        }
    }

    @ViewBuilder
    private func tabLabel(_ name: String, isSelected: Bool) -> some View {
        VStack(spacing: 2) {
            Text(name)
                .font(.subheadline.weight(isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                .fixedSize()
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .contentShape(Rectangle())

            // Thin underline indicator — animated via opacity + scaleEffect
            RoundedRectangle(cornerRadius: 1.5)
                .frame(height: 2.5)
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 10)
                .opacity(isSelected ? 1 : 0)
                .scaleEffect(x: isSelected ? 1 : 0.4)
                .animation(.spring(response: 0.28, dampingFraction: 0.78), value: isSelected)
        }
    }
}
