import SwiftUI

struct SessionRow: View {
    let session: Session

    var body: some View {
        HStack(spacing: 12) {
            HarnessBadge(harness: session.harness, size: 40)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(session.displayTitle)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                        .foregroundStyle(session.state == .exited ? .secondary : .primary)
                    Spacer(minLength: 6)
                    Text(RelativeTime.string(session.updatedDate))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                HStack(spacing: 6) {
                    StateDot(state: session.state)
                    Text(HarnessStyle.of(session.harness).shortName)
                        .foregroundStyle(HarnessStyle.of(session.harness).color)
                    if let p = session.profile, !p.isEmpty {
                        Text(p).foregroundStyle(.secondary)
                    }
                    if !session.cwd.isEmpty {
                        Image(systemName: "folder").imageScale(.small).foregroundStyle(.tertiary)
                        Text(session.cwdBasename).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .font(.caption)
            }
        }
        .padding(.vertical, 4)
        .opacity(session.state == .exited ? 0.7 : 1)
    }
}

struct StateDot: View {
    let state: SessionState

    var body: some View {
        Image(systemName: "circle.fill")
            .font(.system(size: 7))
            .foregroundStyle(color)
            .symbolEffect(.pulse, options: .repeating, isActive: state == .running || state == .starting)
            .accessibilityLabel(state.rawValue)
    }

    private var color: Color {
        switch state {
        case .running, .starting: return .green
        case .idle: return .blue
        case .exited, .unknown: return .gray.opacity(0.6)
        }
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
