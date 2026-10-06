import Foundation
import Observation

@Observable @MainActor final class BrowserModel {
    private(set) var items: [ResourceItem] = []
    private(set) var loading = false
    private(set) var loadingMore = false
    private(set) var nextCursor: String?
    var error: String?
    var query = ""
    var kind: ResourceKind?
    private(set) var visible: [ResourceItem] = []
    let locator: String
    let provider: any SourceProvider
    private var generation = 0
    private var searchTask: Task<Void, Never>?
    init(provider: any SourceProvider, locator: String) { self.provider = provider; self.locator = locator }
    func load(force: Bool = false) async {
        generation += 1
        let token = generation
        loading = true; loadingMore = false; error = nil
        do {
            let page = try await provider.list(CollectionRequest(locator: locator,
                query: query.isEmpty ? nil : query, forceRefresh: force))
            try Task.checkCancellation()
            guard generation == token else { return }
            items = page.items; nextCursor = page.nextCursor; prepareVisible()
        } catch is CancellationError { }
        catch { if generation == token { self.error = error.localizedDescription } }
        if generation == token { loading = false }
    }
    func loadMore() async {
        guard !loading, !loadingMore, let cursor = nextCursor else { return }
        let token = generation
        loadingMore = true
        defer { if generation == token { loadingMore = false } }
        do {
            let page = try await provider.list(CollectionRequest(locator: locator,
                query: query.isEmpty ? nil : query, cursor: cursor))
            try Task.checkCancellation()
            guard generation == token else { return }
            let existing = Set(items.map(\.id))
            let addition = page.items.filter { !existing.contains($0.id) }
            items.append(contentsOf: addition)
            nextCursor = addition.isEmpty ? nil : page.nextCursor
            prepareVisible()
        } catch is CancellationError { }
        catch { if generation == token { self.error = error.localizedDescription } }
    }
    func setQuery(_ value: String) {
        query = value
        if provider.definition.modules?.search == nil {
            prepareVisible(); return
        }
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            await self?.load()
        }
    }
    func setKind(_ value: ResourceKind?) { kind = value; prepareVisible() }
    private func prepareVisible() {
        visible = items.filter { item in
            (kind == nil || item.kind == kind) && (provider.definition.modules?.search != nil || query.isEmpty || item.title.localizedCaseInsensitiveContains(query))
        }
    }
    var videoSequence: [ResourceItem] { visible.filter { $0.kind == .video } }
}
