import SwiftUI

struct ChatView: View {
    @Bindable var model: ChatModel

    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @State private var atBottom = true
    @State private var renaming = false
    @State private var renameText = ""
    @State private var confirmDelete = false
    @State private var copiedTmux = false

    private var accent: Color { HarnessStyle.of(model.session.harness).color }

    var body: some View {
        ScrollViewReader { proxy in
            GeometryReader { outer in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if model.transcript.isEmpty && model.pending.isEmpty {
                            EmptyChatHeader(session: model.session)
                        }
                        ForEach(model.transcript.items) { item in
                            ChatItemView(item: item, accent: accent, isLive: model.isRunning)
                                .id(item.id)
                        }
                        ForEach(model.pending) { p in
                            PendingBubble(message: p, accent: accent,
                                          onRetry: { Task { await model.retry(p) } },
                                          onDiscard: { model.discard(p) },
                                          onCancel: { Task { await model.cancelQueued(p) } })
                        }
                        if model.isRunning {
                            TypingIndicator(color: accent)
                        }
                        BottomSentinel()
                            .id("bottom")
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 8)
                }
                .coordinateSpace(name: "chatScroll")
                .defaultScrollAnchor(.bottom)
                .scrollDismissesKeyboard(.interactively)
                .onPreferenceChange(BottomOffsetKey.self) { maxY in
                    atBottom = maxY <= outer.size.height + 120
                }
                .onChange(of: scrollKey) {
                    guard atBottom else { return }
                    withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                .onAppear {
                    Task {
                        try? await Task.sleep(nanoseconds: 60_000_000)
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
                .overlay(alignment: .bottom) {
                    if !atBottom {
                        JumpToBottomButton {
                            withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("bottom", anchor: .bottom) }
                        }
                        .padding(.bottom, 10)
                        .transition(.scale.combined(with: .opacity))
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: atBottom)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                if model.isExited {
                    ResumeBanner(isResuming: model.isResuming) { Task { await model.resume() } }
                }
                if let banner = model.banner {
                    ErrorBanner(text: banner) { model.banner = nil }
                }
                ComposerView(model: model, accent: accent)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
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
        }
    }
}

private struct BottomOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct BottomSentinel: View {
    var body: some View {
        GeometryReader { g in
            Color.clear.preference(key: BottomOffsetKey.self, value: g.frame(in: .named("chatScroll")).maxY)
        }
        .frame(height: 1)
    }
}
