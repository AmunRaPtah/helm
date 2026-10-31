import SwiftUI

/// All tmux sessions on the box. Tap to view the live pane; swipe to kill.
struct TmuxListView: View {
    @Environment(AppStore.self) private var store
    @State private var sessions: [TmuxSession] = []
    @State private var error: String?

    var body: some View {
        List {
            if let error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            ForEach(sessions) { s in
                NavigationLink {
                    TmuxCaptureView(name: s.name)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: s.isHelm ? "bubble.left.and.text.bubble.right" : "rectangle.split.3x1")
                            .foregroundStyle(s.isHelm ? Color.accentColor : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.name).font(.subheadline.weight(.medium)).monospaced()
                            Text("\(s.windows) window\(s.windows == 1 ? "" : "s")\(s.attached ? " · attached" : "")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .swipeActions {
                    Button("Kill", role: .destructive) { kill(s.name) }
                }
            }
        }
        .navigationTitle("tmux")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        do { sessions = try await store.api.boxTmux(); error = nil }
        catch { self.error = APIClient.describe(error) }
    }

    private func kill(_ name: String) {
        Task {
            Haptics.tap()
            try? await store.api.boxTmuxKill(name)
            await load()
        }
    }
}

/// Live pane capture for one tmux session, with a key-send bar.
struct TmuxCaptureView: View {
    @Environment(AppStore.self) private var store
    let name: String

    @State private var text = ""
    @State private var keys = ""
    @State private var error: String?
    @State private var autoRefresh = true

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    Text(text.isEmpty ? "…" : text)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(12)
                        .id("bottom")
                }
                .onChange(of: text) { _, _ in
                    withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.orange).padding(.horizontal)
            }
            HStack(spacing: 8) {
                TextField("send keys…", text: $keys)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onSubmit(send)
                Button { send() } label: { Image(systemName: "paperplane.fill") }
                    .disabled(keys.isEmpty)
            }
            .padding(10)
            .background(.bar)
        }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button { autoRefresh.toggle() } label: {
                Image(systemName: autoRefresh ? "pause.circle" : "play.circle")
            }
        }
        .task(id: autoRefresh) {
            while !Task.isCancelled && autoRefresh {
                await load()
                try? await Task.sleep(nanoseconds: 2_500_000_000)
            }
            if !autoRefresh { await load() }
        }
    }

    private func load() async {
        do { text = try await store.api.boxTmuxCapture(name, lines: 300); error = nil }
        catch is CancellationError {}
        catch { self.error = APIClient.describe(error) }
    }

    private func send() {
        let k = keys
        keys = ""
        Task {
            Haptics.tap()
            do { try await store.api.boxTmuxSend(name, keys: k) }
            catch { self.error = APIClient.describe(error) }
            try? await Task.sleep(nanoseconds: 400_000_000)
            await load()
        }
    }
}
