import SwiftUI

struct ToolCallCard: View {
    let call: ToolCallItem
    let isLive: Bool
    @State private var expanded = false

    private var isRunning: Bool { !call.isError && call.output == nil && isLive }

    private var statusTint: Color {
        if call.isError { return HelmColor.red }
        if isRunning { return HelmColor.lime }
        return HelmColor.textTertiary.opacity(0.6)
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: HelmRadius.control, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            Button {
                Haptics.tap()
                withHelmAnimation { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    statusIcon
                        .frame(width: 16)
                    Text(call.name)
                        .font(HelmFont.mono(.footnote, weight: .semibold))
                        .foregroundStyle(call.isError ? HelmColor.red : HelmColor.textPrimary)
                    Text(ToolSummary.oneLine(call))
                        .font(HelmFont.mono(.footnote))
                        .foregroundStyle(HelmColor.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(HelmColor.textTertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .padding(.leading, 14)
                .padding(.trailing, 12)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                Rectangle().fill(HelmColor.hairline).frame(height: 1)
                VStack(alignment: .leading, spacing: 12) {
                    if !call.input.isEmpty { section("Input", call.input) }
                    if let out = call.output {
                        section(call.isError ? "Error" : "Output", out.isEmpty ? "(no output)" : out)
                    }
                }
                .padding(.leading, 14)
                .padding(.trailing, 12)
                .padding(.vertical, 12)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(shape.fill(call.isError ? HelmColor.red.opacity(0.07) : HelmColor.surface))
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(statusTint)
                .frame(width: 2.5)
                .shadow(color: isRunning ? HelmColor.lime.opacity(0.6) : .clear, radius: 4)
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(call.isError ? HelmColor.red.opacity(0.35) : HelmColor.hairline, lineWidth: 1))
        .helmAnimation(HelmMotion.spring, value: isRunning)
        .helmAnimation(HelmMotion.spring, value: call.isError)
    }

    @ViewBuilder
    private var statusIcon: some View {
        if call.isError {
            Image(systemName: "xmark.octagon.fill").foregroundStyle(HelmColor.red).font(.footnote)
        } else if isRunning {
            ProgressView().controlSize(.mini).tint(HelmColor.lime)
        } else {
            Image(systemName: ToolSummary.symbol(call.name)).foregroundStyle(HelmColor.textSecondary).font(.footnote)
        }
    }

    private func section(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(0.8)
                    .foregroundStyle(title == "Error" ? HelmColor.red : HelmColor.textTertiary)
                Spacer()
                Button {
                    UIPasteboard.general.string = body
                    Haptics.tap()
                } label: { Image(systemName: "doc.on.doc").font(.caption) }
                .buttonStyle(.borderless)
                .foregroundStyle(HelmColor.textSecondary)
                .accessibilityLabel("Copy \(title.lowercased())")
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Text(body.count > 6000 ? String(body.prefix(6000)) + "\n\u{2026}" : body)
                    .font(HelmFont.mono(.caption))
                    .foregroundStyle(title == "Error" ? HelmColor.red : HelmColor.textPrimary.opacity(0.9))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(10)
            }
            .frame(maxHeight: 320)
            .background(RoundedRectangle(cornerRadius: HelmRadius.chip, style: .continuous).fill(HelmColor.obsidian))
            .overlay(RoundedRectangle(cornerRadius: HelmRadius.chip, style: .continuous).strokeBorder(HelmColor.hairline, lineWidth: 1))
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
