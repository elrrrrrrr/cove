import SwiftUI
import SwiftData

struct NASSettingsView: View {
    var config: NASConfig?
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var host = ""
    @State private var port = "445"
    @State private var username = ""
    @State private var password = ""
    @State private var shareName = ""
    @State private var testing = false
    @State private var testResult: String?
    @State private var loadingShares = false
    @State private var availableShares: [(name: String, comment: String)] = []
    @State private var error: String?

    private var validPort: Int? { Int(port).flatMap { (1...65535).contains($0) ? $0 : nil } }
    private var canSave: Bool { !name.trimmed.isEmpty && !normalizedSMBHost.isEmpty && !shareName.trimmed.isEmpty && validPort != nil }
    private var normalizedSMBHost: String {
        var value = host.trimmed
        if value.lowercased().hasPrefix("smb://") { value = String(value.dropFirst(6)) }
        if let slash = value.firstIndex(of: "/") { value = String(value[..<slash]) }
        if value.filter({ $0 == ":" }).count == 1, let colon = value.lastIndex(of: ":") { value = String(value[..<colon]) }
        return value
    }

    var body: some View {
        NavigationStack {
            Form {
                if config?.requiresSMBSetup == true {
                    Section { Text("请填写 SMB 主机、端口和共享名，保存后继续使用此连接。") }
                }
                Section("SMB 连接") {
                    TextField("名称", text: $name)
                    TextField("IP 地址或主机名", text: $host)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("端口（默认 445）", text: $port).keyboardType(.numberPad)
                }
                Section("认证") {
                    TextField("用户名", text: $username).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("密码", text: $password)
                }
                Section("共享设置") {
                    HStack {
                        TextField("共享名", text: $shareName).textInputAutocapitalization(.never).autocorrectionDisabled()
                        Button { discoverShares() } label: {
                            if loadingShares { ProgressView() } else { Image(systemName: "arrow.triangle.2.circlepath") }
                        }.disabled(normalizedSMBHost.isEmpty || loadingShares)
                    }
                    ForEach(availableShares, id: \.name) { share in
                        Button { shareName = share.name } label: {
                            HStack {
                                Image(systemName: shareName == share.name ? "checkmark.circle.fill" : "circle")
                                VStack(alignment: .leading) {
                                    Text(share.name)
                                    if !share.comment.isEmpty { Text(share.comment).font(.caption).foregroundStyle(.secondary) }
                                }
                            }
                        }
                    }
                }
                Section {
                    Button { testConnection() } label: {
                        if testing { ProgressView() } else { Text("测试连接") }
                    }.disabled(!canSave || testing)
                    if let testResult { Label(testResult, systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                    if let error { Text(error).foregroundStyle(.red) }
                }
                if let config {
                    Section {
                        Button("删除此 NAS", role: .destructive) {
                            context.delete(config)
                            dismiss()
                        }
                    }
                }
            }
            .appSurface()
            .navigationTitle(config == nil ? "添加 NAS" : "编辑 NAS")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { save() }.disabled(!canSave) }
            }
            .onAppear {
                guard let config else { return }
                name = config.name; host = config.host; port = config.port > 0 ? String(config.port) : "445"
                username = config.username; shareName = config.shareName
                password = NASKeychain.load(for: config.id) ?? ""
            }
        }
    }

    private func save() {
        guard let validPort else { return }
        let value = config ?? NASConfig(name: name.trimmed, host: normalizedSMBHost, port: validPort,
                                       username: username.trimmed, shareName: shareName.trimmed)
        value.name = name.trimmed; value.host = normalizedSMBHost; value.port = validPort
        value.username = username.trimmed; value.shareName = shareName.trimmed
        if config == nil { context.insert(value) }
        if !password.isEmpty { NASKeychain.save(password: password, for: value.id) }
        do { try context.save(); dismiss() } catch { self.error = error.localizedDescription }
    }

    private func discoverShares() {
        loadingShares = true; error = nil; availableShares = []
        let h = normalizedSMBHost, u = username.trimmed, p = password
        Task {
            defer { loadingShares = false }
            do {
                availableShares = try await SMBClient.listShares(host: h, username: u, password: p).filter { !$0.name.hasSuffix("$") }
                if availableShares.isEmpty { error = "未发现可用共享" }
            } catch { self.error = error.localizedDescription }
        }
    }

    private func testConnection() {
        guard let validPort else { return }
        testing = true; error = nil; testResult = nil
        let value = NASConfig(name: name.trimmed, host: normalizedSMBHost, port: validPort,
                              username: username.trimmed, shareName: shareName.trimmed)
        let client = SMBClient(snapshot: NASConfigSnapshot(config: value))
        let p = password
        Task {
            defer { testing = false }
            do {
                try await client.connect(password: p)
                _ = try await client.listDirectory()
                await client.disconnect()
                testResult = "连接成功"
            } catch {
                await client.disconnect()
                self.error = error.localizedDescription
            }
        }
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
