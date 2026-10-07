import Foundation
import SwiftData

enum LocalAppStorage {
    static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cove", isDirectory: true)
    }
    static var config: URL { root.appendingPathComponent("config", isDirectory: true) }
    static var data: URL { root.appendingPathComponent("data", isDirectory: true) }

    /// Copy the existing database and its journal before opening the new location.
    /// The old files remain available if opening/migration fails.
    static func prepareModelStore() throws -> (url: URL, freshInstall: Bool) {
        let fm = FileManager.default
        let legacy = ModelConfiguration().url
        let destination = data.appendingPathComponent("Cove.store")
        let existed = fm.fileExists(atPath: destination.path) || fm.fileExists(atPath: legacy.path)
        try fm.createDirectory(at: data, withIntermediateDirectories: true)
        try fm.createDirectory(at: config, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: destination.path), fm.fileExists(atPath: legacy.path) {
            // The main file is committed last, so an interrupted copy can be retried safely.
            for suffix in ["-wal", "-shm", ""] {
                let source = URL(fileURLWithPath: legacy.path + suffix)
                let target = URL(fileURLWithPath: destination.path + suffix)
                if fm.fileExists(atPath: source.path) {
                    if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
                    try fm.copyItem(at: source, to: target)
                }
            }
        }
        return (destination, !existed)
    }
}
