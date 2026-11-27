import SwiftUI

// MARK: - App Theme (Cinema Dark A / Warm Editorial B / Sepia / System)

enum AppTheme: String, CaseIterable, Identifiable, Codable {
    static let storageKey = "readerTheme"
    case cinemaDark = "dark"
    case lightEditorial = "light"
    case sepia = "sepia"
    case system = "system"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .cinemaDark: "影院暗色"
        case .lightEditorial: "暖白画报"
        case .sepia: "护眼纸质"
        case .system: "跟随系统"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .cinemaDark: .dark
        case .lightEditorial, .sepia: .light
        case .system: nil
        }
    }

    var backgroundColor: Color {
        switch self {
        case .cinemaDark: Color(red: 0.043, green: 0.043, blue: 0.055) // #0B0B0E
        case .lightEditorial: Color(red: 0.969, green: 0.965, blue: 0.949) // #F7F6F2
        case .sepia: Color(red: 0.980, green: 0.950, blue: 0.870)
        case .system: Color(.systemBackground)
        }
    }

    var cardColor: Color {
        switch self {
        case .cinemaDark: Color(red: 0.086, green: 0.086, blue: 0.106) // #16161B
        case .lightEditorial: .white
        case .sepia: Color(red: 0.955, green: 0.918, blue: 0.825)
        case .system: Color(.secondarySystemBackground)
        }
    }

    var textColor: Color {
        switch self {
        case .cinemaDark: Color(white: 0.92)
        case .lightEditorial: Color(red: 0.11, green: 0.11, blue: 0.12)
        case .sepia: Color(red: 0.30, green: 0.22, blue: 0.12)
        case .system: Color(.label)
        }
    }
}

extension View {
    func appSurface(_ theme: AppTheme) -> some View {
        self
            .scrollContentBackground(.hidden)
            .background(theme.backgroundColor.ignoresSafeArea())
    }
}

// MARK: - Responsive Spring Press Style (0ms tap response)

struct SpringPressButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(.snappy(duration: 0.18, extraBounce: 0.08), value: configuration.isPressed)
    }
}

// MARK: - Lightweight Floating Liquid Glass Toast

@Observable @MainActor
final class ToastCenter {
    static let shared = ToastCenter()
    private(set) var message: String?
    private(set) var systemImage: String = "checkmark.circle.fill"
    private var dismissTask: Task<Void, Never>?

    func show(_ text: String, icon: String = "checkmark.circle.fill") {
        dismissTask?.cancel()
        withAnimation(.snappy(duration: 0.25)) {
            message = text
            systemImage = icon
        }
        dismissTask = Task {
            try? await Task.sleep(for: .seconds(1.8))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) { message = nil }
        }
    }
}

struct ToastOverlay: View {
    @State private var toast = ToastCenter.shared

    var body: some View {
        if let message = toast.message {
            Label(message, systemImage: toast.systemImage)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .glassEffect(.regular, in: Capsule())
                .padding(.top, 12)
                .transition(.move(edge: .top).combined(with: .opacity))
                .allowsHitTesting(false)
        }
    }
}

// MARK: - Zoom Transition Environment Helper

private struct ZoomNamespaceKey: EnvironmentKey {
    static let defaultValue: Namespace.ID? = nil
}

extension EnvironmentValues {
    var zoomNamespace: Namespace.ID? {
        get { self[ZoomNamespaceKey.self] }
        set { self[ZoomNamespaceKey.self] = newValue }
    }
}

extension View {
    @ViewBuilder
    func coveZoomSource(id: some Hashable, in namespace: Namespace.ID?) -> some View {
        if let namespace { self.matchedTransitionSource(id: id, in: namespace) } else { self }
    }

    @ViewBuilder
    func coveZoomDestination(id: some Hashable, in namespace: Namespace.ID?) -> some View {
        if let namespace { self.navigationTransition(.zoom(sourceID: id, in: namespace)) } else { self }
    }
}
