import SwiftUI

struct ChatTitle: View {
    let session: Session
    let state: SessionState
    let phase: SessionStream.Phase

    var body: some View {
        VStack(spacing: 1) {
            Text(session.displayTitle)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            HStack(spacing: 4) {
                StateDot(state: state)
                Text(subtitle)
                    .lineLimit(1)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: 240)
    }

    private var subtitle: String {
        switch phase {
        case .connecting: return "Connecting\u{2026}"
        case .waiting(let s): return "Offline, retrying in \(s)s"
        case .idle, .live:
            let h = HarnessStyle.of(session.harness).shortName
            let p = session.profile.map { " (\($0))" } ?? ""
            return session.cwd.isEmpty ? h + p : "\(h)\(p) \u{00B7} \(session.cwdBasename)"
        }
    }
}

struct EmptyChatHeader: View {
    let session: Session

    var body: some View {
        VStack(spacing: 10) {
            HarnessBadge(harness: session.harness, size: 56)
            Text(HarnessStyle.of(session.harness).shortName)
                .font(.headline)
            Text(session.cwd)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            Text("Session \(session.id) \u{00B7} \(session.permission)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}

struct TypingIndicator: View {
    let color: Color
    @State private var animate = false

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3) { i in
                Circle()
                    .fill(color)
                    .frame(width: 7, height: 7)
                    .opacity(animate ? 1 : 0.3)
                    .animation(.easeInOut(duration: 0.6).repeatForever().delay(Double(i) * 0.2), value: animate)
            }
        }
        .padding(.vertical, 6)
        .onAppear { animate = true }
        .accessibilityLabel("Working")
    }
}

struct JumpToBottomButton: View {
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.down")
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 38, height: 38)
                .background(.regularMaterial, in: Circle())
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.1)))
                .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Jump to bottom")
    }
}

struct ResumeBanner: View {
    let isResuming: Bool
    var action: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "moon.zzz.fill").foregroundStyle(.secondary)
            Text("This session has exited.")
                .font(.subheadline)
            Spacer()
            Button(action: action) {
                if isResuming { ProgressView() } else { Text("Resume").fontWeight(.semibold) }
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.small)
            .disabled(isResuming)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

struct ErrorBanner: View {
    let text: String
    var onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(text).font(.footnote)
            Spacer()
            Button(action: onDismiss) { Image(systemName: "xmark").font(.caption.weight(.bold)) }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.12))
    }
}
