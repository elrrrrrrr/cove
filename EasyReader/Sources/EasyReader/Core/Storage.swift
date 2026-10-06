import Foundation
import Security

enum CoveStorage {
    static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cove2", isDirectory: true)
    }
    static var config: URL { root.appendingPathComponent("config", isDirectory: true) }
    static var data: URL { root.appendingPathComponent("data", isDirectory: true) }
    static var cache: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cove2", isDirectory: true)
    }
    static func prepare() throws {
        for url in [root, config, data, cache] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }
    static func write<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }
}

enum CredentialVault {
    private static let service = "dev.cove.resource.credentials.v2"
    static func load(id: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: id,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func save(_ password: String, id: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: id
        ]
        let data = Data(password.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(insert as CFDictionary, nil) == errSecSuccess else {
                throw CoveError.message("保存连接密码失败")
            }
        } else if status != errSecSuccess {
            throw CoveError.message("更新连接密码失败")
        }
    }
    static func remove(id: String) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                      kSecAttrService as String: service, kSecAttrAccount as String: id] as CFDictionary)
    }
}

/// Components and symlinks are resolved before containment is checked.
/// String prefix checks without a trailing separator accept sibling directories.
enum ContainedPath {
    static func resolve(_ relative: String, under root: URL, relativeTo base: URL? = nil) throws -> URL {
        guard !relative.isEmpty, !relative.hasPrefix("/"), !relative.hasPrefix("\\"),
              !relative.contains("\0"), !relative.contains("\\") else {
            throw CoveError.message("资源路径不允许使用绝对地址")
        }
        let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        var destination = (base ?? root).standardizedFileURL.resolvingSymlinksInPath()
        func contained(_ url: URL) -> Bool {
            url.path == canonicalRoot.path || url.path.hasPrefix(canonicalRoot.path == "/" ? "/" : canonicalRoot.path + "/")
        }
        guard contained(destination) else { throw CoveError.message("资源目录超出了允许范围") }
        // Resolving an entire nonexistent leaf does not reliably resolve an existing
        // symlink parent on every OS. Walk components and reject links before proceeding.
        for component in relative.split(separator: "/", omittingEmptySubsequences: true) {
            if component == "." { continue }
            if component == ".." { destination.deleteLastPathComponent() }
            else {
                destination.appendPathComponent(String(component))
                if (try? FileManager.default.attributesOfItem(atPath: destination.path)[.type]) as? FileAttributeType == .typeSymbolicLink {
                    throw CoveError.message("资源路径不允许通过符号链接")
                }
            }
            guard contained(destination) else { throw CoveError.message("资源路径超出了允许的目录") }
        }
        return destination
    }
}
