import SwiftUI

struct ReaderFloatingBackButton: View {
    var tint: Color? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.left")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(tint ?? .primary)
                .padding(10)
                .background(.ultraThinMaterial, in: Circle())
        }
        .padding(.leading, 16)
        .padding(.top, 12)
    }
}

struct ReaderLoadingStateView: View {
    let message: String
    var filename: String? = nil
    var tint: Color? = nil
    let onBack: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let filename {
                Text(filename)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topLeading) {
            ReaderFloatingBackButton(tint: tint, action: onBack)
        }
    }
}

struct ReaderErrorView: View {
    let title: String
    let systemImage: String
    var message: String? = nil
    var onRetry: (() -> Void)? = nil
    let onBack: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            if let message { Text(message) }
        } actions: {
            if let onRetry {
                Button("重试", action: onRetry).buttonStyle(.borderedProminent)
            }
            Button("返回", action: onBack)
        }
    }
}

struct ReaderTopBar<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    var tint: Color? = nil
    let onBack: () -> Void
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onBack) {
                Image(systemName: "chevron.left").imageScale(.large)
            }
            if let subtitle {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline).lineLimit(1)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
            } else {
                Spacer()
                Text(title).font(.headline).lineLimit(1)
                Spacer()
            }
            trailing()
        }
        .foregroundStyle(tint ?? .primary)
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }
}

struct ReaderPageSliderBar: View {
    let current: Int
    let total: Int
    var oneBased: Bool = false
    let onSelect: (Int) -> Void

    private var minVal: Double { oneBased ? 1 : 0 }
    private var maxVal: Double { oneBased ? Double(max(total, 1)) : Double(max(total - 1, 0)) }

    var body: some View {
        VStack(spacing: 4) {
            if total > 1 {
                Slider(
                    value: Binding(
                        get: { min(max(Double(current), minVal), maxVal) },
                        set: { onSelect(Int($0)) }
                    ),
                    in: minVal...maxVal,
                    step: 1
                )
                .padding(.horizontal)
            }
        }
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }
}

struct LocalFileReaderView: View {
    let fileURL: URL
    let fileType: FileType
    var historyItem: ReadingHistory? = nil

    var body: some View {
        switch fileType {
        case .pdf:       PDFReaderView(fileURL: fileURL, historyItem: historyItem)
        case .cbz, .cbr: CBZReaderView(fileURL: fileURL, historyItem: historyItem)
        case .epub:      EPUBReaderView(fileURL: fileURL, historyItem: historyItem)
        case .txt:       TXTReaderView(fileURL: fileURL, historyItem: historyItem)
        case .video:     VideoPlayerView(fileURL: fileURL, historyItem: historyItem)
        default:
            ContentUnavailableView("不支持的文件类型", systemImage: "doc.questionmark",
                                   description: Text(fileURL.pathExtension.uppercased()))
        }
    }
}
