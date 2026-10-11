import XCTest
@testable import EasyReader

@MainActor final class FolderSyncPackageTests: XCTestCase {
    private func fixture() throws -> ConfigBackup {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "demo", withExtension: "site", subdirectory: "Sites"))
        let definition = try SiteDefinition.decode(String(contentsOf: url, encoding: .utf8))
        let entry = definition.entries[0]
        return ConfigBackup(exportDate: Date(timeIntervalSince1970: 100),
            settings: .init(readerFontSize: 17, readerTheme: AppTheme.system.rawValue, contentBlockerEnabled: true),
            sites: [.init(id: UUID(), name: entry.name, urlString: entry.url(in: definition)!.absoluteString,
                category: SiteCategory(configurationValue: entry.category)!.rawValue, note: "保留备注", sortOrder: 7,
                definitionID: definition.id, entryID: entry.id)],
            nasConfigs: [.init(id: UUID(), name: "NAS", host: "smb://nas.example", port: 445, username: "reader", shareName: "Books")],
            siteDefinitions: [definition], favorites: [.init(id: UUID(), title: "收藏", pageURL: "https://media.example/watch/1", isPinned: true, pinOrder: 0)],
            histories: [.init(id: UUID(), title: "阅读", url: "https://media.example/read/1", fileType: .web, progress: 0.25, lastReadAt: Date(timeIntervalSince1970: 100))],
            offlineItems: [], preferences: ["home.recent.collapsed": "true"])
    }
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func sync(_ worker: FolderSyncFiles, _ value: ConfigBackup, baseline: Data?, root: URL) async throws -> FolderSyncFiles.Result {
        try await worker.synchronize(local: value.json(), baseline: baseline, folder: root, dataRoot: root,
            recovery: root.appendingPathComponent("Recovery"))
    }
    func testProjectionUsesExistingSchemasWithoutDuplicatingAuthoritativeData() throws {
        let value = try fixture(), bytes = try value.json()
        let documents = try FolderSyncPackage.documents(bytes)
        XCTAssertEqual(documents.count, 3)
        let metadata = try FolderSyncPackage.object(XCTUnwrap(documents[FolderSyncPackage.appDataName]))
        XCTAssertEqual(metadata["schemaVersion"] as? Int, 1)
        XCTAssertNil(metadata["siteDefinitions"]); XCTAssertNil(metadata["favorites"])
        XCTAssertEqual(metadata["siteDefinitionIDs"] as? [String], [value.siteDefinitions[0].id])
        let favorites = try FavoriteDataFile.decode(XCTUnwrap(documents[FolderSyncPackage.favoritesName]))
        XCTAssertEqual(favorites.schemaVersion, 1); XCTAssertEqual(favorites.favorites.first?.id, value.favorites?.first?.id)
        let restored = try FolderSyncPackage.assemble(documents)
        XCTAssertTrue(try FolderSyncMerge.equivalent(bytes, restored))
    }
    func testPublicationPreservesAllRecordsAndHasOnlyOneActiveFormat() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let value = try fixture(), bytes = try value.json(), worker = FolderSyncFiles()
        let first = try await sync(worker, value, baseline: nil, root: root)
        XCTAssertTrue(try FolderSyncMerge.equivalent(first.data, bytes))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Cove-Backup.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(FolderSyncPackage.appDataName).path))
        let second = try await sync(worker, value, baseline: first.data, root: root)
        XCTAssertTrue(try FolderSyncMerge.equivalent(second.data, bytes))
        XCTAssertEqual(try ConfigBackup.decode(second.data).nasConfigs.first?.id, value.nasConfigs.first?.id)
        XCTAssertEqual(try ConfigBackup.decode(second.data).histories?.first?.id, value.histories?.first?.id)
    }
    func testMacEditsApplyByIdentityAndDoNotReseedDeletedEntriesOrRewriteComments() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let value = try fixture(), worker = FolderSyncFiles()
        let first = try await sync(worker, value, baseline: nil, root: root)
        var definition = value.siteDefinitions[0]
        definition.entries[0].path = "/changed/"; definition.entries[0].name = "改名"
        let site = root.appendingPathComponent("sites/\(definition.id).site")
        let edited = Data(("# Mac 编辑保留注释\n" + (try definition.yaml())).utf8)
        try edited.write(to: site)
        var favorites = FavoriteDataFile(favorites: value.favorites!)
        favorites.favorites[0].title = "来自 Mac 的标题"
        try favorites.json().write(to: root.appendingPathComponent(FolderSyncPackage.favoritesName))
        let second = try await sync(worker, value, baseline: first.data, root: root)
        let result = try ConfigBackup.decode(second.data)
        XCTAssertEqual(result.sites.count, 1, "Deleted entries must not reappear from .site")
        XCTAssertEqual(result.sites[0].id, value.sites[0].id)
        XCTAssertEqual(result.sites[0].name, "改名")
        XCTAssertEqual(result.sites[0].urlString, definition.entries[0].url(in: definition)?.absoluteString)
        XCTAssertEqual(result.sites[0].note, "保留备注"); XCTAssertEqual(result.sites[0].sortOrder, 7)
        XCTAssertEqual(result.favorites?.first?.id, value.favorites?.first?.id)
        XCTAssertEqual(result.favorites?.first?.title, "来自 Mac 的标题")
        XCTAssertEqual(try Data(contentsOf: site), edited)
        let third = try await sync(worker, result, baseline: second.data, root: root)
        XCTAssertEqual(try ConfigBackup.decode(third.data).sites[0].urlString, result.sites[0].urlString, "Catalog projection must not revert on the next pass")
    }
    func testIncompleteCloudDirectoryCannotRestoreOldAggregateOrEraseRecords() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let value = try fixture(), worker = FolderSyncFiles()
        let first = try await sync(worker, value, baseline: nil, root: root)
        let metadata = root.appendingPathComponent(FolderSyncPackage.appDataName), original = try Data(contentsOf: metadata)
        try value.json().write(to: root.appendingPathComponent("Cove-Backup.json"))
        try FileManager.default.removeItem(at: root.appendingPathComponent(FolderSyncPackage.favoritesName))
        do { _ = try await sync(worker, value, baseline: first.data, root: root); XCTFail("Missing favorites must pause") } catch { }
        XCTAssertEqual(try Data(contentsOf: metadata), original)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Cove-Backup.json").path))
    }
    func testInvalidOrMissingSiteStopsBeforePublishing() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let value = try fixture(), worker = FolderSyncFiles()
        let first = try await sync(worker, value, baseline: nil, root: root)
        let metadata = root.appendingPathComponent(FolderSyncPackage.appDataName), original = try Data(contentsOf: metadata)
        let site = root.appendingPathComponent("sites/\(value.siteDefinitions[0].id).site")
        let good = try Data(contentsOf: site)
        try Data("schemaVersion: 2\n".utf8).write(to: site)
        do { _ = try await sync(worker, value, baseline: first.data, root: root); XCTFail("Invalid schema must pause") } catch { }
        XCTAssertEqual(try Data(contentsOf: metadata), original)
        try FileManager.default.removeItem(at: site)
        do { _ = try await sync(worker, value, baseline: first.data, root: root); XCTFail("Missing site must pause") } catch { }
        XCTAssertEqual(try Data(contentsOf: metadata), original)
        try good.write(to: site)
        _ = try await sync(worker, value, baseline: first.data, root: root)
    }
    func testFailedPublicationRollsBackNewFilesAndCanRetry() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let value = try fixture(), bytes = try value.json(), worker = FolderSyncFiles()
        let target = root.appendingPathComponent(FolderSyncPackage.appDataName)
        do {
            _ = try await worker.synchronize(local: bytes, baseline: nil, folder: root, dataRoot: root,
                recovery: root.appendingPathComponent("Recovery")) { progress in
                if progress.fileName == FolderSyncPackage.appDataName {
                    try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                }
            }
            XCTFail("Injected publication failure must surface")
        } catch { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(FolderSyncPackage.favoritesName).path))
        try FileManager.default.removeItem(at: target)
        _ = try await sync(worker, value, baseline: nil, root: root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
    }
    func testPrivateMigrationFixtureIfPresentPreservesEveryRecord() throws {
        guard let root = Bundle(for: Self.self).resourceURL?.appendingPathComponent("LocalSiteTests/folder-sync-package-check"),
              FileManager.default.fileExists(atPath: root.path) else { throw XCTSkip("No private migration fixture") }
        let original = try Data(contentsOf: root.appendingPathComponent("Original.json"))
        var documents: [String: Data] = [:]
        for name in [FolderSyncPackage.appDataName, FolderSyncPackage.favoritesName] {
            documents[name] = try Data(contentsOf: root.appendingPathComponent(name))
        }
        let files = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("sites"), includingPropertiesForKeys: nil)
        for file in files where file.pathExtension == "site" { documents["sites/\(file.lastPathComponent)"] = try Data(contentsOf: file) }
        let restored = try FolderSyncPackage.assemble(documents)
        XCTAssertTrue(try FolderSyncMerge.equivalent(original, restored))
        let before = try ConfigBackup.decode(original), after = try ConfigBackup.decode(restored)
        XCTAssertEqual(after.histories?.count, before.histories?.count)
        XCTAssertEqual(Set(after.histories?.map(\.id) ?? []), Set(before.histories?.map(\.id) ?? []))
        XCTAssertEqual(Set(after.favorites?.compactMap(\.id) ?? []), Set(before.favorites?.compactMap(\.id) ?? []))
        XCTAssertEqual(Set(after.nasConfigs.map(\.id)), Set(before.nasConfigs.map(\.id)))
    }
    func testDuplicateSiteIdentityAndEmbeddedCopiesAreRejected() throws {
        let value = try fixture()
        var documents = try FolderSyncPackage.documents(value.json())
        let path = "sites/\(value.siteDefinitions[0].id).site"
        documents["sites/duplicate.site"] = documents[path]
        XCTAssertThrowsError(try FolderSyncPackage.assemble(documents))
        documents.removeValue(forKey: "sites/duplicate.site")
        documents[FolderSyncPackage.appDataName] = try value.json()
        XCTAssertThrowsError(try FolderSyncPackage.assemble(documents))
    }
}
