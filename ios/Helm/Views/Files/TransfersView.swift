import QuickLook
import SwiftUI

/// Every upload and download this launch: progress, cancel, and where it ended up.
struct TransfersView: View {
    @State private var transfers = Transfers.shared
    @State private var previewURL: URL?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            if transfers.items.isEmpty {
                HelmEmptyState(title: "No transfers yet",
                               message: "Upload from a box folder's + menu, or swipe right on a file or folder to download it.",
                               systemImage: "arrow.up.arrow.down")
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            ForEach(transfers.items) { t in
                row(t)
                    .helmRow()
            }
        }
        .helmScreen()
        .tint(HelmColor.lime)
        .navigationTitle("Transfers")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Clear") {
                    Haptics.tap()
                    transfers.clearFinished()
                }
                .foregroundStyle(HelmColor.textSecondary)
                    .disabled(!transfers.items.contains { !$0.isRunning })
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { dismiss() }
                    .fontWeight(.semibold)
            }
        }
        .quickLookPreview($previewURL)
    }

    private func row(_ t: Transfer) -> some View {
        VStack(alignment: .leading, spacing: HelmSpace.sm) {
            HStack(spacing: 10) {
                Image(systemName: t.kind == .upload ? "arrow.up.circle" : "arrow.down.circle")
                    .foregroundStyle(color(t))
                Image(systemName: t.isFolder ? "folder" : PickedFile.icon(for: t.name))
                    .foregroundStyle(HelmColor.textTertiary)
                Text(t.name)
                    .font(HelmFont.body)
                    .foregroundStyle(HelmColor.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                if t.isRunning {
                    Button {
                        Haptics.warning()
                        transfers.cancel(t)
                    } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless).foregroundStyle(HelmColor.textTertiary)
                        .accessibilityLabel("Cancel")
                } else if let url = t.localURL, !t.isFolder {
                    Button {
                        Haptics.tap()
                        previewURL = url
                    } label: { Image(systemName: "eye") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(HelmColor.lime)
                        .accessibilityLabel("Preview")
                }
            }
            if t.isRunning {
                TransferBar(fraction: t.fraction)
            }
            Text(detail(t))
                .font(HelmFont.mono(.caption2))
                .foregroundStyle(isFailed(t) ? HelmColor.red : HelmColor.textTertiary)
                .lineLimit(2).truncationMode(.head)
            if !t.failures.isEmpty {
                DisclosureGroup("\(t.failures.count) failed") {
                    ForEach(t.failures, id: \.self) { Text($0).font(HelmFont.mono(.caption2)).foregroundStyle(HelmColor.red) }
                }
                .font(HelmFont.mono(.caption, weight: .medium))
                .foregroundStyle(HelmColor.red)
                .tint(HelmColor.red)
            }
        }
        .padding(.vertical, HelmSpace.xs)
        .contextMenu {
            if let p = t.remotePath {
                Button { UIPasteboard.general.string = p } label: { Label("Copy box path", systemImage: "doc.on.doc") }
            }
            if let url = t.localURL, !t.isRunning {
                ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
            }
        }
    }

    private func detail(_ t: Transfer) -> String {
        let bytes = ByteCountFormatter.string(fromByteCount: t.doneBytes, countStyle: .file)
        let total = ByteCountFormatter.string(fromByteCount: t.totalBytes, countStyle: .file)
        switch t.state {
        case .running:
            var s = t.totalBytes > 0 ? "\(bytes) of \(total)" : bytes
            if t.isFolder && t.totalFiles > 0 { s += " \u{00B7} \(t.doneFiles)/\(t.totalFiles) files" }
            if !t.current.isEmpty { s += "\n" + t.current }
            return s
        case .done:
            let place = t.kind == .upload ? (t.remotePath ?? "") : "On My iPhone \u{203A} Helm \u{203A} \(t.localURL?.lastPathComponent ?? t.name)"
            let count = t.isFolder ? "\(t.totalFiles) files, " : ""
            return "\(count)\(total)\n\(place)"
        case .failed(let msg):
            return msg
        case .cancelled:
            return "Cancelled"
        }
    }

    private func isFailed(_ t: Transfer) -> Bool {
        if case .failed = t.state { return true }
        return false
    }

    private func color(_ t: Transfer) -> Color {
        switch t.state {
        case .running: return HelmColor.lime
        case .done: return HelmColor.lime
        case .failed: return HelmColor.red
        case .cancelled: return HelmColor.textTertiary
        }
    }
}

/// Thin lime progress track. Indeterminate (nil) shows a dim empty track.
private struct TransferBar: View {
    let fraction: Double?

    var body: some View {
        let value = min(max(fraction ?? 0, 0), 1)
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.06))
                Capsule()
                    .fill(HelmColor.lime)
                    .frame(width: geo.size.width * value)
                    .shadow(color: HelmColor.lime.opacity(0.45), radius: 3)
            }
        }
        .frame(height: 3)
        .opacity(fraction == nil ? 0.4 : 1)
        .helmAnimation(HelmMotion.snappy, value: value)
        .accessibilityElement()
        .accessibilityValue(fraction.map { "\(Int($0 * 100)) percent" } ?? "In progress")
    }
}
