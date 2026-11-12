import SwiftUI

struct ChatView: View {
    @Bindable var model: ChatModel

    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @State private var follower = BottomFollower()
    @State private var renaming = false
    @State private var renameText = ""
    @State private var confirmDelete = false
    @State private var copiedTmux = false

    private var accent: Color { HarnessStyle.of(model.session.harness).color }

    var body: some View {
        ScrollViewReader { proxy in
            GeometryReader { outer in
                ScrollView {
                    VStack(spacing: 0) {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if model.transcript.isEmpty && model.pending.isEmpty {
                            EmptyChatHeader(session: model.session)
                        }
                        ForEach(model.transcript.items) { item in
                            ChatItemView(item: item, accent: accent, isLive: model.isRunning)
                                .id(item.id)
                                .transition(HelmMotion.appear)
                        }
                        ForEach(model.pending) { p in
                            PendingBubble(message: p, accent: accent, reconnecting: model.isReconnecting,
                                          onRetry: { Task { await model.retry(p) } },
                                          onDiscard: { model.discard(p) },
                                          onCancel: { Task { await model.cancelQueued(p) } })
                            .transition(HelmMotion.appear)
                        }
                        if model.isRunning {
                            TypingIndicator(color: accent,
                                            label: model.isReconnecting ? startingLabel : "Working",
                                            reconnecting: model.isReconnecting)
                                .transition(HelmMotion.appear)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 8)
                    .helmAnimation(HelmMotion.spring, value: model.transcript.items.count)
                    .helmAnimation(HelmMotion.spring, value: model.pending.count)
                    .helmAnimation(HelmMotion.spring, value: model.isRunning)
                    .helmAnimation(HelmMotion.spring, value: model.isReconnecting)
                    // Outside the LazyVStack so it is never unloaded when the
                    // user scrolls far up.
                    BottomFollowSentinel()
                        .id("bottom")
                    }
                    .coordinateSpace(name: bottomFollowContent)
                }
                .helmScreen()
                .coordinateSpace(name: bottomFollowViewport)
                .startsAtBottom()
                .scrollDismissesKeyboard(.interactively)
                .onPreferenceChange(BottomFollowKey.self) { m in
                    follower.update(m, viewport: outer.size.height)
                }
                .onChange(of: model.pending.count) { old, new in
                    // Sending a message always brings the user back down.
                    if new > old { follower.following = true }
                }
                .onChange(of: scrollKey) {
                    guard follower.following else { return }
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
                .onAppear {
                    Task {
                        try? await Task.sleep(nanoseconds: 60_000_000)
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
                .overlay(alignment: .bottom) {
                    if !follower.following {
                        JumpToBottomButton {
                            Haptics.tap()
                            follower.following = true
                            withHelmAnimation(HelmMotion.spring) { proxy.scrollTo("bottom", anchor: .bottom) }
                        }
                        .padding(.bottom, 10)
                        .transition(.scale.combined(with: .opacity))
                    }
                }
                .helmAnimation(HelmMotion.spring, value: follower.following)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                if model.isExited {
                    ResumeBanner(isResuming: model.isResuming) { Haptics.tap(); Task { await model.resume() } }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                if let banner = model.banner {
                    ErrorBanner(text: banner) { model.banner = nil }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                ComposerView(model: model, accent: accent)
            }
            .helmAnimation(HelmMotion.spring, value: model.isExited)
            .helmAnimation(HelmMotion.spring, value: model.banner)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(HelmColor.obsidian.opacity(0.85), for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                ChatTitle(session: model.session, state: model.state, phase: model.stream.phase)
            }
            ToolbarItem(placement: .topBarTrailing) { menu }
        }
        .sensoryFeedback(.success, trigger: model.turnCompletions)
        .onAppear {
            model.start()
            Task { await model.refreshSession() }
        }
        .onDisappear { model.stop() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.start() } else if phase == .background { model.stop() }
        }
        .alert("Rename chat", isPresented: $renaming) {
            TextField("Title", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                let t = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !t.isEmpty else { return }
                Task {
                    do { try await store.rename(model.session.id, to: t) }
                    catch { model.banner = APIClient.describe(error) }
                }
            }
        }
        .confirmationDialog("Delete this chat?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                Task {
                    await store.delete(model.session.id)
                    dismiss()
                }
            }
        } message: {
            Text("Kills tmux session \(model.session.tmux). Files on the box are kept.")
        }
    }

    /// "Reconnecting to Claude…" when helmd revives a dead runner; "Starting" for a new chat.
    private var startingLabel: String {
        let verb = model.transcript.isEmpty ? "Starting" : "Reconnecting to"
        return "\(verb) \(HarnessStyle.of(model.session.harness).shortName)\u{2026}"
    }

    private var scrollKey: String {
        let last = model.transcript.items.last
        let len = last.map { $0.copyText.count } ?? 0
        return "\(model.transcript.items.count)-\(len)-\(model.pending.count)-\(model.pending.filter { $0.queueId != nil }.count)-\(model.isRunning)"
    }

    private var menu: some View {
        Menu {
            Button {
                renameText = model.session.title
                renaming = true
            } label: { Label("Rename", systemImage: "pencil") }
            Button {
                UIPasteboard.general.string = model.session.tmuxAttachCommand
                Haptics.tap()
            } label: { Label("Copy tmux attach", systemImage: "terminal") }
            Button {
                UIPasteboard.general.string = model.session.cwd
            } label: { Label("Copy working directory", systemImage: "folder") }
            if model.isRunning {
                Button { Task { await model.interrupt() } } label: { Label("Interrupt", systemImage: "stop.circle") }
            }
            if model.isExited {
                Button { Task { await model.resume() } } label: { Label("Resume", systemImage: "play.circle") }
            }
            Divider()
            Button(role: .destructive) { confirmDelete = true } label: { Label("Delete", systemImage: "trash") }
        } label: {
            Image(systemName: "ellipsis.circle")
                .foregroundStyle(HelmColor.textSecondary)
        }
    }
}

