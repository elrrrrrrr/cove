import SwiftUI
import SwiftData
import AVKit

/// Auto-connects to a NAS and opens a file from history.
/// Used when tapping NAS history items from HomeView.
struct NASAutoConnectView: View {
    let historyItem: ReadingHistory

    @Query private var nasConfigs: [NASConfig]
    @Environment(\.dismiss) private var dismiss

    @State private var state: LoadState = .connecting
    @State private var connection: NASConnection?
    @State private var fileURL: URL?
    @State private var streamItem: AVPlayerItem?
    @State private var imageData: Data?
    @State private var loadTask: Task<Void, Never>?

    enum LoadState {
        case connecting
        case downloading(Double)
        case ready
        case failed(String)
    }

    private var config: NASConfig? {
        guard let configID = historyItem.nasConfigID else { return nil }
        return nasConfigs.first { $0.id.uuidString == configID }
    }

    var body: some View {
        Group {
            switch state {
            case .connecting:
                VStack(spacing: 16) {
                    ProgressView()
                    Text("正在连接 NAS…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            case .downloading(let progress):
                VStack(spacing: 16) {
                    ProgressView(value: progress)
                        .frame(width: 200)
                    Text("正在加载文件…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("\(Int(progress * 100))%")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            case .ready:
                readyView
            case .failed(let msg):
                ContentUnavailableView {
                    Label("连接失败", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(msg)
                } actions: {
                    Button("重试") { connectAndLoad() }
                    Button("返回") { dismiss() }
                }
            }
        }
        .navigationTitle(historyItem.title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { connectAndLoad() }
        .onDisappear {
            loadTask?.cancel()
            if let fileURL { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        }
    }

    @ViewBuilder
    private var readyView: some View {
        let ft = historyItem.fileType
        if let streamItem {
            NASVideoView(streamItem: streamItem)
        } else if ft == .audio {
            NASAudioView(trackName: historyItem.title, trackPath: historyItem.filePath ?? "")
        } else if let imageData {
            NASImageView(initialData: imageData)
        } else if let url = fileURL {
            switch ft {
            case .txt: TXTReaderView(fileURL: url)
            case .pdf: PDFReaderView(fileURL: url)
            case .cbz, .cbr: CBZReaderView(fileURL: url)
            case .epub: EPUBReaderView(fileURL: url)
            case .video: NASVideoView(fileURL: url)
            default: Text("不支持的格式")
            }
        }
    }

    private func connectAndLoad() {
        guard let config else {
            state = .failed("找不到 NAS 配置")
            return
        }
        guard let password = NASKeychain.load(for: config.id) else {
            state = .failed("未保存密码，请重新在 NAS 设置中连接")
            return
        }
        guard let filePath = historyItem.filePath else {
            state = .failed("文件路径为空")
            return
        }

        loadTask?.cancel()
        streamItem = nil
        imageData = nil
        state = .connecting

        guard !config.requiresSMBSetup else {
            state = .failed("此连接需要重新填写 SMB 主机和共享名")
            return
        }
        connectSMBAndLoad(config: config, password: password, filePath: filePath)
    }

    private func connectSMBAndLoad(config: NASConfig, password: String, filePath: String) {
        let snap = NASConfigSnapshot(config: config)
        let client = SMBClient(snapshot: snap)
        loadTask = Task {
            do {
                try await client.connect(password: password)
                try Task.checkCancellation()
                let conn = NASConnection.smb(client)
                connection = conn
                await loadFile(connection: conn, filePath: filePath)
            } catch {
                guard !Task.isCancelled else { return }
                state = .failed(error.localizedDescription)
            }
        }
    }


    private func loadFile(connection: NASConnection, filePath: String) async {
        do {
            guard let client = connection.smbClient else { throw SMBError.notConnected }
            switch historyItem.fileType {
            case .video where SMBStreamLoader.supportsVideo(path: filePath):
                streamItem = SMBStreamLoader.makePlayerItem(client: client, remotePath: filePath)
            case .audio:
                let item = SMBStreamLoader.makePlayerItem(client: client, remotePath: filePath)
                AudioPlayerManager.shared.play(item: item, name: historyItem.title, path: filePath, client: client)
            case .image:
                imageData = try await client.readFile(at: filePath)
            default:
                state = .downloading(0)
                let url = try await client.temporaryFile(for: filePath) { pct in
                    Task { @MainActor in
                        guard case .downloading = state else { return }
                        state = .downloading(pct)
                    }
                }
                guard !Task.isCancelled else {
                    try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
                    return
                }
                fileURL = url
            }
            try Task.checkCancellation()
            state = .ready
        } catch {
            guard !Task.isCancelled else { return }
            state = .failed("加载失败: \(error.localizedDescription)")
        }
    }
}
