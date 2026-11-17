import SwiftUI

struct RootView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    @State private var inbox = FileInbox.shared
    @State private var drop = DropStore.shared
    @State private var askInbox = false
    @State private var showInbox = false
    @State private var tab = 0

    var body: some View {
        if store.config.isConfigured {
            TabView(selection: $tab) {
                SessionsListView()
                    .tabItem { Label("Chats", systemImage: "bubble.left.and.bubble.right") }
                    .tag(0)
                DropView()
                    .tabItem { Label("Drop", systemImage: "paperplane") }
                    .badge(drop.unread)
                    .tag(3)
                BoxView()
                    .tabItem { Label("Box", systemImage: "server.rack") }
                    .tag(1)
                FilesHomeView()
                    .tabItem { Label("Files", systemImage: "folder") }
                    .tag(2)
            }
            .tint(HelmColor.lime)
            .onChange(of: tab) { _, _ in Haptics.tap() }
            // Keeps the Drop thread (and its tab badge) current while the app is open.
            .task(id: "\(scenePhase == .active)\(store.config.normalizedURLString)") {
                guard scenePhase == .active else { return }
                await drop.run(api: store.api)
            }
            // Files shared into Helm from another app ("Open in Helm"): Drop or a box folder.
            .onChange(of: inbox.pending.count) { _, n in if n > 0 { askInbox = true } }
            .onAppear { if !inbox.pending.isEmpty { askInbox = true } }
            .confirmationDialog(inboxTitle, isPresented: $askInbox, titleVisibility: .visible) {
                Button("Send to Drop") {
                    let urls = inbox.pending
                    inbox.pending = []
                    tab = 3
                    drop.send(urls, owned: true)
                }
                Button("Upload to a box folder\u{2026}") { showInbox = true }
                Button("Cancel", role: .cancel) {
                    for u in inbox.pending { try? FileManager.default.removeItem(at: u.deletingLastPathComponent()) }
                    inbox.pending = []
                }
            }
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

    private var inboxTitle: String {
        let n = inbox.pending.count
        return n == 1 ? "Send \(inbox.pending[0].lastPathComponent)" : "Send \(n) files"
    }
}
