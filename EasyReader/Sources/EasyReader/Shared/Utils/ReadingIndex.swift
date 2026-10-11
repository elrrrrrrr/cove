import SwiftUI
import SwiftData

struct HistorySnapshot: Equatable, Sendable {
    let id: UUID
    let title: String
    let url: String?
    let path: String?
    let date: Date
    @MainActor init(_ item: ReadingHistory) {
        id = item.id; title = item.title; url = item.url; path = item.filePath; date = item.lastReadAt
    }
}

enum ReadingProjection {
    struct Group: Sendable { let title: String; let ids: [UUID]; let date: Date }
    struct Result: Sendable { let recent: [UUID]; let groups: [Group] }

    static func displayTitle(_ title: String) -> String {
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.contains("://") || value.hasPrefix("/") else { return value }
        if value.hasPrefix("/") {
            let filename = (value as NSString).lastPathComponent
            let name = filename.components(separatedBy: ".").dropLast().joined(separator: ".")
            return name.isEmpty ? filename : name
        }
        if let url = URL(string: value) {
            if let last = url.pathComponents.last(where: { $0 != "/" }), !last.isEmpty {
                let name = ((last.removingPercentEncoding ?? last) as NSString).deletingPathExtension
                if name.count > 1 { return name }
            }
            return url.host() ?? value
        }
        return value
    }

    static func make(_ records: [HistorySnapshot], includeGroups: Bool, now: Date, calendar: Calendar) -> Result {
        var keys = Set<String>(), titles = Set<String>(), recent: [UUID] = []
        for item in records {
            if Task.isCancelled { return Result(recent: [], groups: []) }
            guard keys.insert(item.url ?? item.path ?? item.id.uuidString).inserted,
                  titles.insert(displayTitle(item.title)).inserted else { continue }
            recent.append(item.id)
            if recent.count == 12 { break }
        }
        guard includeGroups else { return Result(recent: recent, groups: []) }
        let formatter = DateFormatter(); formatter.calendar = calendar; formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy年M月d日"
        let today = calendar.startOfDay(for: now), yesterday = calendar.date(byAdding: .day, value: -1, to: today)
        var days: [Date: [UUID]] = [:]
        for item in records {
            if Task.isCancelled { return Result(recent: recent, groups: []) }
            days[calendar.startOfDay(for: item.date), default: []].append(item.id)
        }
        let groups = days.keys.sorted(by: >).map { day in
            Group(title: day == today ? "今天" : day == yesterday ? "昨天" : formatter.string(from: day), ids: days[day]!, date: day)
        }
        return Result(recent: recent, groups: groups)
    }
}

@Observable @MainActor final class ReadingIndex {
    private(set) var latest: ReadingHistory?
    private(set) var recent: [ReadingHistory] = []
    private(set) var groups: [(title: String, items: [ReadingHistory])] = []
    private var projection = ReadingProjection.Result(recent: [], groups: [])
    private let includeGroups: Bool
    private var work: Task<Void, Never>?
    private var generation = UUID()
    init(includeGroups: Bool = false) { self.includeGroups = includeGroups }

    func update(_ records: [ReadingHistory], snapshots: [HistorySnapshot]? = nil, now: Date = Date(), calendar: Calendar = .current) {
        work?.cancel(); generation = UUID()
        let id = generation, snapshots = snapshots ?? records.map(HistorySnapshot.init), includeGroups = includeGroups
        let byID = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // Drop removed models before publishing any state that can redraw their cards.
        recent = projection.recent.compactMap { byID[$0] }
        groups = projection.groups.map { ($0.title, $0.ids.compactMap { byID[$0] }) }.filter { !$0.1.isEmpty }
        latest = records.first
        work = Task {
            guard !Task.isCancelled else { return }
            let preparation = Task.detached(priority: .userInitiated) { ReadingProjection.make(snapshots, includeGroups: includeGroups, now: now, calendar: calendar) }
            let result = await withTaskCancellationHandler { await preparation.value } onCancel: { preparation.cancel() }
            guard !Task.isCancelled, generation == id else { return }
            projection = result
            recent = result.recent.compactMap { byID[$0] }
            groups = result.groups.map { ($0.title, $0.ids.compactMap { byID[$0] }) }
        }
    }
}

/// Query observation is isolated from collapse, layout and download UI state.
struct ReadingIndexObserver: View, Equatable {
    @Query(sort: \ReadingHistory.lastReadAt, order: .reverse) private var records: [ReadingHistory]
    @Environment(\.scenePhase) private var scenePhase
    nonisolated let index: ReadingIndex
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.index === rhs.index }
    var body: some View {
        let snapshots = records.map(HistorySnapshot.init)
        Color.clear.frame(width: 0, height: 0).allowsHitTesting(false)
            .onChange(of: snapshots, initial: true) { index.update(records, snapshots: snapshots) }
            .onChange(of: scenePhase) { if scenePhase == .active { index.update(records, snapshots: snapshots) } }
            .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in index.update(records, snapshots: snapshots) }
            .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in index.update(records, snapshots: snapshots) }
            .onReceive(NotificationCenter.default.publisher(for: NSLocale.currentLocaleDidChangeNotification)) { _ in index.update(records, snapshots: snapshots) }
    }
}
