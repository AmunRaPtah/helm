import SwiftUI

/// Recent Claude Code sessions on the box, newest first. Tap for a transcript tail.
struct ClaudeHistoryView: View {
    @Environment(AppStore.self) private var store
    @State private var sessions: [ClaudeSessionRef] = []
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
            if !loaded && sessions.isEmpty && error == nil {
                ForEach(0..<6, id: \.self) { _ in SkeletonRow().helmRow() }
            }
            if loaded && sessions.isEmpty && error == nil {
                HelmEmptyState(title: "No Claude sessions",
                               message: "Claude Code sessions on the box will appear here.",
                               systemImage: "clock.arrow.circlepath")
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            ForEach(sessions) { s in
                NavigationLink {
                    ClaudeTranscriptView(ref: s)
                } label: {
                    sessionLabel(s)
                }
                .helmRow()
            }
        }
        .helmScreen()
        .navigationTitle("Claude history")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
    }

    private func sessionLabel(_ s: ClaudeSessionRef) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(s.summary.isEmpty ? "(no summary)" : s.summary)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(s.summary.isEmpty ? HelmColor.textTertiary : HelmColor.textPrimary)
                .lineLimit(2)
            HStack(spacing: 6) {
                MonoTag(text: s.projectLabel, systemImage: "folder")
                Spacer()
                Text(relative(s.modified))
                    .font(HelmFont.mono(.caption2))
                    .foregroundStyle(HelmColor.textTertiary)
            }
        }
        .padding(.vertical, 2)
    }

    private func load() async {
        do { sessions = try await store.api.boxClaudeSessions(limit: 60); error = nil }
        catch { self.error = APIClient.describe(error) }
        loaded = true
    }

    private func relative(_ ts: Double) -> String {
        guard ts > 0 else { return "" }
        let date = Date(timeIntervalSince1970: ts)
        return RelativeDateTimeFormatter().localizedString(for: date, relativeTo: Date())
    }
}

/// Read-only transcript tail for one Claude Code session.
struct ClaudeTranscriptView: View {
    @Environment(AppStore.self) private var store
    let ref: ClaudeSessionRef

    @State private var turns: [ClaudeTurn] = []
    @State private var error: String?
    @State private var loading = true

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: HelmSpace.md) {
                if loading {
                    ForEach(0..<4, id: \.self) { _ in turnSkeleton }
                }
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(HelmColor.amber)
                }
                ForEach(turns) { t in
                    turnCard(t)
                }
            }
            .padding()
        }
        .helmScreen()
        .navigationTitle(ref.projectLabel)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            loading = true
            do { turns = try await store.api.boxClaudeTranscript(project: ref.project, id: ref.id, tail: 80) }
            catch { self.error = APIClient.describe(error) }
            loading = false
        }
    }

    private var turnSkeleton: some View {
        VStack(alignment: .leading, spacing: 8) {
            SkeletonBlock(width: 44, height: 8)
            SkeletonBlock(height: 11)
            SkeletonBlock(width: 200, height: 11)
        }
        .padding(HelmSpace.md)
        .helmCard()
        .accessibilityHidden(true)
    }

    private func turnCard(_ t: ClaudeTurn) -> some View {
        let isUser = t.role == "user"
        return VStack(alignment: .leading, spacing: 6) {
            Text(t.role.uppercased())
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .tracking(0.8)
                .foregroundStyle(isUser ? HelmColor.lime : HelmColor.textTertiary)
            Text(t.text)
                .font(.callout)
                .foregroundStyle(HelmColor.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .padding(HelmSpace.md)
        .helmCard(fill: isUser ? HelmColor.raisedHigh : HelmColor.raised,
                  stroke: isUser ? HelmColor.lime.opacity(0.18) : nil)
    }
}
