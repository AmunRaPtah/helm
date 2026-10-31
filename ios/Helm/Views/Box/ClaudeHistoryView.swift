import SwiftUI

/// Recent Claude Code sessions on the box, newest first. Tap for a transcript tail.
struct ClaudeHistoryView: View {
    @Environment(AppStore.self) private var store
    @State private var sessions: [ClaudeSessionRef] = []
    @State private var error: String?

    var body: some View {
        List {
            if let error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            ForEach(sessions) { s in
                NavigationLink {
                    ClaudeTranscriptView(ref: s)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(s.summary.isEmpty ? "(no summary)" : s.summary)
                            .font(.subheadline).lineLimit(2)
                        HStack(spacing: 6) {
                            Image(systemName: "folder").font(.caption2)
                            Text(s.projectLabel).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Text(relative(s.modified)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Claude history")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        do { sessions = try await store.api.boxClaudeSessions(limit: 60); error = nil }
        catch { self.error = APIClient.describe(error) }
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
            LazyVStack(alignment: .leading, spacing: 14) {
                if loading { ProgressView().frame(maxWidth: .infinity) }
                if let error { Text(error).foregroundStyle(.orange) }
                ForEach(turns) { t in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(t.role.uppercased())
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(t.role == "user" ? Color.accentColor : .secondary)
                        Text(t.text)
                            .font(.callout)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .padding(10)
                    .background(t.role == "user" ? Color.accentColor.opacity(0.08) : Color.secondary.opacity(0.08),
                                in: RoundedRectangle(cornerRadius: 10))
                }
            }
            .padding()
        }
        .navigationTitle(ref.projectLabel)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            loading = true
            do { turns = try await store.api.boxClaudeTranscript(project: ref.project, id: ref.id, tail: 80) }
            catch { self.error = APIClient.describe(error) }
            loading = false
        }
    }
}
