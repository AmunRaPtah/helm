import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Sends files, documents and photos from the phone to a folder on the box.
struct BoxUploadView: View {
    @Environment(AppStore.self) private var store
    @AppStorage("helm.uploadDir") private var dir = "/root/uploads"
    @State private var inbox = FileInbox.shared
    @State private var uploads: [BoxUpload] = []
    @State private var showFiles = false
    @State private var photoItems: [PhotosPickerItem] = []

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
                Button { showFiles = true } label: { Label("Choose files", systemImage: "doc.badge.plus") }
                PhotosPicker(selection: $photoItems, maxSelectionCount: 20, matching: .any(of: [.images, .videos])) {
                    Label("Choose photos or videos", systemImage: "photo.on.rectangle")
                }
            } footer: {
                Text("Tip: in any app, Share \u{2192} Helm sends a file straight here. Existing files are never overwritten.")
            }
            if !uploads.isEmpty {
                Section("Uploads") {
                    ForEach(uploads) { u in row(u) }
                }
            }
        }
        .navigationTitle("Upload to box")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            for url in urls {
                if let f = PickedFile.load(url) { send(f) }
                else { uploads.insert(BoxUpload(filename: url.lastPathComponent, error: "Couldn't read file"), at: 0) }
            }
        }
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            photoItems = []
            for item in items { Task { await sendPhoto(item) } }
        }
        .task(id: inbox.pending.count) { drainInbox() }
    }

    private func row(_ u: BoxUpload) -> some View {
        HStack(spacing: 10) {
            if u.isUploading {
                ProgressView().controlSize(.small)
            } else if u.error != nil {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            } else {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(u.filename).font(.subheadline).lineLimit(1)
                Text(u.error ?? u.path ?? "Uploading \(ByteCountFormatter.string(fromByteCount: Int64(u.size), countStyle: .file))\u{2026}")
                    .font(.caption.monospaced())
                    .foregroundStyle(u.error == nil ? Color.secondary : Color.red)
                    .lineLimit(2)
                    .truncationMode(.head)
            }
        }
        .contextMenu {
            if let p = u.path {
                Button { UIPasteboard.general.string = p } label: { Label("Copy path", systemImage: "doc.on.doc") }
            }
        }
    }

    private func drainInbox() {
        let files = inbox.pending
        guard !files.isEmpty else { return }
        inbox.pending = []
        files.forEach(send)
    }

    private func sendPhoto(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self) else {
            uploads.insert(BoxUpload(filename: "photo", error: "Couldn't load from Photos"), at: 0)
            return
        }
        let type = item.supportedContentTypes.first
        let ext = type?.preferredFilenameExtension ?? "bin"
        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        send(PickedFile(data: data, filename: "photo-\(stamp).\(ext)",
                        mimeType: type?.preferredMIMEType ?? "application/octet-stream"))
    }

    private func send(_ f: PickedFile) {
        let u = BoxUpload(filename: f.filename, size: f.data.count)
        uploads.insert(u, at: 0)
        let target = dir
        Task {
            do {
                let path = try await store.api.uploadToBox(dir: target, data: f.data, filename: f.filename, mimeType: f.mimeType)
                update(u.id) { $0.path = path }
                Haptics.tap()
            } catch {
                update(u.id) { $0.error = APIClient.describe(error) }
            }
        }
    }

    private func update(_ id: UUID, _ change: (inout BoxUpload) -> Void) {
        if let i = uploads.firstIndex(where: { $0.id == id }) { change(&uploads[i]) }
    }
}

struct BoxUpload: Identifiable {
    let id = UUID()
    var filename: String
    var size = 0
    var path: String?
    var error: String?
    var isUploading: Bool { path == nil && error == nil }
}
