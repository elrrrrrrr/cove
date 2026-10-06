import SwiftUI

enum EpisodeSelection {
    static func item(_ item: ResourceItem, number: Int, config: EpisodeModule) throws -> ResourceItem {
        guard number > 0, number <= (item.episodeCount ?? 0) else { throw CoveError.message("集数无效") }
        let path = config.url.replacingOccurrences(of: "{url}", with: item.locator).replacingOccurrences(of: "{episode}", with: "\(number)")
        guard let url = URL(string: path, relativeTo: URL(string: item.locator))?.absoluteURL,
              ["http", "https"].contains(url.scheme ?? "") else { throw CoveError.message("选集地址无效") }
        return ResourceItem(sourceID: item.sourceID, title: item.title + " · 第 \(number) 集",
                            locator: url.absoluteString, kind: .video,
                            identity: item.identity.map { $0 + ":episode:\(number)" },
                            thumbnail: item.thumbnail, subtitle: "第 \(number) 集", tags: item.tags)
    }
}

struct EpisodePicker: View {
    let item: ResourceItem
    let config: EpisodeModule
    var onSelect: (ResourceItem) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?
    var body: some View {
        NavigationStack {
            List(1...max(1, min(10_000, item.episodeCount ?? 1)), id: \.self) { number in
                Button("第 \(number) 集") {
                    do { let selected = try EpisodeSelection.item(item, number: number, config: config); dismiss(); onSelect(selected) }
                    catch { self.error = error.localizedDescription }
                }
            }
            .navigationTitle("选择集数").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
            .alert("无法选集", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("好") { error = nil } } message: { Text(error ?? "") }
        }
    }
}
