import SwiftUI

struct RootView: View {
    @Environment(AppStore.self) private var store
    @State private var inbox = FileInbox.shared
    @State private var showInbox = false
    @State private var tab = 0

    var body: some View {
        if store.config.isConfigured {
            TabView(selection: $tab) {
                SessionsListView()
                    .tabItem { Label("Chats", systemImage: "bubble.left.and.bubble.right") }
                    .tag(0)
                BoxView()
                    .tabItem { Label("Box", systemImage: "server.rack") }
                    .tag(1)
                FilesHomeView()
                    .tabItem { Label("Files", systemImage: "folder") }
                    .tag(2)
            }
            .tint(HelmColor.lime)
            .onChange(of: tab) { _, _ in Haptics.tap() }
            // Files shared into Helm from another app ("Open in Helm").
            .onChange(of: inbox.pending.count) { _, n in if n > 0 { showInbox = true } }
            .onAppear { if !inbox.pending.isEmpty { showInbox = true } }
            .sheet(isPresented: $showInbox) {
                NavigationStack { BoxUploadView() }
                    .environment(store)
            }
        } else {
            NavigationStack {
                SettingsView(isOnboarding: true)
            }
        }
    }
}
