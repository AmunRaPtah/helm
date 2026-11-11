import SwiftUI

@main
struct HelmApp: App {
    @State private var store = AppStore()

    init() {
        HelmAppearance.install()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .preferredColorScheme(.dark)
                .tint(HelmColor.lime)
                .onOpenURL { FileInbox.shared.receive($0) }
        }
    }
}

/// Kept for stored-preference compatibility. Helm is dark-only now: the
/// instrument-panel palette is designed for obsidian and the mark is steel-white.
enum Appearance: String, CaseIterable, Identifiable {
    case system, dark, light
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .dark: return .dark
        case .light: return .light
        }
    }
}
