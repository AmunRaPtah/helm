import QuickLook
import SwiftUI
import UIKit

/// Helm's folder on the phone (Files > On My iPhone > Helm), where downloads land.
/// Preview, share, save elsewhere, send back to the box, or delete.
struct PhoneFilesView: View {
    var url: URL = PhoneFiles.root

    @Environment(AppStore.self) private var store
    @State private var transfers = Transfers.shared
    @AppStorage("helm.uploadDir") private var uploadDir = "/root/uploads"

    @State private var entries: [LocalEntry] = []
    @State private var previewURL: URL?
    @State private var exporting: URL?
    @State private var deleting: LocalEntry?
    @State private var sending: LocalEntry?
    @State private var showTransfers = false

    private var isRoot: Bool { url.standardizedFileURL == PhoneFiles.root.standardizedFileURL }

    var body: some View {
        List {
            if isRoot {
                Section {
                    Link(destination: URL(string: "shareddocuments://" + PhoneFiles.root.path)!) {
                        Label("Open in the Files app", systemImage: "folder.badge.gearshape")
                    }
                } footer: {
                    Text("Downloads from the box land here. The Files app shows the same folder under On My iPhone \u{203A} Helm.")
                }
            }
            Section {
                if entries.isEmpty {
                    Text("Nothing here yet").foregroundStyle(.secondary)
                }
                ForEach(entries) { e in row(e) }
            }
        }
        .navigationTitle(isRoot ? "On this iPhone" : url.lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: load)
        .refreshable { load() }
        .onChange(of: transfers.activeCount) { _, _ in load() }
        .quickLookPreview($previewURL)
        .sheet(item: Binding(get: { exporting.map(ExportItem.init) }, set: { exporting = $0?.url })) { item in
            ExportPicker(url: item.url).ignoresSafeArea()
        }
        .sheet(item: $sending) { e in
            NavigationStack { SendToBoxView(entry: e, dir: $uploadDir) { dir in
                transfers.upload([e.url], to: dir, api: store.api)
                sending = nil
                showTransfers = true
            } }
        }
        .sheet(isPresented: $showTransfers) {
            NavigationStack { TransfersView() }.presentationDetents([.medium, .large])
        }
        .confirmationDialog(deleting.map { "Delete \u{201C}\($0.name)\u{201D} from this iPhone?" } ?? "",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let e = deleting { try? FileManager.default.removeItem(at: e.url); load() }
                deleting = nil
            }
        } message: {
            Text("Only the copy on the phone is removed, not anything on the box.")
        }
    }

    @ViewBuilder private func row(_ e: LocalEntry) -> some View {
        Group {
            if e.isDir {
                NavigationLink { PhoneFilesView(url: e.url) } label: { label(e) }
            } else {
                Button { previewURL = e.url } label: { label(e) }.foregroundStyle(.primary)
            }
        }
        .contextMenu {
            if !e.isDir {
                Button { previewURL = e.url } label: { Label("Preview", systemImage: "eye") }
            }
            ShareLink(item: e.url) { Label("Share", systemImage: "square.and.arrow.up") }
            Button { exporting = e.url } label: { Label("Save to Files\u{2026}", systemImage: "folder") }
            Button { sending = e } label: { Label("Upload to box\u{2026}", systemImage: "arrow.up.circle") }
            Button(role: .destructive) { deleting = e } label: { Label("Delete", systemImage: "trash") }
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { deleting = e } label: { Label("Delete", systemImage: "trash") }
        }
        .swipeActions(edge: .leading) {
            Button { sending = e } label: { Label("Upload", systemImage: "arrow.up.circle") }.tint(.accentColor)
        }
    }

    private func label(_ e: LocalEntry) -> some View {
        HStack(spacing: 12) {
            Image(systemName: e.isDir ? "folder.fill" : PickedFile.icon(for: e.name))
                .font(.title3)
                .foregroundStyle(e.isDir ? Color.accentColor : .secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(e.name).lineLimit(1).truncationMode(.middle)
                Text(e.isDir ? e.mtime.formatted(.relative(presentation: .named))
                             : "\(ByteCountFormatter.string(fromByteCount: e.size, countStyle: .file)) \u{00B7} \(e.mtime.formatted(.relative(presentation: .named)))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
    }

    private func load() {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys,
                                                                  options: [.skipsHiddenFiles])) ?? []
        entries = urls.compactMap { u in
            if isRoot && u.lastPathComponent == PhoneFiles.systemInbox.lastPathComponent { return nil }
            let v = try? u.resourceValues(forKeys: Set(keys))
            return LocalEntry(url: u, isDir: v?.isDirectory ?? false, size: Int64(v?.fileSize ?? 0),
                              mtime: v?.contentModificationDate ?? .distantPast)
        }
        .sorted { ($0.isDir ? 0 : 1, $0.name.lowercased()) < ($1.isDir ? 0 : 1, $1.name.lowercased()) }
    }
}

struct LocalEntry: Identifiable, Hashable {
    var url: URL
    var isDir: Bool
    var size: Int64
    var mtime: Date
    var id: URL { url }
    var name: String { url.lastPathComponent }
}

private struct ExportItem: Identifiable {
    let url: URL
    var id: URL { url }
}

/// Picks a box folder, then uploads a phone file or folder into it.
private struct SendToBoxView: View {
    let entry: LocalEntry
    @Binding var dir: String
    let send: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section("Upload") {
                Label(entry.name, systemImage: entry.isDir ? "folder" : "doc")
            }
            Section {
                NavigationLink { DirectoryPicker(selection: $dir, startPath: dir) } label: {
                    Label(dir, systemImage: "folder").font(.callout.monospaced())
                        .lineLimit(1).truncationMode(.head)
                }
            } header: { Text("Into box folder") } footer: {
                Text(entry.isDir ? "The whole folder is copied, subfolders included. If a folder with that name exists, the copy gets a -1 suffix."
                                 : "Existing files are never overwritten.")
            }
        }
        .navigationTitle("Upload to box")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .topBarTrailing) { Button("Upload") { send(dir) }.bold() }
        }
    }
}

/// "Save to Files": the system picker for copying a file or folder anywhere
/// the Files app can reach (iCloud Drive, a USB drive, another app's folder).
struct ExportPicker: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        UIDocumentPickerViewController(forExporting: [url], asCopy: true)
    }

    func updateUIViewController(_ vc: UIDocumentPickerViewController, context: Context) {}
}
