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
                            .font(.caption)
                            .lineLimit(1)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color(.tertiarySystemFill), in: Capsule())
                    }
                }
                if !text.isEmpty {
                    Text(InlineText.attributed(text))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(accent.opacity(0.22), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
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

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            UserBubble(text: message.text, attachments: message.attachments, accent: accent, dimmed: true)
            if message.failed {
                HStack(spacing: 12) {
                    Text("Not sent").foregroundStyle(.red)
                    Button("Retry", action: onRetry)
                    Button("Discard", role: .destructive, action: onDiscard)
                }
                .font(.caption)
                .buttonStyle(.borderless)
            } else {
                Text("Sending\u{2026}").font(.caption2).foregroundStyle(.secondary)
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
                withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "brain")
                    Text("Thinking")
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Spacer()
                }
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                Text(text)
                    .font(.footnote)
                    .italic()
                    .foregroundStyle(.secondary)
                    .padding(.leading, 10)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(.quaternary).frame(width: 2)
                    }
                    .fixedSize(horizontal: false, vertical: true)
            } else if let first = text.split(separator: "\n").first {
                Text(first)
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
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
        .font(.caption)
        .foregroundStyle(item.style == .error ? AnyShapeStyle(Color.red) : AnyShapeStyle(.secondary))
        .padding(.horizontal, item.style == .error ? 10 : 0)
        .padding(.vertical, item.style == .error ? 6 : 0)
        .background {
            if item.style == .error {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.red.opacity(0.12))
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
