import SwiftUI

/// One appearance preference shared by the app and its readers.
enum AppTheme: String, CaseIterable, Identifiable, Codable {
    static let storageKey = "readerTheme"
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

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .dark: .dark
        case .light, .sepia: .light
        }
    }
    var backgroundColor: Color {
        switch self {
        case .sepia: Color(red: 0.98, green: 0.95, blue: 0.87)
        case .dark: .black
        case .light: .white
        case .system: Color(.systemBackground)
        }
    }
    var textColor: Color {
        switch self {
        case .sepia: Color(red: 0.30, green: 0.22, blue: 0.12)
        case .dark: Color(white: 0.85)
        case .light: .black
        case .system: Color(.label)
        }
    }
}

enum NovelReadingMode: String, CaseIterable, Identifiable {
    static let storageKey = "novelReadingMode"
    case paged, scroll
    var id: String { rawValue }
    var label: String { self == .paged ? "左右翻页" : "上下滚动" }
}

struct AppAppearance: ViewModifier {
    @AppStorage(AppTheme.storageKey) private var theme: AppTheme = .system
    func body(content: Content) -> some View {
        content
            .preferredColorScheme(theme.colorScheme)
            .scrollContentBackground(theme == .sepia ? .hidden : .automatic)
            .background(theme.backgroundColor.ignoresSafeArea())
    }
}

extension View {
    func appAppearance() -> some View { modifier(AppAppearance()) }
    func appSurface() -> some View { modifier(AppSurface()) }
}

private struct AppSurface: ViewModifier {
    @AppStorage(AppTheme.storageKey) private var theme: AppTheme = .system
    func body(content: Content) -> some View {
        content
            .scrollContentBackground(theme == .sepia ? .hidden : .automatic)
            .background(theme == .sepia ? theme.backgroundColor : .clear)
    }
}
