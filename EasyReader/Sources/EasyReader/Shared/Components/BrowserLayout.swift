import SwiftUI
import CryptoKit

enum BrowserLayout: String, CaseIterable, Identifiable, Sendable {
    case list, bento, portrait
    var id: String { rawValue }
    var label: String {
        switch self {
        case .list: "列表"
        case .bento: "Bento"
        case .portrait: "竖版"
        }
    }
    var icon: String {
        switch self {
        case .list: "list.bullet"
        case .bento: "rectangle.grid.1x2"
        case .portrait: "rectangle.grid.3x2"
        }
    }
    static let preferencePrefix = "browserLayout."
    static func preferenceKey(source: String, location: String) -> String {
        let context = [source, location].map { "\($0.utf8.count):\($0)" }.joined()
        return preferencePrefix + SHA256.hash(data: Data(context.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

struct BrowserLayoutMenu: View {
    @Binding var layout: BrowserLayout
    var body: some View {
        Menu {
            Picker("布局", selection: $layout) {
                ForEach(BrowserLayout.allCases) { option in
                    Label(option.label, systemImage: option.icon).tag(option)
                }
            }
        } label: { Image(systemName: layout.icon) }
        .accessibilityLabel("切换布局")
        .accessibilityValue(layout.label)
        .accessibilityIdentifier("browser-layout-menu")
    }
}
