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

enum NASViewMode { case list, grid }

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
    @State private var viewMode: NASViewMode = .list

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

    private var readPathSet: Set<String> {
        Set(readHistory.compactMap(\.filePath))
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
                        viewMode: $viewMode,
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
                        viewMode: $viewMode,
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

/// Reusable view for a single directory level. Supports NavigationLink for subdirectories.
struct NASDirectoryListView: View {
    let path: String
    let title: String
    let connection: NASConnection
    @Binding var viewMode: NASViewMode
    let isDownloading: Bool
    let readPathSet: Set<String>
    let onOpenDirectory: (String) -> Void
    let onOpen: (NASFileEntry, [NASFileEntry]) -> Void
    let onDownload: (NASFileEntry) -> Void
    let onDisconnect: () -> Void

    @State private var allEntries: [NASFileEntry] = []
    @State private var visibleLimit = 200
    @State private var isLoading = true
    @State private var error: String?

    private let initialVisibleCount = 200
    private let loadMoreCount = 200

    private var visibleEntries: ArraySlice<NASFileEntry> {
        allEntries.prefix(visibleLimit)
    }

    private var hasMoreEntries: Bool {
        visibleLimit < allEntries.count
    }

    var body: some View {
        Group {
            if isLoading {
                ProgressView("加载中…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error {
                ContentUnavailableView {
                    Label("加载失败", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("重试") { loadEntries() }
                }
            } else if allEntries.isEmpty {
                ContentUnavailableView("空文件夹", systemImage: "folder")
            } else {
                switch viewMode {
                case .list: listLayout
                case .grid: gridLayout
                }
            }
        }
        .appSurface()
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("断开") { onDisconnect() }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    viewMode = viewMode == .list ? .grid : .list
                } label: {
                    Image(systemName: viewMode == .list ? "square.grid.2x2" : "list.bullet")
                }
            }
        }
        .task { loadEntries() }
    }

    // MARK: - List layout

    private var listLayout: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(visibleEntries) { entry in
                    listRow(entry)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Divider()
                        .padding(.leading, 60)
                }
                if hasMoreEntries {
                    loadMoreFooter
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .appSurface()
    }

    // MARK: - Grid layout

    private var gridLayout: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 12)], spacing: 12) {
                ForEach(visibleEntries) { entry in
                    if entry.isDirectory {
                        Button {
                            onOpenDirectory(entry.path)
                        } label: {
                            fileGridCell(entry)
                        }
                        .buttonStyle(.plain)
                    } else {
                        fileGridCell(entry)
                            .onTapGesture {
                                if !isDownloading { onOpen(entry, allEntries) }
                            }
                    }
                }
                if hasMoreEntries {
                    loadMoreFooter
                        .gridCellColumns(2)
                }
            }
            .padding()
        }
    }

    private var loadMoreFooter: some View {
        HStack(spacing: 8) {
            ProgressView()
                .scaleEffect(0.75)
            Text("显示 \(min(visibleLimit, allEntries.count)) / \(allEntries.count)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .onAppear { loadMoreEntries() }
    }

    // MARK: - Row views

    @ViewBuilder
    private func listRow(_ entry: NASFileEntry) -> some View {
        if entry.isDirectory {
            Button {
                onOpenDirectory(entry.path)
            } label: {
                directoryRow(entry)
            }
            .contentShape(Rectangle())
            .buttonStyle(.plain)
        } else {
            fileRow(entry)
                .contentShape(Rectangle())
                .onTapGesture {
                    if !isDownloading { onOpen(entry, allEntries) }
                }
        }
    }

    private func directoryRow(_ entry: NASFileEntry) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "folder.fill")
                .font(.title3)
                .foregroundStyle(.blue)
                .frame(width: 32, height: 32)
            Text(entry.name).lineLimit(1)
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func fileRow(_ entry: NASFileEntry) -> some View {
        HStack(spacing: 12) {
            NASFileThumbnail(entry: entry, connection: connection, size: 32)
                .frame(width: 32, height: 32)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name).lineLimit(1)
                Text(entry.displaySize)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isRead(entry) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
            Button {
                onDownload(entry)
            } label: {
                Image(systemName: "arrow.down.circle")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
        .opacity(isDownloading ? 0.5 : 1)
    }

    private func fileGridCell(_ entry: NASFileEntry) -> some View {
        VStack(spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                if entry.isDirectory {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(.blue)
                        .frame(width: 80, height: 80)
                } else {
                    NASFileThumbnail(entry: entry, connection: connection, size: 80)
                        .frame(width: 80, height: 80)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                if isRead(entry) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.green)
                        .offset(x: 4, y: 4)
                }
            }
            Text(entry.name)
                .font(.caption)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .padding(8)
        .contentShape(Rectangle())
        .opacity(isDownloading ? 0.5 : 1)
    }

    // MARK: - Helpers

    private func isRead(_ entry: NASFileEntry) -> Bool {
        guard !entry.isDirectory else { return false }
        let ft = entry.fileType
        guard ft == .video || ft == .cbz || ft == .cbr else { return false }
        return readPathSet.contains(entry.path)
    }

    private func loadEntries() {
        isLoading = true
        error = nil
        let conn = connection
        let p = path
        Task {
            do {
                let items: [NASFileEntry]
                if p == "/" {
                    items = try await conn.listRoot()
                } else {
                    items = try await conn.listDirectory(path: p)
                }
                await MainActor.run {
                    allEntries = items
                    visibleLimit = min(initialVisibleCount, items.count)
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    self.error = error.localizedDescription
                    isLoading = false
                }
            }
        }
    }

    private func loadMoreEntries() {
        guard hasMoreEntries else { return }
        visibleLimit = min(visibleLimit + loadMoreCount, allEntries.count)
    }
}
