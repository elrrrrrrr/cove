import SwiftUI

/// Prepared directory entries; opening and downloading remain with the source.
struct NASDirectoryContent: View {
    let entries: [NASFileEntry]
    let layout: BrowserLayout
    let connection: NASConnection?
    let isDownloading: Bool
    let readPathSet: Set<String>
    let totalCount: Int
    let onOpenDirectory: (String) -> Void
    let onOpen: (NASFileEntry) -> Void
    let onDownload: (NASFileEntry) -> Void
    let onLoadMore: () -> Void
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var visibleEntryID: UUID?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                switch layout {
                case .list:
                    LazyVStack(spacing: 0) {
                        ForEach(entries) { entry in
                            listRow(entry)
                            Divider().padding(.leading, 60)
                        }
                        footer
                    }
                    .scrollTargetLayout()
                case .bento:
                    BentoGrid(items: entries, columns: sizeClass == .regular ? 3 : 2) { entry, cardSize in
                        entryButton(entry) { bentoCard(entry, size: cardSize) }
                    } footer: { footer }
                case .portrait:
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: sizeClass == .regular ? 4 : 3), spacing: 12) {
                        ForEach(entries) { entry in
                            entryButton(entry) { portraitCard(entry) }
                        }
                    }
                    .scrollTargetLayout()
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    footer
                }
            }
            .scrollPosition(id: $visibleEntryID, anchor: .top)
            .onChange(of: layout) { _, _ in
                if let visibleEntryID { proxy.scrollTo(visibleEntryID, anchor: .top) }
            }
        }
        .accessibilityIdentifier("nas-directory-content")
    }

    func open(_ entry: NASFileEntry) {
        if entry.isDirectory { onOpenDirectory(entry.path) }
        else if !isDownloading { onOpen(entry) }
    }
    @ViewBuilder private func entryButton<Content: View>(_ entry: NASFileEntry, @ViewBuilder label: () -> Content) -> some View {
        Button { open(entry) } label: { label() }
            .buttonStyle(.plain)
            .disabled(isDownloading && !entry.isDirectory)
            .contextMenu {
                if !entry.isDirectory { Button("下载到本地", systemImage: "arrow.down.circle") { onDownload(entry) } }
            }
    }
    private func listRow(_ entry: NASFileEntry) -> some View {
        HStack(spacing: 12) {
            Button { open(entry) } label: {
                HStack(spacing: 12) {
                    NASFileThumbnail(entry: entry, connection: connection, size: 32)
                        .frame(width: 32, height: 32).clipShape(RoundedRectangle(cornerRadius: 6))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.name).lineLimit(2).foregroundStyle(.primary)
                        if !entry.isDirectory { Text(entry.displaySize).font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer(minLength: 8)
                    readBadge(entry)
                }
                .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).disabled(isDownloading && !entry.isDirectory)
            if entry.isDirectory {
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            } else {
                Button { onDownload(entry) } label: {
                    Image(systemName: "arrow.down.circle").foregroundStyle(.secondary)
                }.buttonStyle(.plain).accessibilityLabel("下载 \(entry.name)")
            }
        }
        .padding(.horizontal, 16)
    }
    private func bentoCard(_ entry: NASFileEntry, size: BentoCardSize) -> some View {
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 0) {
                NASFileThumbnail(entry: entry, connection: connection, size: min(geometry.size.width, geometry.size.height))
                    .frame(width: geometry.size.width, height: max(geometry.size.height - 50, 1))
                    .clipped().clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(alignment: .topTrailing) { readBadge(entry).padding(6) }
                metadata(entry, titleFont: .system(size: size == .large ? 15 : 13, weight: .medium))
                    .frame(height: 50, alignment: .topLeading)
            }
        }
    }
    private func portraitCard(_ entry: NASFileEntry) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            NASFileThumbnail(entry: entry, connection: connection, size: 80)
                .aspectRatio(2.0 / 3, contentMode: .fit)
                .clipped().clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(alignment: .topTrailing) { readBadge(entry).padding(6) }
            metadata(entry, titleFont: .system(size: 13, weight: .medium))
        }
    }
    private func metadata(_ entry: NASFileEntry, titleFont: Font) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(entry.name).font(titleFont).lineLimit(2).foregroundStyle(.primary)
            Text(entry.isDirectory ? "文件夹" : entry.displaySize).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.horizontal, 3).padding(.vertical, 5)
    }
    @ViewBuilder private func readBadge(_ entry: NASFileEntry) -> some View {
        if !entry.isDirectory, readPathSet.contains(entry.path) {
            Image(systemName: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
                .accessibilityLabel("已阅读")
        }
    }
    @ViewBuilder private var footer: some View {
        if entries.count < totalCount {
            HStack(spacing: 8) {
                ProgressView().scaleEffect(0.75)
                Text("显示 \(entries.count) / \(totalCount)").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 12).onAppear(perform: onLoadMore)
        }
    }
}
