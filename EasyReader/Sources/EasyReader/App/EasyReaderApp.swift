import SwiftUI
import SwiftData
import os

@main
struct EasyReaderApp: App {

    let modelContainer: ModelContainer
    private let freshInstall: Bool

    init() {
        do {
            let storage = try LocalAppStorage.prepareModelStore()
            do { try OfflineFiles.shared.migrateLegacyDirectory() }
            catch { Logger(subsystem: "Cove", category: "Storage").error("离线目录迁移暂未完成：\(error.localizedDescription, privacy: .private)") }
            freshInstall = storage.freshInstall
            modelContainer = try ModelContainer(for:
                ReadingHistory.self,
                BookmarkSite.self,
                OfflineItem.self,
                NASConfig.self,
                FavoriteVideo.self,
                configurations: ModelConfiguration(url: storage.url)
            )
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .appAppearance()
                .task {
                    do { try await OfflineFiles.shared.normalizeRecords(in: modelContainer.mainContext) }
                    catch { Logger(subsystem: "Cove", category: "Storage").error("离线路径更新暂未完成：\(error.localizedDescription, privacy: .private)") }
                    SiteDefinitionStore.shared.initialize(context: modelContainer.mainContext, freshInstall: freshInstall)
                }
        }
        .modelContainer(modelContainer)
    }

}
