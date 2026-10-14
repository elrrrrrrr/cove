import SwiftUI

enum SkeletonStyle {
    static func gradient(phase: CGFloat) -> LinearGradient {
        LinearGradient(stops: [
            .init(color: Color(.systemFill), location: phase),
            .init(color: Color(.tertiarySystemFill), location: phase + 0.4),
            .init(color: Color(.systemFill), location: phase + 0.8)
        ], startPoint: .leading, endPoint: .trailing)
    }
}

struct SkeletonShimmer<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = -1
    let content: (LinearGradient) -> Content
    init(@ViewBuilder content: @escaping (LinearGradient) -> Content) { self.content = content }
    var body: some View {
        content(SkeletonStyle.gradient(phase: phase))
            .onAppear { animate() }
            .onChange(of: reduceMotion) { animate() }
    }
    private func animate() {
        withAnimation(nil) { phase = reduceMotion ? 0.2 : -1 }
        if !reduceMotion { withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) { phase = 1.2 } }
    }
}

// MARK: - Skeleton card

struct SkeletonCard: View {
    var isLarge: Bool = false
    let gradient: LinearGradient

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(gradient)
                .aspectRatio(16/9, contentMode: .fit)
            VStack(alignment: .leading, spacing: 5) {
                Capsule().fill(gradient).frame(height: isLarge ? 14 : 12)
                Capsule().fill(gradient).frame(width: isLarge ? 120 : 80, height: isLarge ? 12 : 10)
                if isLarge {
                    Capsule().fill(gradient).frame(width: 60, height: 10)
                }
            }
            .padding(.horizontal, 4).padding(.vertical, 6)
        }
        .clipped()
    }
}

// MARK: - Portrait skeleton grid (2:3 cards, uniform LazyVGrid)

struct PortraitSkeletonGrid: View {
    let columns: Int

    var body: some View {
        let cols = Array(repeating: GridItem(.flexible(), spacing: 10), count: columns)
        SkeletonShimmer { gradient in
            ScrollView {
                LazyVGrid(columns: cols, spacing: 12) {
                    ForEach(0..<12, id: \.self) { _ in
                        VStack(alignment: .leading, spacing: 0) {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(gradient)
                                .aspectRatio(2/3, contentMode: .fit)
                            VStack(alignment: .leading, spacing: 4) {
                                Capsule().fill(gradient).frame(height: 12)
                                Capsule().fill(gradient).frame(width: 60, height: 10)
                            }
                            .padding(.horizontal, 2).padding(.vertical, 5)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - List skeleton (horizontal card placeholders)

struct ListSkeletonView: View {
    var body: some View {
        SkeletonShimmer { gradient in
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(0..<8, id: \.self) { _ in
                        HStack(spacing: 12) {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(gradient)
                                .frame(width: 48, height: 48)
                            VStack(alignment: .leading, spacing: 6) {
                                Capsule().fill(gradient).frame(height: 14)
                                Capsule().fill(gradient).frame(width: 100, height: 11)
                            }
                            Spacer()
                        }
                        .padding(14)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                }
                .padding(12)
            }
        }
        .allowsHitTesting(false)
    }
}
