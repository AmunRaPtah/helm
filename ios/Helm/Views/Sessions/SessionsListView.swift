import SwiftUI

struct SessionsListView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase

    @State private var path: [String] = []
    @State private var showNew = false
    @State private var showSettings = false
    @State private var pendingDelete: Session?

    var body: some View {
        NavigationStack(path: $path) {
            list
                .navigationTitle("Helm")
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { showSettings = true } label: { Image(systemName: "gearshape") }
                            .accessibilityLabel("Settings")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { showNew = true } label: { Image(systemName: "square.and.pencil") }
                            .accessibilityLabel("New chat")
                    }
                }
                .safeAreaInset(edge: .bottom) { newChatButton }
                .navigationDestination(for: String.self) { id in
                    ChatScreen(sessionId: id)
                }
        }
        .sheet(isPresented: $showNew) {
            NewSessionSheet { session in
                showNew = false
                path = [session.id]
            }
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack { SettingsView() }
        }
        .confirmationDialog("Delete this chat?", isPresented: Binding(
            get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }
        ), titleVisibility: .visible, presenting: pendingDelete) { s in
            Button("Delete", role: .destructive) { Task { await store.delete(s.id) } }
        } message: { _ in
            Text("Kills the tmux session on the server. Files on the box are kept.")
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            await store.refreshHarnesses()
            while !Task.isCancelled {
                if path.isEmpty { await store.refresh() }
                try? await Task.sleep(nanoseconds: 4_000_000_000)
            }
        }
    }

    @ViewBuilder
    private var list: some View {
        List {
            if let err = store.listError {
                OfflineBanner(message: err, lastSync: store.lastSync)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
            }
            ForEach(store.sessions) { s in
                NavigationLink(value: s.id) {
                    SessionRow(session: s)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) { pendingDelete = s } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
                .contextMenu {
                    Button { UIPasteboard.general.string = s.tmuxAttachCommand } label: {
                        Label("Copy tmux attach", systemImage: "terminal")
                    }
                    Button(role: .destructive) { pendingDelete = s } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
        .listStyle(.plain)
        .refreshable { await store.refresh() }
        .overlay {
            if store.sessions.isEmpty && store.listError == nil {
                ContentUnavailableView {
                    Label("No chats yet", systemImage: "bubble.left.and.text.bubble.right")
                } description: {
                    Text("Start a session with Claude Code, Codex or any harness on your box.")
                }
            }
        }
    }

    private var newChatButton: some View {
        Button {
            Haptics.tap()
            showNew = true
        } label: {
            Label("New chat", systemImage: "plus")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }
}

private struct OfflineBanner: View {
    let message: String
    let lastSync: Date?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "wifi.exclamationmark")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(message).font(.footnote.weight(.medium))
                if let lastSync {
                    Text("Showing cached chats from \(lastSync.formatted(.relative(presentation: .named)))")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Showing cached chats").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
