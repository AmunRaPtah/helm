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
                        Button { Haptics.tap(); showSettings = true } label: { Image(systemName: "gearshape") }
                            .tint(HelmColor.textSecondary)
                            .accessibilityLabel("Settings")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { Haptics.tap(); showNew = true } label: { Image(systemName: "square.and.pencil") }
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
        // A certificate shared into Helm is finished in Settings.
        .onChange(of: CertInbox.shared.pending != nil, initial: true) { _, has in
            if has && !showNew { showSettings = true }
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
            // Keep polling while a chat is open too. If the list only refreshed
            // after coming back, rows would reorder (the chat just used jumps to
            // the top) a moment after the list reappears, and a tap landing
            // during that move opened the wrong chat.
            while !Task.isCancelled {
                await store.refresh()
                try? await Task.sleep(nanoseconds: 4_000_000_000)
            }
        }
        // Coming back from a chat: settle the order now, during the pop
        // animation, before the list can be tapped.
        .onChange(of: path.isEmpty) { _, isEmpty in
            if isEmpty { Task { await store.refresh() } }
        }
    }

    private var isFirstLoad: Bool {
        store.sessions.isEmpty && store.listError == nil && store.lastSync == nil
    }

    @ViewBuilder
    private var list: some View {
        List {
            if let err = store.listError {
                OfflineBanner(message: err, lastSync: store.lastSync)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                    .transition(HelmMotion.appear)
            }
            if isFirstLoad {
                ForEach(0..<5, id: \.self) { _ in
                    SkeletonRow()
                        .listRowBackground(Color.clear)
                        .listRowSeparatorTint(HelmColor.hairline)
                }
            }
            ForEach(store.sessions) { s in
                NavigationLink(value: s.id) {
                    SessionRow(session: s)
                }
                .listRowBackground(Color.clear)
                .listRowSeparatorTint(HelmColor.hairline)
                .alignmentGuide(.listRowSeparatorLeading) { _ in 52 }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) { pendingDelete = s } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .tint(HelmColor.red)
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
            // Room for the floating New chat button.
            Color.clear
                .frame(height: 8)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        }
        .listStyle(.plain)
        .helmScreen()
        .refreshable { await store.refresh() }
        .helmAnimation(HelmMotion.spring, value: store.sessions.map(\.id))
        .helmAnimation(HelmMotion.spring, value: store.listError)
        .overlay {
            if store.sessions.isEmpty && store.listError == nil && !isFirstLoad {
                HelmEmptyState(title: "No chats yet",
                               message: "Start a session with Claude Code, Codex or any harness on your box.")
            }
        }
    }

    private var newChatButton: some View {
        Button {
            Haptics.tap()
            showNew = true
        } label: {
            Label("New chat", systemImage: "plus")
        }
        .buttonStyle(HelmPrimaryButtonStyle())
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background {
            LinearGradient(colors: [HelmColor.obsidian.opacity(0), HelmColor.obsidian.opacity(0.92)],
                           startPoint: .top, endPoint: .center)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        }
    }
}

private struct OfflineBanner: View {
    let message: String
    let lastSync: Date?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "wifi.exclamationmark")
                .foregroundStyle(HelmColor.amber)
            VStack(alignment: .leading, spacing: 2) {
                Text(message).font(.footnote.weight(.medium)).foregroundStyle(HelmColor.textPrimary)
                if let lastSync {
                    Text("Showing cached chats from \(lastSync.formatted(.relative(presentation: .named)))")
                        .font(HelmFont.mono(.caption2)).foregroundStyle(HelmColor.textSecondary)
                } else {
                    Text("Showing cached chats").font(HelmFont.mono(.caption2)).foregroundStyle(HelmColor.textSecondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .helmCard(radius: HelmRadius.control, fill: HelmColor.amber.opacity(0.08), stroke: HelmColor.amber.opacity(0.25))
    }
}
