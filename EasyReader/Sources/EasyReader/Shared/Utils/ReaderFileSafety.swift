import Foundation

enum ReaderSafetyError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

enum ReaderContainedPath {
    static func resolve(_ relative: String, under root: URL, relativeTo base: URL? = nil) throws -> URL {
        guard !relative.isEmpty, !relative.hasPrefix("/"), !relative.hasPrefix("\\"),
              !relative.contains("\0"), !relative.contains("\\") else {
            throw ReaderSafetyError.message("资源路径不允许使用绝对地址")
        }
        let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        var destination = (base ?? root).standardizedFileURL.resolvingSymlinksInPath()
        func contained(_ url: URL) -> Bool {
            url.path == canonicalRoot.path || url.path.hasPrefix(canonicalRoot.path == "/" ? "/" : canonicalRoot.path + "/")
        }
        guard contained(destination) else { throw ReaderSafetyError.message("资源目录超出了允许范围") }
        // Resolving an entire nonexistent leaf does not reliably resolve an existing
        // symlink parent on every OS. Walk components and reject links before proceeding.
        for component in relative.split(separator: "/", omittingEmptySubsequences: true) {
            if component == "." { continue }
            if component == ".." { destination.deleteLastPathComponent() }
            else {
                destination.appendPathComponent(String(component))
                if (try? FileManager.default.attributesOfItem(atPath: destination.path)[.type]) as? FileAttributeType == .typeSymbolicLink {
                    throw ReaderSafetyError.message("资源路径不允许通过符号链接")
                }
            }
            guard contained(destination) else { throw ReaderSafetyError.message("资源路径超出了允许的目录") }
        }
        return destination
    }
}
