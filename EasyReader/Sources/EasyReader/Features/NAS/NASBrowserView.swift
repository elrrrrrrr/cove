import SwiftUI
import SwiftData
import AVFoundation

// MARK: - SMB connection

enum NASConnection {
    case smb(SMBClient)
    var smbClient: SMBClient? { if case .smb(let client) = self { return client }; return nil }
    func listDirectory(path: String) async throws -> [NASFileEntry] {
        switch self { case .smb(let client): try await client.listDirectory(path: path) }
    }
    func listRoot() async throws -> [NASFileEntry] { try await listDirectory(path: "/") }
    func readFile(at path: String, progress: (@Sendable (Double) -> Void)? = nil) async throws -> Data {
        switch self { case .smb(let client): try await client.readFile(at: path, progress: progress) }
    }
    func disconnect() async { if case .smb(let client) = self { await client.disconnect() } }
}

// MARK: - NASBrowserView

/// Shows NAS file tree with native navigation (swipe-back) and file routing.
struct NASBrowserView: View {
    @Query private var nasConfigs: [NASConfig]
    @Query private var readHistory: [ReadingHistory]

    @Environment(\.modelContext) private var modelContext

    @State private var selectedConfig: NASConfig?
    @State private var nasPassword  = ""
    @State private var showConnect  = false
    @State private var connection: NASConnection?
    @State private var error: String?

    // Navigation stack for directory browsing (swipe-back support)
    @State private var navPath: [String] = []

    // File open routing
    @State private var openedFileURL: URL?
    @State private var openedHistory: ReadingHistory?
    @State private var openedFileType: FileType?
    @State private var openedFileData: Data?
    @State private var openedStreamItem: AVPlayerItem?
    @State private var openedStreamURL: URL?
    @State private var downloadProgress: (name: String, progress: Double, isVideo: Bool)?
    @State private var isDownloading = false

    // Sibling navigation
    @State private var openedSiblings: [NASFileEntry] = []
    @State private var openedIndex: Int = 0

    // Audio
    @State private var showAudioPlayer = false
    @State private var audioManager = AudioPlayerManager.shared

    // SMB connection progress
    @State private var isResolving = false

    private var isShowingReader: Bool {
        openedFileURL != nil || openedFileData != nil || openedStreamItem != nil || openedStreamURL != nil
    }

    @State private var readPathSet: Set<String> = []
    private func updateReadPaths() {
        let configID = selectedConfig?.id.uuidString
        readPathSet = Set(readHistory.filter { $0.nasConfigID == configID }.compactMap(\.filePath))
    }

    var body: some View {
        NavigationStack(path: $navPath) {
            Group {
                if nasConfigs.isEmpty {
                    nasEmptyState
                } else if let connection {
                    NASDirectoryListView(
                        path: "/",
                        title: selectedConfig?.name ?? "NAS",
                        connection: connection,
                        sourceID: selectedConfig?.id.uuidString ?? "nas",
                        isDownloading: isDownloading,
                        readPathSet: readPathSet,
                        onOpenDirectory: { dirPath in navPath.append(dirPath) },
                        onOpen: { entry, entries in openFile(entry, from: entries) },
                        onDownload: { entry in downloadToOffline(entry) },
                        onDisconnect: { disconnect() }
                    )
                } else {
                    configPickerView
                }
            }
            .appSurface()
            .navigationTitle("NAS")
            .navigationDestination(for: String.self) { dirPath in
                if let connection {
                    NASDirectoryListView(
                        path: dirPath,
                        title: (dirPath as NSString).lastPathComponent,
                        connection: connection,
                        sourceID: selectedConfig?.id.uuidString ?? "nas",
                        isDownloading: isDownloading,
                        readPathSet: readPathSet,
                        onOpenDirectory: { dirPath in navPath.append(dirPath) },
                        onOpen: { entry, entries in openFile(entry, from: entries) },
                        onDownload: { entry in downloadToOffline(entry) },
                        onDisconnect: { disconnect() }
                    )
                }
            }
        }
        .task { updateReadPaths() }
        .onChange(of: readHistory) { _, _ in updateReadPaths() }
        .onChange(of: selectedConfig?.id) { _, _ in updateReadPaths() }
        .overlay {
            if isResolving {
                VStack(spacing: 12) {
                    ProgressView()
                    Text(resolvingMessage)
                        .font(.caption)
                }
                .padding(24)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 16))
            }
            if isDownloading, let dl = downloadProgress {
                VStack(spacing: 12) {
                    ProgressView(value: dl.progress)
                        .progressViewStyle(.linear)
                        .frame(width: 200)
                    Text("加载中 \(dl.name)")
                        .font(.caption)
                        .lineLimit(1)
                    Text("\(Int(dl.progress * 100))%")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(24)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .shadow(radius: 10)
            }
        }
        .fullScreenCover(isPresented: Binding(
            get: { isShowingReader },
            set: { if !$0 { closeReader() } }
        )) {
            NavigationStack {
                readerDestination
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("完成") { closeReader() }
                        }
                    }
            }
        }
        .sheet(isPresented: $showConnect) { connectSheet }
        .sheet(isPresented: $showAudioPlayer) {
            NASAudioView(trackName: audioManager.trackName, trackPath: audioManager.trackPath)
        }
        .alert("错误", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("好") { error = nil }
        } message: {
            Text(error ?? "")
        }
        .safeAreaInset(edge: .bottom) {
            if connection != nil {
                MiniPlayerBar { showAudioPlayer = true }
            }
        }
    }

    // MARK: - Reader routing

    private func closeReader() {
        if let openedFileURL { try? FileManager.default.removeItem(at: openedFileURL.deletingLastPathComponent()) }
        openedFileURL = nil
        openedHistory = nil
        openedFileData = nil
        openedStreamItem = nil
        openedStreamURL = nil
    }

    @ViewBuilder
    private var readerDestination: some View {
        let ft = openedFileType ?? .unknown
        if let data = openedFileData {
            dataReaderView(data: data, fileType: ft)
        } else if openedStreamItem != nil && (ft == .video || ft == .audio) {
            NASVideoView(streamItem: openedStreamItem,
                         files: openedSiblings, initialIndex: openedIndex,
                         client: connection?.smbClient)
        } else if openedStreamURL != nil && (ft == .video || ft == .audio) {
            NASVideoView(streamURL: openedStreamURL,
                         files: openedSiblings, initialIndex: openedIndex)
        } else if let url = openedFileURL {
            readerView(for: url, fileType: ft)
        }
    }

    @ViewBuilder
    private func readerView(for url: URL, fileType: FileType) -> some View {
        switch fileType {
        case .txt:
            TXTReaderView(fileURL: url, historyItem: openedHistory)
        case .pdf:
            PDFReaderView(fileURL: url)
        case .cbz, .cbr:
            CBZReaderView(fileURL: url)
        case .epub:
            EPUBReaderView(fileURL: url)
        case .image:
            NASImageView(files: openedSiblings, initialIndex: openedIndex,
                         client: connection?.smbClient)
        case .video:
            NASVideoView(fileURL: url, files: openedSiblings, initialIndex: openedIndex,
                         client: connection?.smbClient)
        default:
            ContentUnavailableView("不支持的文件类型", systemImage: "doc.questionmark",
                                   description: Text(url.pathExtension.uppercased()))
        }
    }

    @ViewBuilder
    private func dataReaderView(data: Data, fileType: FileType) -> some View {
        switch fileType {
        case .image:
            NASImageView(files: openedSiblings, initialIndex: openedIndex,
                         client: connection?.smbClient, initialData: data)
        default:
            if let url = openedFileURL {
                readerView(for: url, fileType: fileType)
            }
        }
    }

    // MARK: - Sub-views

    private var nasEmptyState: some View {
        ContentUnavailableView {
            Label("未配置 NAS", systemImage: "externaldrive.badge.exclamationmark")
        } description: {
            Text("前往「设置」添加 NAS 连接")
        }
    }

    private var configPickerView: some View {
        ZStack {
            List(nasConfigs) { config in
                Button {
                    selectedConfig = config
                    if let saved = NASKeychain.load(for: config.id) {
                        nasPassword = saved
                        showConnect = false
                        connectToNAS(config: config)
                    } else {
                        showConnect = true
                    }
                } label: {
                    HStack {
                        Image(systemName: configIcon(config))
                            .font(.title2)
                            .foregroundStyle(.blue)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(config.name).font(.headline)
                            Text(configSubtitle(config))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private var connectSheet: some View {
        NavigationStack {
            Form {
                if let config = selectedConfig {
                    Section("连接到 \(config.name)") {
                        SecureField("密码", text: $nasPassword)
                    }
                    Toggle("记住密码", isOn: .constant(true))
                    Button("连接") {
                        showConnect = false
                        NASKeychain.save(password: nasPassword, for: config.id)
                        connectToNAS(config: config)
                    }
                }
            }
            .appSurface()
            .navigationTitle("NAS 登录")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { showConnect = false }
                }
            }
        }
    }

    // MARK: - Sibling helpers

    private func sameTypeGroup(_ a: FileType, _ b: FileType) -> Bool {
        switch a {
        case .image: return b == .image
        case .video: return b == .video
        case .audio: return b == .audio
        default: return false
        }
    }

    // MARK: - Config display helpers

    private func configIcon(_ config: NASConfig) -> String { "externaldrive.fill" }
    private func configSubtitle(_ config: NASConfig) -> String {
        config.requiresSMBSetup ? "需要重新配置 SMB" : "\(config.host):\(config.port) / \(config.shareName)"
    }
    private var resolvingMessage: String { "正在连接 SMB…" }
    private func connectToNAS(config: NASConfig) {
        guard !config.requiresSMBSetup else {
            error = "请编辑此连接，填写 SMB 主机、端口和共享名"
            return
        }
        connectSMB(config: config, password: nasPassword)
    }

    private func connectSMB(config: NASConfig, password: String) {
        let snap = NASConfigSnapshot(config: config)
        let smb = SMBClient(snapshot: snap)
        isResolving = true
        Task {
            do {
                try await smb.connect(password: password)
                await MainActor.run {
                    isResolving = false
                    connection = .smb(smb)
                }
            } catch {
                await MainActor.run {
                    isResolving = false
                    self.error = error.localizedDescription
                }
            }
        }
    }





    // MARK: - File open

    private func openFile(_ entry: NASFileEntry, from directoryEntries: [NASFileEntry]) {
        let ft = entry.fileType
        guard ft != .unknown else {
            self.error = "不支持的文件类型: \(entry.name)"
            return
        }

        guard let connection else { return }

        // Compute siblings for prev/next navigation
        let siblings = directoryEntries.filter { !$0.isDirectory && sameTypeGroup($0.fileType, ft) }
        let index = siblings.firstIndex(where: { $0.path == entry.path }) ?? 0
        openedSiblings = siblings
        openedIndex = index

        switch ft {
        case .video:
            openVideo(entry: entry, connection: connection, ft: ft)
        case .audio:
            openAudio(entry: entry, connection: connection, siblings: siblings, index: index, ft: ft)
        case .image:
            openImage(entry: entry, connection: connection, ft: ft)
        default:
            downloadAndOpen(entry: entry, connection: connection, ft: ft, isVideo: false)
        }
    }

    private func openVideo(entry: NASFileEntry, connection: NASConnection, ft: FileType) {
        if case .smb(let client) = connection {
            if SMBStreamLoader.supportsVideo(path: entry.path) {
                let item = SMBStreamLoader.makePlayerItem(client: client, remotePath: entry.path)
                openedFileType = ft
                openedStreamItem = item
                saveHistory(entry: entry, fileType: ft)
            } else {
                downloadAndOpen(entry: entry, connection: connection, ft: ft, isVideo: true)
            }
        }
    }

    private func openAudio(entry: NASFileEntry, connection: NASConnection,
                           siblings: [NASFileEntry], index: Int, ft: FileType) {
        let name = (entry.name as NSString).deletingPathExtension

        if case .smb(let client) = connection {
            let item = SMBStreamLoader.makePlayerItem(client: client, remotePath: entry.path)
            audioManager.play(item: item, name: name, path: entry.path,
                              siblings: siblings, currentIndex: index, client: client)
            showAudioPlayer = true
            saveHistory(entry: entry, fileType: ft)
        }
    }

    private func openImage(entry: NASFileEntry, connection: NASConnection, ft: FileType) {
        isDownloading = true
        downloadProgress = (entry.name, 0, false)
        Task {
            do {
                let data = try await connection.readFile(at: entry.path) { pct in
                    Task { @MainActor in
                        downloadProgress = (entry.name, pct, false)
                    }
                }
                await MainActor.run {
                    isDownloading = false
                    downloadProgress = nil
                    openedFileType = ft
                    openedFileData = data
                    saveHistory(entry: entry, fileType: ft)
                }
            } catch {
                await MainActor.run {
                    isDownloading = false
                    downloadProgress = nil
                    self.error = "加载失败: \(error.localizedDescription)"
                }
            }
        }
    }

    private func downloadAndOpen(entry: NASFileEntry, connection: NASConnection, ft: FileType, isVideo: Bool) {
        isDownloading = true
        downloadProgress = (entry.name, 0, isVideo)
        Task {
            do {
                guard let client = connection.smbClient else { throw SMBError.notConnected }
                let dest = try await client.temporaryFile(for: entry.path) { pct in
                    Task { @MainActor in
                        downloadProgress = (entry.name, pct, isVideo)
                    }
                }
                await MainActor.run {
                    isDownloading = false
                    downloadProgress = nil
                    openedFileType = ft
                    openedFileURL = dest
                    openedHistory = saveHistory(entry: entry, fileType: ft)
                }
            } catch {
                await MainActor.run {
                    isDownloading = false
                    downloadProgress = nil
                    self.error = "加载失败: \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - History (with dedup)

    @discardableResult private func saveHistory(entry: NASFileEntry, fileType: FileType) -> ReadingHistory {
        let configID = selectedConfig?.id.uuidString
        if let existing = readHistory.first(where: { $0.filePath == entry.path && $0.nasConfigID == configID }) {
            existing.lastReadAt = Date()
            existing.nasConfigID = selectedConfig?.id.uuidString
            return existing
        } else {
            let history = ReadingHistory(
                title: (entry.name as NSString).deletingPathExtension,
                filePath: entry.path,
                fileType: fileType
            )
            history.nasConfigID = selectedConfig?.id.uuidString
            modelContext.insert(history)
            return history
        }
    }

    private func disconnect() {
        guard let c = connection else { return }
        Task { await c.disconnect() }
        connection = nil
        navPath.removeAll()
    }

    private func downloadToOffline(_ entry: NASFileEntry) {
        guard let smbClient = connection?.smbClient else {
            self.error = "当前连接方式暂不支持离线下载"
            return
        }
        DownloadManager.shared.configureSMB(client: smbClient)
        DownloadManager.shared.add(
            title: entry.name,
            sourceURL: entry.path,
            fileType: entry.fileType,
            isNAS: true
        )
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }
}

// MARK: - NASDirectoryListView

struct NASDirectoryListView: View {
    let path: String
    let title: String
    let connection: NASConnection
    let isDownloading: Bool
    let readPathSet: Set<String>
    let onOpenDirectory: (String) -> Void
    let onOpen: (NASFileEntry, [NASFileEntry]) -> Void
    let onDownload: (NASFileEntry) -> Void
    let onDisconnect: () -> Void
    @AppStorage private var savedLayout: String
    @State private var allEntries: [NASFileEntry] = []
    @State private var visibleEntries: [NASFileEntry] = []
    @State private var isLoading = true
    @State private var error: String?

    init(path: String, title: String, connection: NASConnection, sourceID: String,
         isDownloading: Bool, readPathSet: Set<String>,
         onOpenDirectory: @escaping (String) -> Void,
         onOpen: @escaping (NASFileEntry, [NASFileEntry]) -> Void,
         onDownload: @escaping (NASFileEntry) -> Void, onDisconnect: @escaping () -> Void) {
        self.path = path; self.title = title; self.connection = connection
        self.isDownloading = isDownloading; self.readPathSet = readPathSet
        self.onOpenDirectory = onOpenDirectory; self.onOpen = onOpen
        self.onDownload = onDownload; self.onDisconnect = onDisconnect
        _savedLayout = AppStorage(wrappedValue: "", BrowserLayout.preferenceKey(source: "nas:" + sourceID, location: path))
    }
    private var layout: BrowserLayout { BrowserLayout(rawValue: savedLayout) ?? .list }
    private var layoutSelection: Binding<BrowserLayout> {
        Binding(get: { layout }, set: { savedLayout = $0.rawValue })
    }
    var body: some View {
        Group {
            if isLoading {
                ProgressView("加载中…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error {
                ContentUnavailableView {
                    Label("加载失败", systemImage: "exclamationmark.triangle")
                } description: { Text(error) } actions: { Button("重试") { loadEntries() } }
            } else if allEntries.isEmpty {
                ContentUnavailableView("空文件夹", systemImage: "folder")
            } else {
                NASDirectoryContent(entries: visibleEntries, layout: layout, connection: connection,
                    isDownloading: isDownloading, readPathSet: readPathSet, totalCount: allEntries.count,
                    onOpenDirectory: onOpenDirectory, onOpen: { onOpen($0, allEntries) },
                    onDownload: onDownload, onLoadMore: loadMoreEntries)
            }
        }
        .appSurface()
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { Button("断开", action: onDisconnect) }
            ToolbarItem(placement: .topBarTrailing) { BrowserLayoutMenu(layout: layoutSelection) }
        }
        .task { loadEntries() }
    }
    private func loadEntries() {
        isLoading = true; error = nil
        Task {
            do {
                let items = try await connection.listDirectory(path: path)
                allEntries = items; visibleEntries = Array(items.prefix(200)); isLoading = false
            } catch { self.error = error.localizedDescription; isLoading = false }
        }
    }
    private func loadMoreEntries() {
        let start = visibleEntries.count, end = min(start + 200, allEntries.count)
        guard end > start else { return }
        visibleEntries.append(contentsOf: allEntries[start..<end])
    }
}
