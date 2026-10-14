import XCTest
import SwiftData
import CryptoKit
@testable import Cove

@MainActor final class FolderSyncTests: XCTestCase {
    private func backup() -> ConfigBackup {
        ConfigBackup(exportDate: Date(timeIntervalSince1970: 100),
            settings: SettingsBackup(readerFontSize: 17, readerTheme: AppTheme.system.rawValue, contentBlockerEnabled: true),
            sites: [], nasConfigs: [], siteDefinitions: [], favorites: [], histories: [], offlineItems: [], preferences: [:])
    }
    private func record(_ id: UUID, title: String = "测试") -> FavoriteDataFile.FavoriteRecord {
        .init(id: id, title: title, pageURL: "https://library.example/\(id)", addedAt: Date(timeIntervalSince1970: 10), isPinned: true, pinOrder: 0)
    }
    private func merge(_ local: ConfigBackup, _ remote: ConfigBackup, _ base: ConfigBackup?) throws -> (ConfigBackup, Bool) {
        let result = try FolderSyncMerge.merge(local: local.json(), remote: remote.json(), baseline: base?.json())
        return (try ConfigBackup.decode(result.data), result.hasConflicts)
    }
    func testFirstConnectionUnionsIdentifiersAndRestoresCloudSettings() throws {
        var local = backup(), remote = backup()
        let a = UUID(), b = UUID()
        local.favorites = [record(a)]; remote.favorites = [record(b)]
        remote.settings.readerFontSize = 23
        let result = try merge(local, remote, nil)
        XCTAssertEqual(Set(result.0.favorites!.compactMap(\.id)), Set([a, b]))
        XCTAssertEqual(result.0.settings.readerFontSize, 23)
        XCTAssertTrue(result.1)
    }
    func testThreeWayDeletionDoesNotResurrectAndIndependentEditsMerge() throws {
        var base = backup(); let a = UUID(), b = UUID()
        base.favorites = [record(a), record(b)]
        var local = base, remote = base
        local.favorites!.removeFirst(); local.favorites![0].isPinned = false
        remote.favorites![1].title = "远端标题"
        let result = try merge(local, remote, base)
        XCTAssertEqual(result.0.favorites!.compactMap(\.id), [b])
        XCTAssertEqual(result.0.favorites![0].title, "远端标题")
        XCTAssertEqual(result.0.favorites![0].isPinned, false)
        XCTAssertFalse(result.1)
    }
    func testConcurrentFieldConflictKeepsLocalAndReportsConflict() throws {
        var base = backup(); base.favorites = [record(UUID())]
        var local = base, remote = base
        local.favorites![0].title = "本地"; remote.favorites![0].title = "云端"
        let result = try merge(local, remote, base)
        XCTAssertEqual(result.0.favorites![0].title, "本地"); XCTAssertTrue(result.1)
    }
    func testModificationDuringTransferSurvivesReconciliation() throws {
        let initial = backup(); var current = initial, published = initial
        current.settings.readerFontSize = 20
        published.favorites = [record(UUID())]
        let result = try merge(current, published, initial)
        XCTAssertEqual(result.0.settings.readerFontSize, 20)
        XCTAssertEqual(result.0.favorites?.count, 1)
    }
    func testExistingSchemaOneDecodesWithoutAdditionalRecords() throws {
        var value = backup(); value.favorites = nil; value.histories = nil; value.offlineItems = nil; value.preferences = nil
        let data = try value.json(), decoded = try ConfigBackup.decode(data)
        XCTAssertEqual(decoded.schemaVersion, 1); XCTAssertNil(decoded.histories)
        XCTAssertTrue(try FolderSyncMerge.equivalent(data, decoded.json()))
        var bad = value; bad.schemaVersion = 2
        XCTAssertThrowsError(try ConfigBackup.decode(bad.json()))
    }
    func testNegativeScrollCaptureDoesNotRejectValidRecordsAndVideoSecondsRoundTrip() throws {
        let container = try ModelContainer(for: BookmarkSite.self, NASConfig.self, ReadingHistory.self, FavoriteVideo.self, OfflineItem.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let page = ReadingHistory(title: "滚动回弹", url: "https://library.example/page", progress: -0.0005226)
        let video = ReadingHistory(title: "视频", url: "https://library.example/video", progress: 123.5)
        context.insert(page); context.insert(video); try context.save()
        let value = try ConfigBackup.captureAll(context: context)
        let decoded = try ConfigBackup.decode(value.json())
        XCTAssertEqual(decoded.histories?.first { $0.id == page.id }?.progress, 0)
        XCTAssertEqual(decoded.histories?.first { $0.id == video.id }?.progress, 123.5)
        XCTAssertEqual(page.progress, -0.0005226, "Export must not rewrite source records")
        XCTAssertEqual(decoded.histories?.count, 2)
        var invalid = value
        invalid.histories![0].progress = -1
        XCTAssertThrowsError(try invalid.validate(), "Portable data still rejects negative progress")
        invalid = value; invalid.histories![0].fileType = .txt; invalid.histories![0].progress = 3
        XCTAssertThrowsError(try invalid.validate(), "Reading fractions must remain bounded")
    }
    func testMetadataOnlySavedWebpagesDoNotRequireDownloadedFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var value = backup()
        value.offlineItems = (0..<2).map { index in
            OfflineBackup(id: UUID(), title: "网页", sourceURL: "https://library.example/page/\(index)", localPath: "", fileType: .web, savedAt: Date(), fileSizeBytes: 0)
        }
        let result = try await FolderSyncFiles().synchronize(local: value.json(), baseline: nil, folder: root, dataRoot: root, recovery: root.appendingPathComponent("R"))
        XCTAssertEqual(try ConfigBackup.decode(result.data).offlineItems?.count, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Files").path))
    }
    func testRejectsDuplicateIdentifiersTraversalAndDeviceSecrets() throws {
        var value = backup(); let record = record(UUID())
        value.favorites = [record, record]; XCTAssertThrowsError(try value.validate())
        value.favorites = []; value.preferences = ["folderSync.bookmark": "secret"]
        XCTAssertThrowsError(try value.validate())
        value.preferences = [:]
        value.offlineItems = [.init(id: UUID(), title: "bad", localPath: "Offline/../../escape", fileType: .txt, savedAt: Date(), fileSizeBytes: 0)]
        XCTAssertThrowsError(try value.validate())
        value.offlineItems = []; value.histories = [.init(id: UUID(), title: "external", filePath: "/private/external.txt", fileType: .txt, progress: 0, lastReadAt: Date())]
        XCTAssertThrowsError(try value.validate())
    }
    func testApplyPreservesIdentityAndOptionalRecordsWhenImportingConfigurationOnly() throws {
        let container = try ModelContainer(for: BookmarkSite.self, NASConfig.self, ReadingHistory.self, FavoriteVideo.self, OfflineItem.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let existing = FavoriteVideo(title: "旧标题", pageURLString: "https://library.example/old")
        context.insert(existing); try context.save()
        var value = backup(); value.favorites = [record(existing.id, title: "新标题")]
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = SiteDefinitionStore(storageURL: folder.appendingPathComponent("sites.json"))
        try value.applySynchronized(to: context, store: store)
        XCTAssertTrue(try context.fetch(FetchDescriptor<FavoriteVideo>()).first === existing)
        XCTAssertEqual(existing.title, "新标题")
        value.favorites = nil
        let historyID = UUID()
        value.histories = [.init(id: historyID, title: "本地阅读", filePath: "Offline/synced/book.txt", fileType: .txt, progress: 0.4, lastReadAt: Date())]
        try value.applySynchronized(to: context, store: store)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<FavoriteVideo>()), 1)
        let history = try XCTUnwrap(context.fetch(FetchDescriptor<ReadingHistory>()).first)
        XCTAssertEqual(history.id, historyID)
        XCTAssertEqual(history.filePath, LocalAppStorage.data.appendingPathComponent("Offline/synced/book.txt").path)
        XCTAssertEqual(history.progress, 0.4)
    }
    func testFullSnapshotRoundTripKeepsComicChapterNASIdentityAndOmitsExternalAuthorization() throws {
        let container = try ModelContainer(for: BookmarkSite.self, NASConfig.self, ReadingHistory.self, FavoriteVideo.self, OfflineItem.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let nas = NASConfig(name: "测试 NAS", host: "smb://nas.example", username: "reader", shareName: "Books")
        let comic = ReadingHistory(title: "漫画", url: "https://library.example/comic", filePath: "chapter-17", fileType: .comic, progress: 0.5)
        let external = ReadingHistory(title: "外部文件", filePath: "/private/device-only.pdf", fileType: .pdf)
        let site = BookmarkSite(name: "站点", urlString: "https://library.example")
        let favorite = FavoriteVideo(title: "收藏", pageURLString: "https://library.example/item")
        favorite.isPinned = true; favorite.pinOrder = 2
        let offline = OfflineItem(title: "小说", localPath: "Offline/roundtrip/book.txt", fileType: .txt)
        for item in [nas as any PersistentModel, comic, external, site, favorite, offline] { context.insert(item) }
        try context.save()
        let snapshot = try ConfigBackup.captureAll(context: context)
        let encoded = try snapshot.json(), decoded = try ConfigBackup.decode(encoded)
        XCTAssertEqual(decoded.nasConfigs.first?.id, nas.id)
        XCTAssertEqual(decoded.sites.first?.id, site.id)
        XCTAssertEqual(decoded.favorites?.first?.id, favorite.id)
        XCTAssertEqual(decoded.favorites?.first?.pinOrder, 2)
        XCTAssertEqual(decoded.histories?.first { $0.id == comic.id }?.filePath, "chapter-17")
        XCTAssertNil(decoded.histories?.first { $0.id == external.id }?.filePath)
        XCTAssertEqual(decoded.offlineItems?.first?.id, offline.id)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let nasJSON = try XCTUnwrap((object["nasConfigs"] as? [[String: Any]])?.first)
        XCTAssertNil(nasJSON["password"])
        XCTAssertNil(object["folderSync.bookmark"])
    }
    func testOfflineFileUploadRestoreAndMissingCloudProtection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cloud = root.appendingPathComponent("Cloud"), source = root.appendingPathComponent("Source"), target = root.appendingPathComponent("Target")
        for url in [cloud, source, target] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        let path = "Offline/fixture/book.txt", contents = Data("离线内容".utf8)
        let sourceFile = source.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: sourceFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: sourceFile)
        var value = backup(); value.offlineItems = [.init(id: UUID(), title: "小说", localPath: path, fileType: .txt, savedAt: Date(timeIntervalSince1970: 100), fileSizeBytes: Int64(contents.count))]
        let worker = FolderSyncFiles()
        let reports = SyncProgressRecorder()
        let first = try await worker.synchronize(local: value.json(), baseline: nil, folder: cloud, dataRoot: source, recovery: root.appendingPathComponent("RecoveryA"), progress: reports.record)
        let copying = reports.values.filter { $0.phase == "写入云盘文件" }
        XCTAssertEqual(copying.first?.completedBytes, 0)
        XCTAssertEqual(copying.last?.completedBytes, Int64(contents.count))
        XCTAssertEqual(copying.last?.fraction, 1)
        XCTAssertEqual(copying.last?.fileCount, 1)
        XCTAssertTrue(reports.values.contains { $0.phase == "校验写入结果" })
        let digest = SHA256.hash(data: contents).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(try ConfigBackup.decode(first.data).offlineItems?.first?.contentSHA256, digest)
        let second = try await worker.synchronize(local: backup().json(), baseline: nil, folder: cloud, dataRoot: target, recovery: root.appendingPathComponent("RecoveryB"))
        XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent(path)), contents)
        XCTAssertEqual(try ConfigBackup.decode(second.data).offlineItems?.count, 1)
        try FileManager.default.removeItem(at: cloud.appendingPathComponent(FolderSyncPackage.appDataName))
        do {
            _ = try await worker.synchronize(local: value.json(), baseline: first.data, folder: cloud, dataRoot: source, recovery: root.appendingPathComponent("RecoveryC"))
            XCTFail("Missing cloud snapshot must not be replaced with a new library")
        } catch { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: cloud.appendingPathComponent(FolderSyncPackage.appDataName).path))
    }
    func testPlaceholderAndSymlinkCannotOverwriteExistingCloudData() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent(FolderSyncPackage.appDataName)
        let placeholder = root.appendingPathComponent(".\(FolderSyncPackage.appDataName).icloud")
        try Data().write(to: placeholder)
        let worker = FolderSyncFiles(), bytes = try backup().json()
        do { _ = try await worker.synchronize(local: bytes, baseline: nil, folder: root, dataRoot: root, recovery: root.appendingPathComponent("R")); XCTFail("Must wait for placeholder") } catch { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        try FileManager.default.removeItem(at: placeholder)
        let outside = root.appendingPathComponent("outside.json"); try bytes.write(to: outside)
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: outside)
        do { _ = try await worker.synchronize(local: bytes, baseline: nil, folder: root, dataRoot: root, recovery: root.appendingPathComponent("R")); XCTFail("Must reject symlink") } catch { }
        XCTAssertEqual(try Data(contentsOf: outside), bytes)
    }
}

private final class SyncProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [FolderSyncProgress] = []
    func record(_ value: FolderSyncProgress) { lock.withLock { events.append(value) } }
    var values: [FolderSyncProgress] { lock.withLock { events } }
}
