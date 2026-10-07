import SwiftUI
import SwiftData

struct HistoryView: View {
    @Query(sort: \ReadingHistory.lastReadAt, order: .reverse)
    private var allHistory: [ReadingHistory]

    @Environment(\.modelContext) private var context
    @State private var showClearConfirm = false

    private var grouped: [(String, [ReadingHistory])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: allHistory) { item -> String in
            if calendar.isDateInToday(item.lastReadAt) { return "今天" }
            if calendar.isDateInYesterday(item.lastReadAt) { return "昨天" }
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy年M月d日"
            return formatter.string(from: item.lastReadAt)
        }
        // Sort sections newest first using the first item's date in each group
        return grouped.sorted { a, b in
            let aDate = a.value.first?.lastReadAt ?? .distantPast
            let bDate = b.value.first?.lastReadAt ?? .distantPast
            return aDate > bDate
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if allHistory.isEmpty {
                    ContentUnavailableView("暂无历史记录", systemImage: "clock.arrow.circlepath")
                } else {
                    List {
                        ForEach(grouped, id: \.0) { section, items in
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
            .appSurface()
            .navigationTitle("历史记录")
            .toolbar {
                if !allHistory.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("清除全部", role: .destructive) {
                            showClearConfirm = true
                        }
                    }
                }
            }
            .confirmationDialog("确定要清除所有阅读记录吗？", isPresented: $showClearConfirm, titleVisibility: .visible) {
                Button("清除全部记录", role: .destructive) {
                    allHistory.forEach { context.delete($0) }
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
