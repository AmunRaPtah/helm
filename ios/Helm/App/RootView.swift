import SwiftUI

struct RootView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        if store.config.isConfigured {
            TabView {
                SessionsListView()
                    .tabItem { Label("Chats", systemImage: "bubble.left.and.bubble.right") }
                BoxView()
                    .tabItem { Label("Box", systemImage: "server.rack") }
            }
        } else {
            NavigationStack {
                SettingsView(isOnboarding: true)
            }
        }
    }
}
