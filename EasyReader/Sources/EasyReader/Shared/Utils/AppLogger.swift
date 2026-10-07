import Foundation

/// In-memory log collector for NAS connection diagnostics.
/// Logs are viewable in Settings → 诊断日志.
/// Controlled by the "diagnosticLogEnabled" UserDefaults key (default: off).
@Observable @MainActor
final class AppLogger {
    static let shared = AppLogger()

    struct Entry: Identifiable, Sendable {
        let id = UUID()
        let timestamp: Date
        let message: String
    }

    private(set) var entries: [Entry] = []
    private let maxEntries = 500

    /// Whether diagnostic logging is active. Toggled in Settings → 诊断.
    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "diagnosticLogEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "diagnosticLogEnabled") }
    }

    private init() {}

    func log(_ message: String) {
        guard isEnabled else { return }
        let entry = Entry(timestamp: Date(), message: message)
        entries.append(entry)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
        #if DEBUG
        print(message)
        #endif
    }

    func clear() {
        entries.removeAll()
    }

    /// Nonisolated entry point for calling from actors / background tasks.
    nonisolated static func log(_ message: String) {
        Task { @MainActor in
            shared.log(message)
        }
    }
}
