import SwiftUI

// MARK: - BentoCardSize

enum BentoCardSize {
    case small, large
}

// MARK: - BentoMetrics

struct BentoMetrics: Equatable {
    let smallWidth: CGFloat
    let smallHeight: CGFloat
    let largeWidth: CGFloat
    let largeHeight: CGFloat
    let spacing: CGFloat

    static let zero = BentoMetrics()

    private init() {
        smallWidth = 0; smallHeight = 0
        largeWidth = 0; largeHeight = 0
        spacing = 10
    }

    init(availableWidth: CGFloat, columns: Int, spacing: CGFloat = 10) {
        guard availableWidth > 0, columns > 0 else { self = .zero; return }
        self.spacing = spacing
        let gaps = CGFloat(columns - 1) * spacing
        smallWidth  = floor((availableWidth - gaps) / CGFloat(columns))
        smallHeight = floor(smallWidth * (9.0 / 16.0) + 44)

        if columns == 2 {
            largeWidth  = availableWidth
            largeHeight = floor(availableWidth * (9.0 / 16.0) + 50)
        } else {
            largeWidth  = smallWidth * 2 + spacing
            largeHeight = smallHeight * 2 + spacing
        }
    }
}

// MARK: - BentoSlot

struct BentoSlot: Identifiable {
    let id: Int
    let kind: Kind
    enum Kind {
        case fullWidth(index: Int)
        case smallRow(indices: [Int])
        case largeLeftSmallRight(largeIdx: Int, topIdx: Int, bottomIdx: Int)
        case smallLeftLargeRight(topIdx: Int, bottomIdx: Int, largeIdx: Int)
    }
}

// MARK: - BentoGrouper

enum BentoGrouper {
    static func group2Col(count: Int) -> [BentoSlot] {
        var slots: [BentoSlot] = []
        slots.reserveCapacity(count)
        var i = 0, slotID = 0, cycleRow = 0
        while i < count {
            switch cycleRow % 3 {
            case 0:
                slots.append(BentoSlot(id: slotID, kind: .fullWidth(index: i)))
                i += 1
            default:
                if i + 1 < count {
                    slots.append(BentoSlot(id: slotID, kind: .smallRow(indices: [i, i + 1])))
                    i += 2
                } else {
                    slots.append(BentoSlot(id: slotID, kind: .smallRow(indices: [i])))
                    i += 1
                }
            }
            slotID += 1; cycleRow += 1
        }
        return slots
    }

    static func group3Col(count: Int) -> [BentoSlot] {
        var slots: [BentoSlot] = []
        slots.reserveCapacity(count)
        var i = 0, slotID = 0, cycleRow = 0
        while i < count {
            switch cycleRow % 4 {
            case 0:
                if i + 2 < count {
                    slots.append(BentoSlot(id: slotID, kind: .largeLeftSmallRight(largeIdx: i, topIdx: i + 1, bottomIdx: i + 2)))
                    i += 3
                } else if i + 1 < count {
                    slots.append(BentoSlot(id: slotID, kind: .smallRow(indices: [i, i + 1])))
                    i += 2
                } else {
                    slots.append(BentoSlot(id: slotID, kind: .smallRow(indices: [i])))
                    i += 1
                }
            case 2:
                if i + 2 < count {
                    slots.append(BentoSlot(id: slotID, kind: .smallLeftLargeRight(topIdx: i, bottomIdx: i + 1, largeIdx: i + 2)))
                    i += 3
                } else if i + 1 < count {
                    slots.append(BentoSlot(id: slotID, kind: .smallRow(indices: [i, i + 1])))
                    i += 2
                } else {
                    slots.append(BentoSlot(id: slotID, kind: .smallRow(indices: [i])))
                    i += 1
                }
            default:
                let end = min(i + 3, count)
                slots.append(BentoSlot(id: slotID, kind: .smallRow(indices: Array(i..<end))))
                i = end
            }
            slotID += 1; cycleRow += 1
        }
        return slots
    }
}

// MARK: - BentoGrid

struct BentoGrid<Item: Identifiable, Content: View, Footer: View>: View {
    let items: [Item]
    let columns: Int
    @ViewBuilder let content: (Item, BentoCardSize) -> Content
    @ViewBuilder let footer: () -> Footer

    @State private var availableWidth: CGFloat = 0
    private var metrics: BentoMetrics { BentoMetrics(availableWidth: availableWidth, columns: columns) }
    @State private var slots: [BentoSlot] = []

    /// Convenience init without footer.
    init(items: [Item], columns: Int,
         @ViewBuilder content: @escaping (Item, BentoCardSize) -> Content)
    where Footer == EmptyView {
        self.items = items
        self.columns = columns
        self.content = content
        self.footer = { EmptyView() }
    }

    /// Init with footer (rendered after all bento rows, inside the LazyVStack).
    init(items: [Item], columns: Int,
         @ViewBuilder content: @escaping (Item, BentoCardSize) -> Content,
         @ViewBuilder footer: @escaping () -> Footer) {
        self.items = items
        self.columns = columns
        self.content = content
        self.footer = footer
    }

    var body: some View {
        LazyVStack(spacing: 10) {
            if metrics != .zero {
                ForEach(slots) { slot in
                    if let id = slotFirstID(slot) { slotView(slot).id(id) }
                }
                footer()
            }
        }
        .scrollTargetLayout()
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .onChange(of: [items.count, columns], initial: true) { _, _ in
            slots = columns == 2 ? BentoGrouper.group2Col(count: items.count) : BentoGrouper.group3Col(count: items.count)
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            floor(proxy.size.width - 24)
        } action: { width in
            availableWidth = width
        }
    }

    private func slotFirstID(_ slot: BentoSlot) -> Item.ID? {
        let index: Int?
        switch slot.kind {
        case .fullWidth(let value): index = value
        case .smallRow(let values): index = values.first
        case .largeLeftSmallRight(let large, _, _): index = large
        case .smallLeftLargeRight(let top, _, _): index = top
        }
        return index.flatMap { items.indices.contains($0) ? items[$0].id : nil }
    }
    @ViewBuilder private func card(_ index: Int, size: BentoCardSize) -> some View {
        if items.indices.contains(index) { content(items[index], size).id(items[index].id) }
    }

    @ViewBuilder
    private func slotView(_ slot: BentoSlot) -> some View {
        let m = metrics
        switch slot.kind {
        case .fullWidth(let idx):
            card(idx, size: .large)
                .frame(width: m.largeWidth, height: m.largeHeight)

        case .smallRow(let indices):
            HStack(spacing: m.spacing) {
                ForEach(indices, id: \.self) { idx in
                    card(idx, size: .small)
                        .frame(width: m.smallWidth, height: m.smallHeight)
                }
                if indices.count < columns { Spacer(minLength: 0) }
            }

        case .largeLeftSmallRight(let lg, let top, let bot):
            HStack(alignment: .top, spacing: m.spacing) {
                card(lg, size: .large)
                    .frame(width: m.largeWidth, height: m.largeHeight)
                VStack(spacing: m.spacing) {
                    card(top, size: .small)
                        .frame(width: m.smallWidth, height: m.smallHeight)
                    card(bot, size: .small)
                        .frame(width: m.smallWidth, height: m.smallHeight)
                }
            }

        case .smallLeftLargeRight(let top, let bot, let lg):
            HStack(alignment: .top, spacing: m.spacing) {
                VStack(spacing: m.spacing) {
                    card(top, size: .small)
                        .frame(width: m.smallWidth, height: m.smallHeight)
                    card(bot, size: .small)
                        .frame(width: m.smallWidth, height: m.smallHeight)
                }
                card(lg, size: .large)
                    .frame(width: m.largeWidth, height: m.largeHeight)
            }
        }
    }
}

// MARK: - BentoSkeletonGrid

struct BentoSkeletonGrid: View {
    let columns: Int
    private var itemCount: Int { columns == 2 ? 5 : 12 }

    @State private var metrics = BentoMetrics.zero

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                if metrics != .zero {
                    let slots = columns == 2
                        ? BentoGrouper.group2Col(count: itemCount)
                        : BentoGrouper.group3Col(count: itemCount)
                    ForEach(slots) { slot in
                        skeletonSlot(slot)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .allowsHitTesting(false)
        .onGeometryChange(for: CGFloat.self) { proxy in
            floor(proxy.size.width - 24)
        } action: { width in
            let m = BentoMetrics(availableWidth: width, columns: columns)
            if m != metrics { metrics = m }
        }
    }

    @ViewBuilder
    private func skeletonSlot(_ slot: BentoSlot) -> some View {
        let m = metrics
        switch slot.kind {
        case .fullWidth:
            SkeletonCard(isLarge: true)
                .frame(width: m.largeWidth, height: m.largeHeight)
        case .smallRow(let indices):
            HStack(spacing: m.spacing) {
                ForEach(indices, id: \.self) { _ in
                    SkeletonCard().frame(width: m.smallWidth, height: m.smallHeight)
                }
                if indices.count < columns { Spacer(minLength: 0) }
            }
        case .largeLeftSmallRight:
            HStack(alignment: .top, spacing: m.spacing) {
                SkeletonCard(isLarge: true).frame(width: m.largeWidth, height: m.largeHeight)
                VStack(spacing: m.spacing) {
                    SkeletonCard().frame(width: m.smallWidth, height: m.smallHeight)
                    SkeletonCard().frame(width: m.smallWidth, height: m.smallHeight)
                }
            }
        case .smallLeftLargeRight:
            HStack(alignment: .top, spacing: m.spacing) {
                VStack(spacing: m.spacing) {
                    SkeletonCard().frame(width: m.smallWidth, height: m.smallHeight)
                    SkeletonCard().frame(width: m.smallWidth, height: m.smallHeight)
                }
                SkeletonCard(isLarge: true).frame(width: m.largeWidth, height: m.largeHeight)
            }
        }
    }
}
