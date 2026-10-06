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
    @State private var error: String?

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
    }

    @ViewBuilder
    private var readyView: some View {
        let ft = historyItem.fileType
        if let url = fileURL {
            switch ft {
            case .txt: TXTReaderView(fileURL: url)
            case .pdf: PDFReaderView(fileURL: url)
            case .cbz, .cbr: CBZReaderView(fileURL: url)
            case .epub: EPUBReaderView(fileURL: url)
            case .video: NASVideoView(fileURL: url)
            case .audio:
                NASAudioView(trackName: historyItem.title, trackPath: historyItem.filePath ?? "")
                    .onAppear { AudioPlayerManager.shared.play(url: url, name: historyItem.title, path: historyItem.filePath ?? "") }
            case .image: NASImageView(initialData: try? Data(contentsOf: url))
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
        Task {
            do {
                try await client.connect(password: password)
                let conn = NASConnection.smb(client)
                await MainActor.run { connection = conn }
                await loadFile(connection: conn, filePath: filePath)
            } catch {
                await MainActor.run { state = .failed(error.localizedDescription) }
            }
        }
    }





    private func loadFile(connection: NASConnection, filePath: String) async {
        // Read through SMB into a local file: download to temp file
        do {
            await MainActor.run { state = .downloading(0) }
            let data = try await connection.readFile(at: filePath) { pct in
                Task { @MainActor in state = .downloading(pct) }
            }
            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("NASOpen", isDirectory: true)
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            let filename = (filePath as NSString).lastPathComponent
            let dest = tempDir.appendingPathComponent(filename)
            try data.write(to: dest)
            await MainActor.run {
                fileURL = dest
                state = .ready
            }
        } catch {
            await MainActor.run { state = .failed("加载失败: \(error.localizedDescription)") }
        }
    }
}
