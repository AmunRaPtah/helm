import SwiftUI

struct ChatTitle: View {
    let session: Session
    let state: SessionState
    let phase: SessionStream.Phase

    var body: some View {
        VStack(spacing: 2) {
            Text(session.displayTitle)
                .font(.system(.subheadline, weight: .semibold))
                .tracking(-0.1)
                .foregroundStyle(HelmColor.textPrimary)
                .lineLimit(1)
            HStack(spacing: 5) {
                StateDot(state: displayState)
                Text(subtitle)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .contentTransition(.opacity)
            }
            .font(HelmFont.mono(.caption2))
            .foregroundStyle(subtitleColor)
            .helmAnimation(HelmMotion.spring, value: subtitle)
        }
        .frame(maxWidth: 240)
        .accessibilityElement(children: .combine)
    }

    private var displayState: SessionState {
        switch phase {
        case .connecting, .waiting: return .starting
        case .idle, .live: return state
        }
    }

    private var subtitleColor: Color {
        switch phase {
        case .waiting: return HelmColor.amber
        default: return HelmColor.textSecondary
        }
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
    @State private var shown = false

    var body: some View {
        let style = HarnessStyle.of(session.harness)
        VStack(spacing: 14) {
            ZStack {
                RadialGradient(colors: [style.color.opacity(0.22), .clear], center: .center, startRadius: 0, endRadius: 70)
                    .frame(width: 150, height: 150)
                HarnessBadge(harness: session.harness, size: 60)
            }
            .frame(height: 96)
            VStack(spacing: 6) {
                Text(style.shortName)
                    .font(.system(.title3, weight: .bold))
                    .tracking(-0.3)
                    .foregroundStyle(HelmColor.textPrimary)
                if !session.cwd.isEmpty {
                    Text(session.cwd)
                        .font(HelmFont.mono(.caption))
                        .foregroundStyle(HelmColor.textSecondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .multilineTextAlignment(.center)
                }
            }
            HStack(spacing: 6) {
                MonoTag(text: session.id, systemImage: "number")
                MonoTag(text: session.permission, systemImage: "lock.open")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 44)
        .opacity(shown ? 1 : 0)
        .scaleEffect(shown ? 1 : 0.97)
        .onAppear { withHelmAnimation(HelmMotion.gentle) { shown = true } }
    }
}

/// "Working" indicator shown while the agent runs.
struct TypingIndicator: View {
    let color: Color

    var body: some View {
        ThinkingIndicator(color: HelmColor.lime, label: "Working")
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct JumpToBottomButton: View {
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.down")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(HelmColor.textPrimary)
                .frame(width: 38, height: 38)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().strokeBorder(HelmColor.hairlineStrong, lineWidth: 1))
                .shadow(color: .black.opacity(0.45), radius: 10, y: 4)
        }
        .buttonStyle(HelmPressStyle())
        .accessibilityLabel("Jump to bottom")
    }
}

struct ResumeBanner: View {
    let isResuming: Bool
    var action: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "moon.zzz.fill")
                .foregroundStyle(HelmColor.textTertiary)
            VStack(alignment: .leading, spacing: 1) {
                Text("Session exited")
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(HelmColor.textPrimary)
                Text("Resume to continue where it left off.")
                    .font(.caption)
                    .foregroundStyle(HelmColor.textSecondary)
            }
            Spacer()
            Button(action: action) {
                Group {
                    if isResuming {
                        ProgressView().tint(HelmColor.onLime)
                    } else {
                        Label("Resume", systemImage: "play.fill")
                    }
                }
                .font(.system(.subheadline, weight: .semibold))
            }
            .buttonStyle(HelmPrimaryButtonStyle(fullWidth: false))
            .controlSize(.small)
            .disabled(isResuming)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(HelmColor.surface.opacity(0.92))
        .overlay(alignment: .top) { Rectangle().fill(HelmColor.hairline).frame(height: 1) }
    }
}

struct ErrorBanner: View {
    let text: String
    var onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(HelmColor.amber)
            Text(text)
                .font(.footnote)
                .foregroundStyle(HelmColor.textPrimary)
            Spacer()
            Button(action: onDismiss) {
                Image(systemName: "xmark").font(.caption.weight(.bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(HelmColor.textSecondary)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(HelmColor.amber.opacity(0.10))
        .background(HelmColor.surface)
        .overlay(alignment: .leading) { Rectangle().fill(HelmColor.amber).frame(width: 2) }
    }
}
