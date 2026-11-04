import SwiftUI

struct RootView: View {
    @Environment(AppStore.self) private var store
    @State private var inbox = FileInbox.shared
    @State private var showInbox = false

    var body: some View {
        if store.config.isConfigured {
            TabView {
                SessionsListView()
                    .tabItem { Label("Chats", systemImage: "bubble.left.and.bubble.right") }
                BoxView()
                    .tabItem { Label("Box", systemImage: "server.rack") }
                FilesHomeView()
                    .tabItem { Label("Files", systemImage: "folder") }
            }
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
