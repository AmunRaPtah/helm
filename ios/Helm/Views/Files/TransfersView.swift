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
                Text("No transfers yet. Upload from a box folder's + menu, or swipe right on a file or folder to download it.")
                    .foregroundStyle(.secondary)
            }
            ForEach(transfers.items) { t in row(t) }
        }
        .navigationTitle("Transfers")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Clear") { transfers.clearFinished() }
                    .disabled(!transfers.items.contains { !$0.isRunning })
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { dismiss() }
            }
        }
        .quickLookPreview($previewURL)
    }

    private func row(_ t: Transfer) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: t.kind == .upload ? "arrow.up.circle" : "arrow.down.circle")
                    .foregroundStyle(color(t))
                Image(systemName: t.isFolder ? "folder" : PickedFile.icon(for: t.name))
                    .foregroundStyle(.secondary)
                Text(t.name).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                if t.isRunning {
                    Button { transfers.cancel(t) } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary)
                        .accessibilityLabel("Cancel")
                } else if let url = t.localURL, !t.isFolder {
                    Button { previewURL = url } label: { Image(systemName: "eye") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Preview")
                }
            }
            if t.isRunning {
                if let f = t.fraction { ProgressView(value: f) } else { ProgressView(value: 0).opacity(0.4) }
            }
            Text(detail(t))
                .font(.caption.monospaced())
                .foregroundStyle(isFailed(t) ? Color.red : Color.secondary)
                .lineLimit(2).truncationMode(.head)
            if !t.failures.isEmpty {
                DisclosureGroup("\(t.failures.count) failed") {
                    ForEach(t.failures, id: \.self) { Text($0).font(.caption2.monospaced()).foregroundStyle(.red) }
                }
                .font(.caption)
            }
        }
        .padding(.vertical, 2)
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
        case .running: return .accentColor
        case .done: return .green
        case .failed: return .red
        case .cancelled: return .secondary
        }
    }
}
