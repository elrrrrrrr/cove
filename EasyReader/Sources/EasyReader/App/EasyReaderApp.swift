import SwiftUI
import SwiftData

@main
struct EasyReaderApp: App {

    let modelContainer: ModelContainer
    private let freshInstall: Bool

    init() {
        do {
            let storage = try LocalAppStorage.prepareModelStore()
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
                    SiteDefinitionStore.shared.initialize(context: modelContainer.mainContext, freshInstall: freshInstall)
                }
        }
        .modelContainer(modelContainer)
    }

}
