import SwiftUI
import SwiftData

enum ViewerTarget: Hashable, Identifiable {
    case webItem(ParsedItem, kind: ItemKind, definitionID: String?, siteName: String)
    case history(ReadingHistory)
    case offline(OfflineItem)
    case nasFile(NASFileEntry, siblings: [NASFileEntry], index: Int, clientID: String, configID: String?)
    case webURL(URL)

    var id: String {
        switch self {
        case .webItem(let item, _, _, _): "web:\(item.pageURL.absoluteString)"
        case .history(let h): "hist:\(h.id.uuidString)"
        case .offline(let o): "off:\(o.id.uuidString)"
        case .nasFile(let e, _, _, let cid, _): "nas:\(cid):\(e.path)"
        case .webURL(let u): "url:\(u.absoluteString)"
        }
    }
}

struct ResourceRouter: View {
    let target: ViewerTarget

    var body: some View {
        switch target {
        case .webItem(let item, let kind, let defID, let siteName):
            switch kind {
            case .video: MediaPlayerView(source: .web(item: item, definitionID: defID))
            case .comic: ImageGalleryView(source: .webComic(item: item, definitionID: defID))
            case .article: DocumentReaderView(source: .article(item: item, definitionID: defID, siteName: siteName, history: nil))
            case .navLink: FeedView(name: item.title, urlString: item.pageURL.absoluteString, definitionID: defID)
            }

        case .history(let item):
            if let nasID = item.nasConfigID, let path = item.filePath {
                NASHistoryOpener(history: item, configID: nasID, remotePath: path)
            } else {
                historyLocalView(item)
            }

        case .offline(let item):
            if item.localPath.isEmpty, let urlStr = item.sourceURL, let url = URL(string: urlStr) {
                WebBrowserView(url: url)
            } else if let fileURL = OfflineFiles.shared.url(for: item.localPath) {
                localFileView(fileURL: fileURL, type: item.fileType, title: item.title, history: nil)
            } else {
                ContentUnavailableView("离线文件路径无效", systemImage: "doc.badge.ellipsis")
            }

        case .nasFile(let entry, let siblings, let index, let clientID, _):
            switch entry.fileType {
            case .video:
                MediaPlayerView(source: .nasVideo(entries: siblings, initialIndex: index, clientID: clientID))
            case .audio:
                MediaPlayerView(source: .nasAudio(entries: siblings, initialIndex: index, clientID: clientID))
            case .image:
                ImageGalleryView(source: .nasImages(entries: siblings, initialIndex: index, clientID: clientID))
            default:
                NASTempFileOpener(entry: entry, clientID: clientID)
            }

        case .webURL(let url):
            WebBrowserView(url: url)
        }
    }

    @ViewBuilder
    private func historyLocalView(_ item: ReadingHistory) -> some View {
        if let path = item.filePath, let fileURL = OfflineFiles.shared.historyURL(for: path) {
            localFileView(fileURL: fileURL, type: item.fileType, title: item.displayTitle, history: item)
        } else if let str = item.url, let url = URL(string: str) {
            let parsed = ParsedItem(title: item.title, pageURL: url, thumbnail: item.thumbnailURL, duration: "", extra: "")
            switch item.fileType {
            case .video: MediaPlayerView(source: .web(item: parsed, definitionID: item.definitionID))
            case .comic: ImageGalleryView(source: .webComic(item: parsed, definitionID: item.definitionID))
            case .article: DocumentReaderView(source: .article(item: parsed, definitionID: item.definitionID, siteName: "", history: item))
            case .audio: MediaPlayerView(source: .localAudio(url: url, title: item.displayTitle))
            default: WebBrowserView(url: url)
            }
        } else {
            ContentUnavailableView("无法打开记录", systemImage: "doc.questionmark")
        }
    }

    @ViewBuilder
    private func localFileView(fileURL: URL, type: FileType, title: String, history: ReadingHistory?) -> some View {
        switch type {
        case .video: MediaPlayerView(source: .localVideo(url: fileURL, history: history))
        case .audio: MediaPlayerView(source: .localAudio(url: fileURL, title: title))
        case .cbz, .cbr: ImageGalleryView(source: .localCBZ(url: fileURL, history: history))
        case .txt: DocumentReaderView(source: .txt(url: fileURL, history: history))
        case .pdf: DocumentReaderView(source: .pdf(url: fileURL, history: history))
        case .epub: DocumentReaderView(source: .epub(url: fileURL, history: history))
        default: ContentUnavailableView("不支持的文件格式", systemImage: "doc.questionmark")
        }
    }
}

// MARK: - NAS Helper Openers

private struct NASTempFileOpener: View {
    let entry: NASFileEntry
    let clientID: String
    @State private var localURL: URL?
    @State private var error: String?

    var body: some View {
        Group {
            if let localURL {
                switch entry.fileType {
                case .cbz, .cbr: ImageGalleryView(source: .localCBZ(url: localURL, history: nil))
                case .txt: DocumentReaderView(source: .txt(url: localURL, history: nil))
                case .pdf: DocumentReaderView(source: .pdf(url: localURL, history: nil))
                case .epub: DocumentReaderView(source: .epub(url: localURL, history: nil))
                default: ContentUnavailableView("不支持的文件类型", systemImage: "doc.questionmark")
                }
            } else if let error {
                ContentUnavailableView("加载失败", systemImage: "exclamationmark.triangle", description: Text(error))
            } else {
                ProgressView("正在从 NAS 下载…")
            }
        }
        .task {
            guard localURL == nil else { return }
            do {
                guard let client = await SMBClientRegistry.shared.client(for: clientID) else { throw SMBError.notConnected }
                localURL = try await client.temporaryFile(for: entry.path)
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
        .onDisappear {
            if let localURL { try? FileManager.default.removeItem(at: localURL.deletingLastPathComponent()) }
        }
    }
}

private struct NASHistoryOpener: View {
    let history: ReadingHistory
    let configID: String
    let remotePath: String
    @Query private var configs: [NASConfig]
    @State private var clientID: String?
    @State private var entry: NASFileEntry?
    @State private var error: String?

    var body: some View {
        Group {
            if let entry, let clientID {
                ResourceRouter(target: .nasFile(entry, siblings: [entry], index: 0, clientID: clientID, configID: configID))
            } else if let error {
                ContentUnavailableView("无法连接 NAS", systemImage: "externaldrive.badge.xmark", description: Text(error))
            } else {
                ProgressView("连接 NAS…")
            }
        }
        .task {
            guard entry == nil else { return }
            guard let uuid = UUID(uuidString: configID),
                  let cfg = configs.first(where: { $0.id == uuid }),
                  let pwd = NASKeychain.load(for: uuid) else {
                error = "请先在 NAS 标签页连接服务器"; return
            }
            let client = SMBClient(snapshot: NASConfigSnapshot(config: cfg))
            do {
                try await client.connect(password: pwd)
                clientID = client.cacheIdentity
                entry = NASFileEntry(name: (remotePath as NSString).lastPathComponent, path: remotePath, isDirectory: false, size: 0, modifiedAt: nil)
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }
}
