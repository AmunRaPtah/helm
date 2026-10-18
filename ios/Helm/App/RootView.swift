import SwiftUI

struct RootView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        if store.config.isConfigured {
            SessionsListView()
        } else {
            NavigationStack {
                SettingsView(isOnboarding: true)
            }
        }
    }
}
