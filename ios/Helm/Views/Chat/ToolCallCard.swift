import SwiftUI

struct ToolCallCard: View {
    let call: ToolCallItem
    let isLive: Bool
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    statusIcon
                    Text(call.name)
                        .font(.footnote.weight(.semibold).monospaced())
                        .foregroundStyle(call.isError ? .red : .primary)
                    Text(ToolSummary.oneLine(call))
                        .font(.footnote.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    if !call.input.isEmpty { section("Input", call.input) }
                    if let out = call.output {
                        section(call.isError ? "Error" : "Output", out.isEmpty ? "(no output)" : out)
                    }
                }
                .padding(12)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(call.isError ? Color.red.opacity(0.10) : Color(.secondarySystemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(call.isError ? Color.red.opacity(0.5) : Color.primary.opacity(0.06))
        )
    }

    @ViewBuilder
    private var statusIcon: some View {
        if call.isError {
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red).font(.footnote)
        } else if call.output == nil && isLive {
            ProgressView().controlSize(.mini)
        } else {
            Image(systemName: ToolSummary.symbol(call.name)).foregroundStyle(.secondary).font(.footnote)
        }
    }

    private func section(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button {
                    UIPasteboard.general.string = body
                    Haptics.tap()
                } label: { Image(systemName: "doc.on.doc").font(.caption) }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Text(body.count > 6000 ? String(body.prefix(6000)) + "\n\u{2026}" : body)
                    .font(.caption.monospaced())
                    .foregroundStyle(title == "Error" ? .red : .primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true)
            }
            .frame(maxHeight: 320)
        }
    }
}

enum ToolSummary {
    private static let preferredKeys = ["command", "cmd", "file_path", "path", "pattern", "query", "url", "description", "prompt"]

    static func oneLine(_ call: ToolCallItem) -> String {
        let input = call.input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = input.data(using: .utf8), let json = JSONValue.parse(data), case .object(let o) = json {
            for k in preferredKeys {
                if let v = o[k]?.string, !v.isEmpty { return firstLine(v) }
            }
            if let first = o.sorted(by: { $0.key < $1.key }).first(where: { $0.value.string?.isEmpty == false }) {
                return firstLine(first.value.string ?? "")
            }
        }
        if !input.isEmpty { return firstLine(input) }
        return firstLine(call.output ?? "")
    }

    private static func firstLine(_ s: String) -> String {
        let line = s.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? s
        return line.trimmingCharacters(in: .whitespaces)
    }

    static func symbol(_ name: String) -> String {
        let n = name.lowercased()
        if n.contains("bash") || n.contains("shell") || n.contains("exec") || n.contains("command") { return "terminal" }
        if n.contains("edit") || n.contains("write") || n.contains("patch") { return "pencil" }
        if n.contains("read") || n.contains("view") { return "doc.text" }
        if n.contains("grep") || n.contains("glob") || n.contains("search") || n.contains("find") { return "magnifyingglass" }
        if n.contains("web") || n.contains("fetch") || n.contains("http") { return "globe" }
        if n.contains("task") || n.contains("agent") { return "person.2" }
        if n.contains("todo") { return "checklist" }
        return "wrench.and.screwdriver"
    }
}
