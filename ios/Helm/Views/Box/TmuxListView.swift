import SwiftUI

/// All tmux sessions on the box. Tap to view the live pane; swipe to kill.
/// The top section controls helmd's reaper, which kills idle sessions on its own.
struct TmuxListView: View {
    @Environment(AppStore.self) private var store
    @State private var sessions: [TmuxSession] = []
    @State private var reaper: ReaperState?
    @State private var error: String?
    @State private var loaded = false

    var body: some View {
        List {
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(HelmColor.amber)
                    .helmRow()
            }
            if let r = reaper {
                reaperSection(r)
            }
            if !loaded && sessions.isEmpty && error == nil {
                ForEach(0..<4, id: \.self) { _ in SkeletonRow().helmRow() }
            }
            if loaded && sessions.isEmpty && error == nil {
                HelmEmptyState(title: "No tmux sessions",
                               message: "Nothing is running in tmux on the box right now.",
                               systemImage: "rectangle.split.3x1")
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            Section {
                ForEach(sessions) { s in
                    NavigationLink {
                        TmuxCaptureView(name: s.name)
                    } label: {
                        sessionLabel(s)
                    }
                    .swipeActions {
                        Button("Kill", role: .destructive) { kill(s.name) }
                    }
                    .helmRow()
                }
            } header: {
                if !sessions.isEmpty {
                    HelmSectionHeader(title: "Sessions", trailing: "\(sessions.count)")
                }
            }
        }
        .helmScreen()
        .navigationTitle("tmux")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
    }

    private func reaperSection(_ r: ReaperState) -> some View {
        Section {
            Toggle("Auto-kill idle sessions", isOn: Binding(
                get: { r.enabled },
                set: { v in saveReaper(enabled: v) }))
                .tint(HelmColor.lime)
                .helmRow()
            Stepper(value: Binding(
                get: { r.idleHours },
                set: { v in saveReaper(idleHours: v) }), in: 1...336, step: 1) {
                HStack(spacing: 4) {
                    Text("After")
                    Text("\(Int(r.idleHours))h")
                        .font(HelmFont.mono(.body, weight: .medium))
                        .monospacedDigit()
                    Text("idle")
                }
            }
            .helmRow()
            Toggle("Include non-Helm sessions", isOn: Binding(
                get: { r.includeNonHelm },
                set: { v in saveReaper(includeNonHelm: v) }))
                .tint(HelmColor.lime)
                .helmRow()
            Button(role: .destructive) { runReaper() } label: {
                Text(r.candidates.isEmpty ? "No stale sessions" : "Kill \(r.candidates.count) stale now")
                    .foregroundStyle(r.candidates.isEmpty ? HelmColor.textTertiary : HelmColor.red)
            }
            .disabled(r.candidates.isEmpty)
            .helmRow()
        } header: {
            HelmSectionHeader(title: "Auto-kill")
        } footer: {
            Text("Checked every 15 min. Attached sessions and \"main\" are never killed. Killed chats can be resumed.")
                .foregroundStyle(HelmColor.textTertiary)
        }
    }

    private func sessionLabel(_ s: TmuxSession) -> some View {
        HStack(spacing: HelmSpace.md) {
            Image(systemName: s.isHelm ? "bubble.left.and.text.bubble.right" : "rectangle.split.3x1")
                .font(.callout)
                .foregroundStyle(s.isHelm ? HelmColor.lime : HelmColor.textTertiary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(s.name)
                    .font(HelmFont.mono(.subheadline, weight: .medium))
                    .foregroundStyle(HelmColor.textPrimary)
                Text("\(s.windows) window\(s.windows == 1 ? "" : "s")\(s.attached ? " · attached" : "")\(s.idleLabel.map { " · " + $0 } ?? "")")
                    .font(HelmFont.mono(.caption2))
                    .foregroundStyle(HelmColor.textTertiary)
            }
        }
        .padding(.vertical, 2)
    }

    private func load() async {
        do {
            sessions = try await store.api.boxTmux()
            reaper = try await store.api.boxReaper()
            error = nil
        }
        catch { self.error = APIClient.describe(error) }
        loaded = true
    }

    private func saveReaper(enabled: Bool? = nil, idleHours: Double? = nil, includeNonHelm: Bool? = nil) {
        guard let r = reaper else { return }
        Task {
            Haptics.tap()
            do {
                reaper = try await store.api.boxReaperSet(
                    enabled: enabled ?? r.enabled,
                    idleHours: idleHours ?? r.idleHours,
                    includeNonHelm: includeNonHelm ?? r.includeNonHelm)
            } catch { self.error = APIClient.describe(error) }
        }
    }

    private func runReaper() {
        Task {
            Haptics.tap()
            do { reaper = try await store.api.boxReaperRun() }
            catch { self.error = APIClient.describe(error) }
            await load()
        }
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
    @State private var follower = BottomFollower()

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                GeometryReader { outer in
                    ScrollView {
                        VStack(spacing: 0) {
                            Text(text.isEmpty ? "…" : text)
                                .font(HelmFont.mono(.caption))
                                .foregroundStyle(text.isEmpty ? HelmColor.textTertiary : HelmColor.textPrimary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                                .padding(HelmSpace.md)
                            BottomFollowSentinel()
                                .id("bottom")
                        }
                        .coordinateSpace(name: bottomFollowContent)
                    }
                    .coordinateSpace(name: bottomFollowViewport)
                    .startsAtBottom()
                    .background(HelmColor.obsidian)
                    .onPreferenceChange(BottomFollowKey.self) { m in
                        follower.update(m, viewport: outer.size.height)
                    }
                    .onChange(of: text) { _, _ in
                        // Only follow new output if the user is at the bottom.
                        guard follower.following else { return }
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
            }
            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(HelmColor.amber)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, HelmSpace.md)
                    .padding(.vertical, HelmSpace.xs)
            }
            sendBar
        }
        .background(HelmColor.obsidian.ignoresSafeArea())
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button { Haptics.tap(); autoRefresh.toggle() } label: {
                HStack(spacing: 6) {
                    if autoRefresh { PulseDot(color: HelmColor.lime, size: 6) }
                    Image(systemName: autoRefresh ? "pause.circle" : "play.circle")
                        .foregroundStyle(autoRefresh ? HelmColor.lime : HelmColor.textSecondary)
                }
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

    private var sendBar: some View {
        HStack(spacing: HelmSpace.sm) {
            Text("›")
                .font(HelmFont.mono(.body, weight: .bold))
                .foregroundStyle(HelmColor.lime)
            TextField("send keys…", text: $keys)
                .font(HelmFont.mono(.callout))
                .foregroundStyle(HelmColor.textPrimary)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .onSubmit(send)
            Button { send() } label: {
                Image(systemName: "paperplane.fill")
                    .foregroundStyle(keys.isEmpty ? HelmColor.textTertiary : HelmColor.lime)
            }
            .disabled(keys.isEmpty)
        }
        .padding(.horizontal, HelmSpace.md)
        .padding(.vertical, 10)
        .helmCard(radius: HelmRadius.control, fill: HelmColor.raised)
        .padding(.horizontal, HelmSpace.sm)
        .padding(.vertical, HelmSpace.sm)
        .background(HelmColor.surface)
        .overlay(alignment: .top) {
            Rectangle().fill(HelmColor.hairline).frame(height: 1)
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
