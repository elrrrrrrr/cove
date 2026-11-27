import SwiftUI

enum BentoCardSize { case small, large }

struct BentoMetrics: Equatable {
    let smallWidth: CGFloat
    let smallHeight: CGFloat
    let largeWidth: CGFloat
    let largeHeight: CGFloat
    let spacing: CGFloat

    static let zero = BentoMetrics()
    private init() { smallWidth = 0; smallHeight = 0; largeWidth = 0; largeHeight = 0; spacing = 10 }

    init(availableWidth: CGFloat, columns: Int, spacing: CGFloat = 10) {
        guard availableWidth > 0, columns > 0 else { self = .zero; return }
        self.spacing = spacing
        let gaps = CGFloat(columns - 1) * spacing
        smallWidth = floor((availableWidth - gaps) / CGFloat(columns))
        smallHeight = floor(smallWidth * (9.0 / 16.0) + 46)
        if columns == 2 {
            largeWidth = availableWidth
            largeHeight = floor(availableWidth * (9.0 / 16.0) + 52)
        } else {
            largeWidth = smallWidth * 2 + spacing
            largeHeight = smallHeight * 2 + spacing
        }
    }
}

struct BentoSlot: Identifiable {
    let id: Int
    let kind: Kind
    enum Kind {
        case fullWidth(Int)
        case smallRow([Int])
        case largeLeftSmallRight(Int, Int, Int)
        case smallLeftLargeRight(Int, Int, Int)
    }
}

enum BentoGrouper {
    static func group(count: Int, columns: Int) -> [BentoSlot] {
        columns == 2 ? group2Col(count: count) : group3Col(count: count)
    }

    static func group2Col(count: Int) -> [BentoSlot] {
        var slots: [BentoSlot] = []; slots.reserveCapacity(count)
        var i = 0, slotID = 0, row = 0
        while i < count {
            if row % 3 == 0 {
                slots.append(BentoSlot(id: slotID, kind: .fullWidth(i)))
                i += 1
            } else if i + 1 < count {
                slots.append(BentoSlot(id: slotID, kind: .smallRow([i, i + 1])))
                i += 2
            } else {
                slots.append(BentoSlot(id: slotID, kind: .smallRow([i])))
                i += 1
            }
            slotID += 1; row += 1
        }
        return slots
    }

    static func group3Col(count: Int) -> [BentoSlot] {
        var slots: [BentoSlot] = []; slots.reserveCapacity(count)
        var i = 0, slotID = 0, row = 0
        while i < count {
            if row % 4 == 0, i + 2 < count {
                slots.append(BentoSlot(id: slotID, kind: .largeLeftSmallRight(i, i + 1, i + 2))); i += 3
            } else if row % 4 == 2, i + 2 < count {
                slots.append(BentoSlot(id: slotID, kind: .smallLeftLargeRight(i, i + 1, i + 2))); i += 3
            } else {
                let end = min(i + ((row % 2 == 0) ? 2 : 3), count)
                slots.append(BentoSlot(id: slotID, kind: .smallRow(Array(i..<end)))); i = end
            }
            slotID += 1; row += 1
        }
        return slots
    }
}

struct BentoGrid<Item: Identifiable, Content: View, Footer: View>: View {
    let items: [Item]
    let columns: Int
    @ViewBuilder let content: (Item, BentoCardSize) -> Content
    @ViewBuilder let footer: () -> Footer

    @State private var availableWidth: CGFloat = 0

    init(items: [Item], columns: Int, @ViewBuilder content: @escaping (Item, BentoCardSize) -> Content) where Footer == EmptyView {
        self.items = items; self.columns = columns; self.content = content; self.footer = { EmptyView() }
    }

    init(items: [Item], columns: Int, @ViewBuilder content: @escaping (Item, BentoCardSize) -> Content, @ViewBuilder footer: @escaping () -> Footer) {
        self.items = items; self.columns = columns; self.content = content; self.footer = footer
    }

    private var metrics: BentoMetrics { BentoMetrics(availableWidth: availableWidth, columns: columns) }
    private var slots: [BentoSlot] { BentoGrouper.group(count: items.count, columns: columns) }

    var body: some View {
        LazyVStack(spacing: 10) {
            if metrics != .zero {
                ForEach(slots) { slot in slotView(slot) }
                footer()
            }
        }
        .scrollTargetLayout()
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .onGeometryChange(for: CGFloat.self) { floor($0.size.width - 24) } action: { availableWidth = $0 }
    }

    @ViewBuilder private func card(_ index: Int, size: BentoCardSize) -> some View {
        if items.indices.contains(index) { content(items[index], size).id(items[index].id) }
    }

    @ViewBuilder private func slotView(_ slot: BentoSlot) -> some View {
        let m = metrics
        switch slot.kind {
        case .fullWidth(let idx):
            card(idx, size: .large).frame(width: m.largeWidth, height: m.largeHeight)
        case .smallRow(let indices):
            HStack(spacing: m.spacing) {
                ForEach(indices, id: \.self) { card($0, size: .small).frame(width: m.smallWidth, height: m.smallHeight) }
                if indices.count < columns { Spacer(minLength: 0) }
            }
        case .largeLeftSmallRight(let lg, let t, let b):
            HStack(alignment: .top, spacing: m.spacing) {
                card(lg, size: .large).frame(width: m.largeWidth, height: m.largeHeight)
                VStack(spacing: m.spacing) {
                    card(t, size: .small).frame(width: m.smallWidth, height: m.smallHeight)
                    card(b, size: .small).frame(width: m.smallWidth, height: m.smallHeight)
                }
            }
        case .smallLeftLargeRight(let t, let b, let lg):
            HStack(alignment: .top, spacing: m.spacing) {
                VStack(spacing: m.spacing) {
                    card(t, size: .small).frame(width: m.smallWidth, height: m.smallHeight)
                    card(b, size: .small).frame(width: m.smallWidth, height: m.smallHeight)
                }
                card(lg, size: .large).frame(width: m.largeWidth, height: m.largeHeight)
            }
        }
    }
}
