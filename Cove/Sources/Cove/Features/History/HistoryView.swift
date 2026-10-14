import SwiftUI
import SwiftData

struct HistoryView: View {
    @State private var index = ReadingIndex(includeGroups: true)

    @Environment(\.modelContext) private var context
    @State private var showClearConfirm = false

    var body: some View {
        NavigationStack {
            Group {
                if index.latest == nil {
                    ContentUnavailableView("暂无历史记录", systemImage: "clock.arrow.circlepath")
                } else {
                    List {
                        ForEach(index.groups, id: \.title) { section, items in
                            Section(section) {
                                ForEach(items) { item in
                                    HistoryRow(item: item)
                                        .swipeActions(edge: .trailing) {
                                            Button(role: .destructive) {
                                                context.delete(item)
                                            } label: {
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
            .background(ReadingIndexObserver(index: index).equatable())
            .appSurface()
            .navigationTitle("历史记录")
            .toolbar {
                if index.latest != nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("清除全部", role: .destructive) {
                            showClearConfirm = true
                        }
                    }
                }
            }
            .confirmationDialog("确定要清除所有阅读记录吗？", isPresented: $showClearConfirm, titleVisibility: .visible) {
                Button("清除全部记录", role: .destructive) {
                    try? context.delete(model: ReadingHistory.self)
                    try? context.save()
                }
            }
        }
    }
}

struct HistoryRow: View {
    let item: ReadingHistory

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.fileType.systemImage)
                .frame(width: 32, height: 32)
                .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
                .foregroundStyle(Color.accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .lineLimit(1)
                Text(item.lastReadAt.formatted(date: .omitted, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            ProgressView(value: item.progress)
                .frame(width: 48)
                .tint(.accentColor)
        }
        .padding(.vertical, 2)
    }
}
