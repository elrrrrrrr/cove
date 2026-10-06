import Foundation

/// Shared enum used by SettingsView, TXTReaderView, EPUBReaderView.
enum ReaderTheme: String, CaseIterable, Identifiable, Codable {
    case system, light, dark, sepia
    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: "跟随系统"
        case .light:  "浅色"
        case .dark:   "深色"
        case .sepia:  "护眼黄"
        }
    }
}
