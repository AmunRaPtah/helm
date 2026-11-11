import SwiftUI

struct SessionRow: View {
    let session: Session

    var body: some View {
        let style = HarnessStyle.of(session.harness)
        let exited = session.state == .exited
        HStack(alignment: .top, spacing: 12) {
            HarnessBadge(harness: session.harness, size: 40)
                .saturation(exited ? 0.35 : 1)
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(session.displayTitle)
                        .font(HelmFont.rowTitle)
                        .tracking(-0.2)
                        .foregroundStyle(exited ? HelmColor.textSecondary : HelmColor.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Text(RelativeTime.string(session.updatedDate))
                        .font(HelmFont.mono(.caption2))
                        .foregroundStyle(HelmColor.textTertiary)
                        .monospacedDigit()
                }
                HStack(spacing: 6) {
                    Text(style.shortName)
                        .font(.system(.caption, weight: .semibold))
                        .foregroundStyle(style.color.opacity(exited ? 0.6 : 1))
                    if let p = session.profile, !p.isEmpty {
                        MonoTag(text: p)
                    }
                    Spacer(minLength: 4)
                    StatePill(state: session.state)
                }
                if !session.cwd.isEmpty {
                    Text(session.cwd)
                        .font(HelmFont.mono(.caption2))
                        .foregroundStyle(HelmColor.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

struct StateDot: View {
    let state: SessionState

    var body: some View {
        PulseDot(color: state.tint, size: 6, isActive: state.isLive)
            .accessibilityLabel(state.rawValue)
    }
}

enum RelativeTime {
    private static let formatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    static func string(_ date: Date) -> String {
        let secs = Date().timeIntervalSince(date)
        if secs < 45 { return "now" }
        if secs > 6 * 86400 { return date.formatted(.dateTime.month(.abbreviated).day()) }
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
