import XCTest
import SwiftData
@testable import EasyReader

@MainActor final class FavoritePinsTests: XCTestCase {
    private func container(url: URL? = nil) throws -> ModelContainer {
        let configuration = url.map { ModelConfiguration(url: $0) } ?? ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: FavoriteVideo.self, configurations: configuration)
    }

    private func favorite(_ name: String, comic: Bool = false) -> FavoriteVideo {
        FavoriteVideo(title: name, pageURLString: "https://media.example/\(name)", isComic: comic)
    }

    func testPinsAndManualOrderSurviveReopeningWithoutChangingIdentityOrDates() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Cove.store")
        var identities: [String: UUID] = [:]
        var dates: [UUID: Date] = [:]
        do {
            let store = try container(url: url), context = store.mainContext
            let video = favorite("video"), comic = favorite("comic", comic: true), other = favorite("other")
            for (index, item) in [video, comic, other].enumerated() {
                item.addedAt = Date(timeIntervalSince1970: Double(index + 1))
                identities[item.title] = item.id; dates[item.id] = item.addedAt
                context.insert(item)
            }
            try context.save()
            try FavoritePins.set(video, pinned: true, context: context)
            try FavoritePins.set(comic, pinned: true, context: context)
            try FavoritePins.reorder([comic, video], context: context)
        }
        let store = try container(url: url), context = store.mainContext
        let items = try context.fetch(FetchDescriptor<FavoriteVideo>())
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(FavoritePins.ordered(items).map(\.id), [identities["comic"]!, identities["video"]!])
        for item in items { XCTAssertEqual(item.id, identities[item.title]); XCTAssertEqual(item.addedAt, dates[item.id]) }
        let comic = try XCTUnwrap(items.first { $0.isComic })
        try FavoritePins.set(comic, pinned: false, context: context)
        let reread = try ModelContext(store).fetch(FetchDescriptor<FavoriteVideo>())
        XCTAssertEqual(reread.count, 3, "Unpin must keep the favorite")
        XCTAssertEqual(FavoritePins.ordered(reread).map(\.id), [identities["video"]!])
    }

    func testFilteredOrDuplicateOrderCannotDamageGlobalPinsAndRepinningAppends() throws {
        let store = try container(), context = store.mainContext
        let items = (0..<3).map { favorite("item\($0)") }
        for item in items { context.insert(item) }
        try context.save()
        for item in items { try FavoritePins.set(item, pinned: true, context: context) }
        try FavoritePins.reorder([items[2], items[0], items[1]], context: context)
        XCTAssertThrowsError(try FavoritePins.reorder([items[0], items[1]], context: context))
        XCTAssertThrowsError(try FavoritePins.reorder([items[2], items[0], items[0]], context: context))
        XCTAssertEqual(FavoritePins.ordered(items).map(\.id), [items[2], items[0], items[1]].map(\.id))
        try FavoritePins.set(items[0], pinned: false, context: context)
        try FavoritePins.set(items[0], pinned: true, context: context)
        try FavoritePins.set(items[2], pinned: true, context: context)
        XCTAssertEqual(FavoritePins.ordered(items).map(\.id), [items[2], items[1], items[0]].map(\.id))
    }

    func testExportImportPreservesPinsWhileMergeKeepsLocalChoicesAndAppendsNewPins() throws {
        let source = try container(), context = source.mainContext
        let a = favorite("a"), b = favorite("b", comic: true)
        context.insert(a); context.insert(b); try context.save()
        try FavoritePins.set(a, pinned: true, context: context)
        try FavoritePins.set(b, pinned: true, context: context)
        try FavoritePins.reorder([b, a], context: context)
        let file = try FavoriteDataFile.decode(FavoriteDataFile.export([a, b]).json())
        XCTAssertEqual(file.schemaVersion, 1)
        let target = try container(), restored = target.mainContext
        try file.apply(to: restored); try restored.save()
        var values = try restored.fetch(FetchDescriptor<FavoriteVideo>())
        XCTAssertEqual(FavoritePins.ordered(values).map(\.id), [b.id, a.id])
        XCTAssertTrue(values.first { $0.id == b.id }?.isComic == true)
        try FavoritePins.set(try XCTUnwrap(values.first { $0.id == b.id }), pinned: false, context: restored)
        let incoming = try FavoriteDataFile.decode(Data(#"{"schemaVersion":1,"favorites":[{"title":"c","pageURL":"https://media.example/c","isPinned":true,"pinOrder":0}]}"#.utf8))
        try file.apply(to: restored); try incoming.apply(to: restored); try restored.save()
        values = try restored.fetch(FetchDescriptor<FavoriteVideo>())
        XCTAssertEqual(values.count, 3)
        XCTAssertEqual(FavoritePins.ordered(values).map(\.title), ["a", "c"])
        XCTAssertFalse(try XCTUnwrap(values.first { $0.id == b.id }).isPinned, "Merge must preserve local unpin decisions")
    }

    func testOldRecordsDefaultToUnpinnedAndInvalidPinMetadataIsRejectedBeforeMutation() throws {
        let store = try container(), context = store.mainContext
        let file = try FavoriteDataFile.decode(Data(#"{"schemaVersion":1,"favorites":[{"title":"old","pageURL":"https://media.example/old"}]}"#.utf8))
        try file.apply(to: context); try context.save()
        let old = try XCTUnwrap(context.fetch(FetchDescriptor<FavoriteVideo>()).first)
        XCTAssertFalse(old.isPinned)
        XCTAssertThrowsError(try FavoriteDataFile.decode(Data(#"{"schemaVersion":1,"favorites":[{"title":"bad","pageURL":"https://media.example/bad","isPinned":true,"pinOrder":-1}]}"#.utf8)))
        var collision = file
        collision.favorites[0].id = old.id; collision.favorites[0].pageURL = "https://media.example/another"
        XCTAssertThrowsError(try collision.apply(to: context))
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<FavoriteVideo>()), 1)
        XCTAssertEqual(old.title, "old")
        var new = file.favorites[0]
        new.id = UUID(); new.title = "new"; new.pageURL = "https://media.example/new"
        var ignored = new; ignored.id = old.id
        var duplicates = file; duplicates.favorites = [new, ignored]
        try duplicates.apply(to: context); try context.save()
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<FavoriteVideo>()), 2, "Duplicate URLs remain a merge, even when the ignored record carries an existing ID")
        XCTAssertEqual(old.title, "old")
    }

    func testExistingStoreMigratesWithFavoriteRecordsIntact() throws {
        let fixture = try XCTUnwrap(Bundle(for: Self.self).resourceURL).appendingPathComponent("LocalSiteTests/favorite-migration")
        guard FileManager.default.fileExists(atPath: fixture.appendingPathComponent("expected.json").path) else {
            throw XCTSkip("未提供私有资料库升级样本")
        }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .secondsSince1970
        let expected = try decoder.decode(FavoriteDataFile.self, from: Data(contentsOf: ReaderContainedPath.resolve("expected.json", under: fixture)))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for suffix in ["", "-wal", "-shm"] {
            let path = "Cove.store" + suffix
            if FileManager.default.fileExists(atPath: fixture.appendingPathComponent(path).path) {
                try FileManager.default.copyItem(at: ReaderContainedPath.resolve(path, under: fixture), to: directory.appendingPathComponent(path))
            }
        }
        let store = try ModelContainer(for: ReadingHistory.self, BookmarkSite.self, OfflineItem.self, NASConfig.self, FavoriteVideo.self,
                                       configurations: ModelConfiguration(url: directory.appendingPathComponent("Cove.store")))
        let items = try store.mainContext.fetch(FetchDescriptor<FavoriteVideo>())
        XCTAssertEqual(Set(items.map(\.id)), Set(expected.favorites.compactMap(\.id)))
        XCTAssertTrue(items.allSatisfy { !$0.isPinned && $0.pinOrder == 0 })
        let records = FavoriteDataFile.export(items).favorites
        for old in expected.favorites {
            let current = try XCTUnwrap(records.first { $0.id == old.id })
            XCTAssertEqual(current.title, old.title); XCTAssertEqual(current.pageURL, old.pageURL)
            XCTAssertEqual(current.thumbnail, old.thumbnail); XCTAssertEqual(current.duration, old.duration)
            XCTAssertEqual(current.siteName, old.siteName); XCTAssertEqual(current.isComic, old.isComic)
            XCTAssertEqual(current.definitionID, old.definitionID)
            XCTAssertEqual(try XCTUnwrap(current.addedAt).timeIntervalSince1970, try XCTUnwrap(old.addedAt).timeIntervalSince1970, accuracy: 0.001)
        }
        let item = try XCTUnwrap(items.first)
        try FavoritePins.set(item, pinned: true, context: store.mainContext)
        XCTAssertEqual(try store.mainContext.fetchCount(FetchDescriptor<FavoriteVideo>()), expected.favorites.count)
        XCTAssertEqual(FavoritePins.ordered(items).map(\.id), [item.id])
    }
}
