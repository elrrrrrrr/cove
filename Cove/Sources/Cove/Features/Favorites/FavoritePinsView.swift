import SwiftUI
import SwiftData

struct FavoritePinsView: View {
    @Query(sort: \FavoriteVideo.addedAt, order: .reverse) private var favorites: [FavoriteVideo]
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?

    var body: some View {
        let pins = FavoritePins.ordered(favorites)
        NavigationStack {
            List {
                Section {
                    if pins.isEmpty { Text("尚未置顶收藏").foregroundStyle(.secondary) }
                    ForEach(pins) { favorite in
                        row(favorite)
                    }
                    .onMove { offsets, destination in
                        var reordered = pins
                        reordered.move(fromOffsets: offsets, toOffset: destination)
                        do { try FavoritePins.reorder(reordered, context: context) }
                        catch { self.error = error.localizedDescription }
                    }
                } header: { Text("置顶") }
                footer: { Text("拖动右侧手柄调整顺序。取消置顶会保留收藏。") }
                let others = favorites.filter { !$0.isPinned }
                if !others.isEmpty {
                    Section("其他收藏") {
                        ForEach(others) { favorite in row(favorite) }
                    }
                }
            }
            .appSurface()
            .environment(\.editMode, .constant(.active))
            .navigationTitle("管理置顶")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .alert("置顶操作失败", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("好") { error = nil }
            } message: { Text(error ?? "") }
        }
    }

    private func row(_ favorite: FavoriteVideo) -> some View {
        HStack(spacing: 12) {
            FavoritePinRow(favorite: favorite)
            Button {
                do { try FavoritePins.set(favorite, pinned: !favorite.isPinned, context: context) }
                catch { self.error = error.localizedDescription }
            } label: { Image(systemName: favorite.isPinned ? "pin.slash" : "pin") }
                .buttonStyle(.borderless)
                .foregroundColor(.accentColor)
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityLabel((favorite.isPinned ? "取消置顶" : "置顶") + favorite.title)
        }
        .id("\(favorite.isPinned)-\(favorite.id)")
    }
}

struct FavoritePinRow: View {
    let favorite: FavoriteVideo
    var body: some View {
        HStack(spacing: 12) {
            CachedThumbnail(url: favorite.thumbnailURL, placeholder: favorite.contentIcon,
                            referer: favorite.pageURL, definitionID: favorite.definitionID)
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 4) {
                Text(favorite.title).font(.subheadline.weight(.medium)).lineLimit(2).foregroundStyle(.primary)
                Text(favorite.siteName.isEmpty ? favorite.contentLabel : favorite.siteName)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }
}
