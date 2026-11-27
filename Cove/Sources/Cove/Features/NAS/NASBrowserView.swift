import SwiftUI
import SwiftData
import AVFoundation

// MARK: - NASBrowserView

/// Shows NAS file tree with native navigation (swipe-back) and file routing.
struct NASBrowserView: View {
    @Query private var nasConfigs: [NASConfig]
    @Query private var readHistory: [ReadingHistory]

    @Environment(\.modelContext) private var modelContext

    @State private var selectedConfig: NASConfig?
    @State private var nasPassword  = ""
    @State private var showConnect  = false
    @State private var connection: SMBClient?
    @State private var error: String?

    // Navigation stack for directory browsing (swipe-back support)
    @State private var navPath: [String] = []

    // File open routing
    @State private var openedFileURL: URL?
    @State private var openedHistory: ReadingHistory?
    @State private var openedFileType: FileType?
    @State private var openedFileData: Data?
    @State private var openedStreamItem: AVPlayerItem?
    @State private var downloadProgress: (name: String, progress: Double)?
    @State private var isDownloading = false

    // Sibling navigation
    @State private var openedSiblings: [NASFileEntry] = []
    @State private var openedIndex: Int = 0

    // Audio
    @State private var showAudioPlayer = false
    @State private var audioManager = AudioPlayerManager.shared

    // SMB connection & transfer tasks
    @State private var isResolving = false
    @State private var connectTask: Task<Void, Never>?
    @State private var openTask: Task<Void, Never>?

    private var isShowingReader: Bool {
        openedFileURL != nil || openedFileData != nil || openedStreamItem != nil
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
        .onDisappear {
            connectTask?.cancel(); connectTask = nil
            openTask?.cancel(); openTask = nil
        }
        .overlay {
            if isResolving {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("正在连接 SMB…")
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
    }

    @ViewBuilder
    private var readerDestination: some View {
        let ft = openedFileType ?? .unknown
        if let data = openedFileData {
            NASImageView(files: openedSiblings, initialIndex: openedIndex,
                         client: connection, initialData: data)
        } else if openedStreamItem != nil && ft == .video {
            NASVideoView(streamItem: openedStreamItem,
                         files: openedSiblings, initialIndex: openedIndex,
                         client: connection)
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
            PDFReaderView(fileURL: url, historyItem: openedHistory)
        case .cbz, .cbr:
            CBZReaderView(fileURL: url, historyItem: openedHistory)
        case .epub:
            EPUBReaderView(fileURL: url, historyItem: openedHistory)
        case .video:
            NASVideoView(fileURL: url, files: openedSiblings, initialIndex: openedIndex,
                         client: connection)
        default:
            ContentUnavailableView("不支持的文件类型", systemImage: "doc.questionmark",
                                   description: Text(url.pathExtension.uppercased()))
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
        List(nasConfigs) { config in
            Button {
                selectedConfig = config
                if let saved = NASKeychain.load(for: config.id) {
                    nasPassword = saved
                    showConnect = false
                    connectToNAS(config: config)
                } else {
                    nasPassword = ""
                    showConnect = true
                }
            } label: {
                HStack {
                    Image(systemName: "externaldrive.fill")
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

    private var connectSheet: some View {
        NavigationStack {
            Form {
                if let config = selectedConfig {
                    Section("连接到 \(config.name)") {
                        SecureField("密码", text: $nasPassword)
                    }
                    Button("连接") {
                        showConnect = false
                        if nasPassword.isEmpty { NASKeychain.delete(for: config.id) }
                        else { NASKeychain.save(password: nasPassword, for: config.id) }
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

    private func configSubtitle(_ config: NASConfig) -> String {
        config.requiresSMBSetup ? "需要重新配置 SMB" : "\(config.host):\(config.port) / \(config.shareName)"
    }
    private func connectToNAS(config: NASConfig) {
        guard !config.requiresSMBSetup else {
            error = "请编辑此连接，填写 SMB 主机、端口和共享名"
            return
        }
        connectSMB(config: config, password: nasPassword)
    }

    private func connectSMB(config: NASConfig, password: String) {
        connectTask?.cancel()
        let snap = NASConfigSnapshot(config: config)
        let smb = SMBClient(snapshot: snap)
        isResolving = true
        connectTask = Task {
            do {
                try await smb.connect(password: password)
                guard !Task.isCancelled else { await smb.disconnect(); return }
                isResolving = false
                connection = smb
                connectTask = nil
            } catch {
                guard !Task.isCancelled else { return }
                isResolving = false
                connectTask = nil
                self.error = error.localizedDescription
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
            openVideo(entry: entry, client: connection, ft: ft)
        case .audio:
            openAudio(entry: entry, client: connection, siblings: siblings, index: index, ft: ft)
        case .image:
            openImage(entry: entry, client: connection, ft: ft)
        default:
            downloadAndOpen(entry: entry, client: connection, ft: ft)
        }
    }

    private func openVideo(entry: NASFileEntry, client: SMBClient, ft: FileType) {
        if SMBStreamLoader.supportsVideo(path: entry.path) {
            let item = SMBStreamLoader.makePlayerItem(client: client, remotePath: entry.path)
            openedFileType = ft
            openedStreamItem = item
            saveHistory(entry: entry, fileType: ft)
        } else {
            downloadAndOpen(entry: entry, client: client, ft: ft)
        }
    }

    private func openAudio(entry: NASFileEntry, client: SMBClient,
                           siblings: [NASFileEntry], index: Int, ft: FileType) {
        let name = (entry.name as NSString).deletingPathExtension
        let item = SMBStreamLoader.makePlayerItem(client: client, remotePath: entry.path)
        audioManager.play(item: item, name: name, path: entry.path,
                          siblings: siblings, currentIndex: index, client: client)
        showAudioPlayer = true
        saveHistory(entry: entry, fileType: ft)
    }

    private func openImage(entry: NASFileEntry, client: SMBClient, ft: FileType) {
        openTask?.cancel()
        isDownloading = true
        downloadProgress = (entry.name, 0)
        openTask = Task {
            do {
                let data = try await client.readFile(at: entry.path) { pct in
                    Task { @MainActor in
                        guard isDownloading else { return }
                        downloadProgress = (entry.name, pct)
                    }
                }
                guard !Task.isCancelled, connection === client else { return }
                isDownloading = false
                downloadProgress = nil
                openedFileType = ft
                openedFileData = data
                saveHistory(entry: entry, fileType: ft)
                openTask = nil
            } catch {
                guard !Task.isCancelled else { return }
                isDownloading = false
                downloadProgress = nil
                openTask = nil
                self.error = "加载失败: \(error.localizedDescription)"
            }
        }
    }

    private func downloadAndOpen(entry: NASFileEntry, client: SMBClient, ft: FileType) {
        openTask?.cancel()
        isDownloading = true
        downloadProgress = (entry.name, 0)
        openTask = Task {
            do {
                let dest = try await client.temporaryFile(for: entry.path) { pct in
                    Task { @MainActor in
                        guard isDownloading else { return }
                        downloadProgress = (entry.name, pct)
                    }
                }
                guard !Task.isCancelled, connection === client else {
                    try? FileManager.default.removeItem(at: dest.deletingLastPathComponent())
                    return
                }
                isDownloading = false
                downloadProgress = nil
                openedFileType = ft
                openedFileURL = dest
                openedHistory = saveHistory(entry: entry, fileType: ft)
                openTask = nil
            } catch {
                guard !Task.isCancelled else { return }
                isDownloading = false
                downloadProgress = nil
                openTask = nil
                self.error = "加载失败: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - History (with dedup)

    @discardableResult private func saveHistory(entry: NASFileEntry, fileType: FileType) -> ReadingHistory {
        let configID = selectedConfig?.id.uuidString
        if let existing = readHistory.first(where: { $0.filePath == entry.path && $0.nasConfigID == configID }) {
            existing.lastReadAt = Date()
            existing.nasConfigID = configID
            try? modelContext.save()
            return existing
        } else {
            let history = ReadingHistory(
                title: (entry.name as NSString).deletingPathExtension,
                filePath: entry.path,
                fileType: fileType
            )
            history.nasConfigID = configID
            modelContext.insert(history)
            try? modelContext.save()
            return history
        }
    }

    private func disconnect() {
        connectTask?.cancel(); connectTask = nil
        openTask?.cancel(); openTask = nil
        isDownloading = false
        downloadProgress = nil
        isResolving = false
        nasPassword = ""
        guard let c = connection else { return }
        AudioPlayerManager.shared.stopIfUsing(client: c)
        Task { await c.disconnect() }
        connection = nil
        navPath.removeAll()
    }

    private func downloadToOffline(_ entry: NASFileEntry) {
        guard let smbClient = connection else { return }
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
    let connection: SMBClient
    let isDownloading: Bool
    let readPathSet: Set<String>
    let onOpenDirectory: (String) -> Void
    let onOpen: (NASFileEntry, [NASFileEntry]) -> Void
    let onDownload: (NASFileEntry) -> Void
    let onDisconnect: () -> Void
    @AppStorage private var savedLayout: String
    @State private var allEntries: [NASFileEntry] = []
    @State private var loadID = UUID()
    @State private var refreshTask: Task<Void, Never>?
    @State private var visibleEntries: [NASFileEntry] = []
    @State private var isLoading = true
    @State private var error: String?

    init(path: String, title: String, connection: SMBClient, sourceID: String,
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
                } description: { Text(error) } actions: {
                    Button("重试") {
                        refreshTask?.cancel()
                        refreshTask = Task { await loadEntries(refresh: true) }
                    }
                }
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
            ToolbarItem(placement: .topBarTrailing) {
                HStack {
                    Button("刷新", systemImage: "arrow.clockwise") {
                        refreshTask?.cancel()
                        refreshTask = Task { await loadEntries(refresh: true) }
                    }
                    BrowserLayoutMenu(layout: layoutSelection)
                }
            }
        }
        .task { await loadEntries() }
        .refreshable { await loadEntries(refresh: true) }
        .onDisappear { refreshTask?.cancel() }
    }
    private func loadEntries(refresh: Bool = false) async {
        let id = UUID(); loadID = id
        if allEntries.isEmpty { isLoading = true }
        error = nil
        do {
            let items = try await connection.listDirectory(path: path, refresh: refresh)
            guard !Task.isCancelled, loadID == id else { return }
            let sameSnapshot = allEntries.count == items.count && allEntries.first?.id == items.first?.id
            let count = sameSnapshot ? max(visibleEntries.count, min(200, items.count)) : min(200, items.count)
            allEntries = items; visibleEntries = Array(items.prefix(count)); isLoading = false
        } catch {
            guard !Task.isCancelled, loadID == id else { return }
            self.error = error.localizedDescription; isLoading = false
        }
    }
    private func loadMoreEntries() {
        let start = visibleEntries.count, end = min(start + 200, allEntries.count)
        guard end > start else { return }
        visibleEntries.append(contentsOf: allEntries[start..<end])
    }
}
