import SwiftUI

struct ChatItemView: View {
    let item: ChatItem
    let accent: Color
    let isLive: Bool

    var body: some View {
        switch item.kind {
        case .user(let text, let attachments):
            UserBubble(text: text, attachments: attachments, accent: accent)
                .contextMenu { copyButton }
        case .assistant(let text, _):
            MarkdownView(text: text)
                .padding(.vertical, 2)
                .contentShape(Rectangle())
                .contextMenu { copyButton }
        case .thinking(let text):
            ThinkingBlock(text: text)
                .contextMenu { copyButton }
        case .tool(let call):
            ToolCallCard(call: call, isLive: isLive)
                .contextMenu { copyButton }
        case .system(let s):
            SystemLineView(item: s)
                .contextMenu { copyButton }
        }
    }

    private var copyButton: some View {
        Button {
            UIPasteboard.general.string = item.copyText
            Haptics.tap()
        } label: { Label("Copy", systemImage: "doc.on.doc") }
    }
}

struct UserBubble: View {
    let text: String
    let attachments: [String]
    let accent: Color
    var dimmed = false

    var body: some View {
        HStack {
            Spacer(minLength: 48)
            VStack(alignment: .trailing, spacing: 6) {
                if !attachments.isEmpty {
                    ForEach(attachments, id: \.self) { a in
                        Label((a as NSString).lastPathComponent, systemImage: "paperclip")
                            .font(HelmFont.mono(.caption2, weight: .medium))
                            .foregroundStyle(HelmColor.textSecondary)
                            .lineLimit(1)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(HelmColor.raised))
                            .overlay(Capsule().strokeBorder(HelmColor.hairline, lineWidth: 1))
                    }
                }
                if !text.isEmpty {
                    Text(InlineText.attributed(text))
                        .foregroundStyle(HelmColor.textPrimary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background {
                            UnevenRoundedRectangle(topLeadingRadius: 18, bottomLeadingRadius: 18,
                                                   bottomTrailingRadius: 6, topTrailingRadius: 18, style: .continuous)
                                .fill(LinearGradient(colors: [HelmColor.raisedHigh, HelmColor.raised],
                                                     startPoint: .top, endPoint: .bottom))
                        }
                        .overlay {
                            UnevenRoundedRectangle(topLeadingRadius: 18, bottomLeadingRadius: 18,
                                                   bottomTrailingRadius: 6, topTrailingRadius: 18, style: .continuous)
                                .stroke(HelmColor.hairlineStrong, lineWidth: 1)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .opacity(dimmed ? 0.6 : 1)
        }
    }
}

struct PendingBubble: View {
    let message: PendingMessage
    let accent: Color
    var onRetry: () -> Void
    var onDiscard: () -> Void
    var onCancel: () -> Void = {}

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            UserBubble(text: message.text, attachments: message.attachments, accent: accent, dimmed: true)
            if message.failed {
                HStack(spacing: 12) {
                    Label("Not sent", systemImage: "exclamationmark.circle.fill").foregroundStyle(HelmColor.red)
                    Button("Retry") { Haptics.tap(); onRetry() }
                        .foregroundStyle(HelmColor.lime)
                    Button("Discard", role: .destructive, action: onDiscard)
                        .foregroundStyle(HelmColor.textSecondary)
                }
                .font(.system(.caption, weight: .medium))
                .buttonStyle(.borderless)
            } else if message.queueId != nil {
                HStack(spacing: 12) {
                    HStack(spacing: 5) {
                        PulseDot(color: HelmColor.amber, size: 5, isActive: true)
                        Text("QUEUED").font(.system(size: 10, weight: .semibold, design: .monospaced)).tracking(0.6)
                    }
                    .foregroundStyle(HelmColor.amber)
                    Button("Cancel", role: .destructive, action: onCancel)
                        .foregroundStyle(HelmColor.textSecondary)
                }
                .font(.system(.caption, weight: .medium))
                .buttonStyle(.borderless)
            } else {
                Text("Sending\u{2026}")
                    .font(HelmFont.mono(.caption2))
                    .foregroundStyle(HelmColor.textTertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

struct ThinkingBlock: View {
    let text: String
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                Haptics.tap()
                withHelmAnimation { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "brain")
                        .imageScale(.small)
                    Text("THINKING")
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        .tracking(0.8)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Spacer()
                }
                .foregroundStyle(HelmColor.textTertiary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Group {
                if expanded {
                    Text(text)
                        .font(.footnote)
                        .italic()
                        .foregroundStyle(HelmColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity)
                } else if let first = text.split(separator: "\n").first {
                    Text(first)
                        .font(.footnote)
                        .foregroundStyle(HelmColor.textTertiary)
                        .lineLimit(1)
                        .transition(.opacity)
                }
            }
            .padding(.leading, 10)
            .overlay(alignment: .leading) {
                Rectangle().fill(HelmColor.hairlineStrong).frame(width: 1.5)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint(expanded ? "Collapse" : "Expand")
    }
}

struct SystemLineView: View {
    let item: SystemItem

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
            Text(item.text)
                .multilineTextAlignment(.center)
        }
        .font(HelmFont.mono(.caption2, weight: item.style == .error ? .medium : .regular))
        .foregroundStyle(item.style == .error ? HelmColor.red : HelmColor.textTertiary)
        .padding(.horizontal, item.style == .error ? 10 : 0)
        .padding(.vertical, item.style == .error ? 6 : 0)
        .background {
            if item.style == .error {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(HelmColor.red.opacity(0.10))
                RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(HelmColor.red.opacity(0.3), lineWidth: 0.75)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var symbol: String {
        switch item.style {
        case .info: return "info.circle"
        case .status: return "circle.dashed"
        case .usage: return "gauge.with.dots.needle.33percent"
        case .error: return "exclamationmark.triangle.fill"
        }
    }
}
