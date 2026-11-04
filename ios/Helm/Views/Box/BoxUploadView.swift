import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Sends files, folders and photos from the phone to a chosen folder on the box.
/// Also where "Open in Helm" from another app lands.
struct BoxUploadView: View {
    @Environment(AppStore.self) private var store
    @AppStorage("helm.uploadDir") private var dir = "/root/uploads"
    @State private var inbox = FileInbox.shared
    @State private var transfers = Transfers.shared
    @State private var started: Set<UUID> = []
    @State private var importFolders = false
    @State private var showImporter = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var error: String?

    var body: some View {
        List {
            Section("Destination") {
                NavigationLink { DirectoryPicker(selection: $dir, startPath: dir) } label: {
                    Label(dir, systemImage: "folder")
                        .font(.callout.monospaced())
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            Section {
                Button { importFolders = false; showImporter = true } label: { Label("Choose files", systemImage: "doc.badge.plus") }
                Button { importFolders = true; showImporter = true } label: { Label("Choose a folder", systemImage: "folder.badge.plus") }
                PhotosPicker(selection: $photoItems, maxSelectionCount: 50, matching: .any(of: [.images, .videos])) {
                    Label("Choose photos or videos", systemImage: "photo.on.rectangle")
                }
            } footer: {
                Text("Tip: in any app, Share \u{2192} Helm sends a file straight here. Existing files are never overwritten.")
            }
            if let error {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
            let mine = transfers.items.filter { started.contains($0.id) }
            if !mine.isEmpty {
                Section("Uploads") {
                    ForEach(mine) { t in row(t) }
                }
            }
        }
        .navigationTitle("Upload to box")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: importFolders ? [.folder] : [.item],
                      allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            send(urls, owned: false)
        }
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            photoItems = []
            Task { await sendPhotos(items) }
        }
        .task(id: inbox.pending.count) { drainInbox() }
    }

    private func row(_ t: Transfer) -> some View {
        HStack(spacing: 10) {
            switch t.state {
            case .running: ProgressView().controlSize(.small)
            case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            case .cancelled: Image(systemName: "xmark.circle").foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(t.name).font(.subheadline).lineLimit(1)
                Group {
                    switch t.state {
                    case .running:
                        Text(t.fraction.map { "\(Int($0 * 100))%" + (t.isFolder ? " \u{00B7} \(t.doneFiles)/\(t.totalFiles) files" : "") } ?? "Uploading\u{2026}")
                    case .done: Text(t.remotePath ?? "")
                    case .failed(let m): Text(m)
                    case .cancelled: Text("Cancelled")
                    }
                }
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.head)
            }
        }
        .contextMenu {
            if let p = t.remotePath {
                Button { UIPasteboard.general.string = p } label: { Label("Copy path", systemImage: "doc.on.doc") }
            }
            if t.isRunning {
                Button(role: .destructive) { transfers.cancel(t) } label: { Label("Cancel", systemImage: "xmark") }
            }
        }
    }

    private func send(_ urls: [URL], owned: Bool) {
        guard !urls.isEmpty else { return }
        let before = Set(transfers.items.map(\.id))
        transfers.upload(urls, to: dir, api: store.api, ownedTemp: owned)
        started.formUnion(transfers.items.map(\.id).filter { !before.contains($0) })
    }

    private func drainInbox() {
        let urls = inbox.pending
        guard !urls.isEmpty else { return }
        inbox.pending = []
        send(urls, owned: true)
    }

    private func sendPhotos(_ items: [PhotosPickerItem]) async {
        var urls: [URL] = []
        for item in items {
            if let f = try? await item.loadTransferable(type: PhotoFile.self) { urls.append(f.url) }
        }
        error = urls.count < items.count ? "\(items.count - urls.count) item(s) couldn't be loaded from Photos" : nil
        send(urls, owned: true)
    }
}
