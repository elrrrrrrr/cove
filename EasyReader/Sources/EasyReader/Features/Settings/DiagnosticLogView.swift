import SwiftUI

struct DiagnosticLogView: View {
    @State private var logger = AppLogger.shared
    @State private var autoScroll = true
    @State private var filter = ""
    @State private var copied = false

    private var filteredEntries: [AppLogger.Entry] {
        if filter.isEmpty { return logger.entries }
        return logger.entries.filter { $0.message.localizedCaseInsensitiveContains(filter) }
    }

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    var body: some View {
        ScrollViewReader { proxy in
            List(filteredEntries) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.timeFmt.string(from: entry.timestamp))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(entry.message)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
                .id(entry.id)
            }
            .listStyle(.plain)
            .onChange(of: logger.entries.count) {
                if autoScroll, let last = filteredEntries.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
        .searchable(text: $filter, prompt: "过滤日志…")
        .navigationTitle("诊断日志")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        autoScroll.toggle()
                    } label: {
                        Label(autoScroll ? "自动滚动: 开" : "自动滚动: 关",
                              systemImage: autoScroll ? "checkmark" : "")
                    }
                    Divider()
                    Button {
                        copyAll()
                    } label: {
                        Label(copied ? "已复制" : "复制全部日志", systemImage: "doc.on.doc")
                    }
                    ShareLink(item: exportText()) {
                        Label("分享日志", systemImage: "square.and.arrow.up")
                    }
                    Divider()
                    Button(role: .destructive) {
                        logger.clear()
                    } label: {
                        Label("清除", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .overlay {
            if filteredEntries.isEmpty {
                ContentUnavailableView(
                    filter.isEmpty ? "暂无日志" : "无匹配",
                    systemImage: filter.isEmpty ? "text.alignleft" : "magnifyingglass",
                    description: Text(filter.isEmpty ? "连接 NAS 后会自动记录诊断信息" : "")
                )
            }
        }
    }

    private func exportText() -> String {
        let lines = logger.entries.map {
            "\(Self.timeFmt.string(from: $0.timestamp)) \($0.message)"
        }
        return lines.joined(separator: "\n")
    }

    private func copyAll() {
        UIPasteboard.general.string = exportText()
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }
}
