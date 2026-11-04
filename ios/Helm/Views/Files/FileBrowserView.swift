import PhotosUI
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

/// Browses a directory on the box. Upload files, folders and photos into it,
/// download any file or whole folder to the phone, preview, rename, delete.
struct FileBrowserView: View {
    let path: String

    @Environment(AppStore.self) private var store
    @State private var transfers = Transfers.shared
    @AppStorage("helm.files.showHidden") private var showHidden = false

    @State private var listing: FsListing?
    @State private var error: String?
    @State private var filter = ""

    @State private var importFolders = false
    @State private var showImporter = false
    @State private var showPhotos = false
    @State private var photoItems: [PhotosPickerItem] = []

    @State private var showNewFolder = false
    @State private var newFolderName = ""
    @State private var renaming: FsEntry?
    @State private var renameText = ""
    @State private var deleting: FsEntry?

    @State private var previewURL: URL?
    @State private var previewing: String?
    @State private var showTransfers = false
    @State private var showGoTo = false
    @State private var goToText = ""
    @State private var jumpPath: String?

    var body: some View {
        List {
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.footnote).foregroundStyle(.red)
            }
            if listing == nil && error == nil {
                ProgressView().frame(maxWidth: .infinity)
            }
            if let listing {
                if visible.isEmpty {
                    Text(filter.isEmpty ? "Empty folder" : "No matches")
                        .foregroundStyle(.secondary)
                }
                ForEach(visible) { e in row(e) }
                if !listing.entries.isEmpty {
                    Text(summary(listing))
                        .font(.caption).foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $filter, placement: .navigationBarDrawer(displayMode: .automatic))
        .refreshable { await load() }
        .task { await load() }
        .onChange(of: transfers.uploadsFinished) { _, _ in Task { await load() } }
        .toolbar { toolbar }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: importFolders ? [.folder] : [.item],
                      allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result, !urls.isEmpty else { return }
            transfers.upload(urls, to: path, api: store.api)
            showTransfers = true
        }
        .photosPicker(isPresented: $showPhotos, selection: $photoItems, maxSelectionCount: 50,
                      matching: .any(of: [.images, .videos]))
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            photoItems = []
            Task { await uploadPhotos(items) }
        }
        .alert("New folder", isPresented: $showNewFolder) {
            TextField("Name", text: $newFolderName)
            Button("Create") { Task { await makeFolder() } }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Rename") { Task { await rename() } }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Go to folder", isPresented: $showGoTo) {
            TextField("/root/projects", text: $goToText)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("Go") {
                let p = goToText.trimmingCharacters(in: .whitespaces)
                if p.hasPrefix("/") { jumpPath = p }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(deleting.map { "Move \u{201C}\($0.name)\u{201D} to trash?" } ?? "",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) { Task { await delete() } }
        } message: {
            Text("It goes to ~/.helm/trash on the box and is purged after 7 days.")
        }
        .navigationDestination(isPresented: Binding(get: { jumpPath != nil }, set: { if !$0 { jumpPath = nil } })) {
            if let jumpPath { FileBrowserView(path: jumpPath) }
        }
        .quickLookPreview($previewURL)
        .sheet(isPresented: $showTransfers) {
            NavigationStack { TransfersView() }
                .presentationDetents([.medium, .large])
        }
    }

    // MARK: Rows

    @ViewBuilder private func row(_ e: FsEntry) -> some View {
        Group {
            if e.isDir {
                NavigationLink { FileBrowserView(path: e.path) } label: { label(e) }
            } else {
                Button { Task { await preview(e) } } label: { label(e) }
                    .foregroundStyle(.primary)
            }
        }
        .contextMenu { menu(e) }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { deleting = e } label: { Label("Delete", systemImage: "trash") }
        }
        .swipeActions(edge: .leading) {
            Button { download(e) } label: { Label("Download", systemImage: "arrow.down.circle") }
                .tint(.accentColor)
        }
    }

    private func label(_ e: FsEntry) -> some View {
        HStack(spacing: 12) {
            Image(systemName: e.isDir ? "folder.fill" : PickedFile.icon(for: e.name))
                .font(.title3)
                .foregroundStyle(e.isDir ? Color.accentColor : .secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(e.name).lineLimit(1).truncationMode(.middle)
                    if e.isLink { Image(systemName: "arrow.turn.up.right").font(.caption2).foregroundStyle(.secondary) }
                }
                Text(e.isDir ? e.mtime.formatted(.relative(presentation: .named))
                             : "\(e.sizeText) \u{00B7} \(e.mtime.formatted(.relative(presentation: .named)))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if previewing == e.path { ProgressView().controlSize(.small) }
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder private func menu(_ e: FsEntry) -> some View {
        if e.isDir {
            Button { download(e) } label: { Label("Download folder", systemImage: "arrow.down.circle") }
            Button { transfers.download(e, api: store.api, asZip: true); showTransfers = true } label: {
                Label("Download as .zip", systemImage: "doc.zipper")
            }
        } else {
            Button { Task { await preview(e) } } label: { Label("Preview", systemImage: "eye") }
            Button { download(e) } label: { Label("Download to iPhone", systemImage: "arrow.down.circle") }
        }
        Button { UIPasteboard.general.string = e.path } label: { Label("Copy path", systemImage: "doc.on.doc") }
        Button { renameText = e.name; renaming = e } label: { Label("Rename", systemImage: "pencil") }
        Button(role: .destructive) { deleting = e } label: { Label("Delete", systemImage: "trash") }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button { showTransfers = true } label: {
                Image(systemName: transfers.activeCount > 0 ? "arrow.up.arrow.down.circle.fill" : "arrow.up.arrow.down.circle")
                    .overlay(alignment: .topTrailing) {
                        if transfers.activeCount > 0 {
                            Text("\(transfers.activeCount)")
                                .font(.caption2.bold()).foregroundStyle(.white)
                                .padding(3).background(Circle().fill(.red))
                                .offset(x: 8, y: -8)
                        }
                    }
            }
            .accessibilityLabel("Transfers")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Section("Upload here") {
                    Button { importFolders = false; showImporter = true } label: {
                        Label("Files", systemImage: "doc.badge.plus")
                    }
                    Button { importFolders = true; showImporter = true } label: {
                        Label("Folder", systemImage: "folder.badge.plus")
                    }
                    Button { showPhotos = true } label: {
                        Label("Photos or videos", systemImage: "photo.on.rectangle")
                    }
                }
                Button { newFolderName = ""; showNewFolder = true } label: {
                    Label("New folder", systemImage: "folder.badge.plus")
                }
                Button {
                    if let l = listing { transfers.download(FsEntry(name: title, path: l.path, isDir: true, size: 0,
                                                                     mtime: .now, isLink: false), api: store.api)
                        showTransfers = true }
                } label: { Label("Download this folder", systemImage: "arrow.down.circle") }
                Divider()
                Button { goToText = path; showGoTo = true } label: { Label("Go to\u{2026}", systemImage: "arrow.right.circle") }
                Button { UIPasteboard.general.string = path } label: { Label("Copy path", systemImage: "doc.on.doc") }
                Toggle(isOn: $showHidden) { Label("Show hidden files", systemImage: "eye") }
            } label: {
                Image(systemName: "plus.circle")
            }
            .accessibilityLabel("Upload and folder actions")
        }
    }

    // MARK: Data

    private var title: String {
        path == "/" ? "/" : (path as NSString).lastPathComponent
    }

    private var visible: [FsEntry] {
        let all = listing?.entries ?? []
        let shown = showHidden ? all : all.filter { !$0.isHidden }
        guard !filter.isEmpty else { return shown }
        return all.filter { $0.name.localizedCaseInsensitiveContains(filter) }
    }

    private func summary(_ l: FsListing) -> String {
        let dirs = l.entries.filter(\.isDir).count
        let files = l.entries.count - dirs
        let bytes = l.entries.reduce(Int64(0)) { $0 + $1.size }
        var s = "\(dirs) folder\(dirs == 1 ? "" : "s"), \(files) file\(files == 1 ? "" : "s")"
        if files > 0 { s += " \u{00B7} " + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
        let hidden = l.entries.filter(\.isHidden).count
        if !showHidden && hidden > 0 { s += " \u{00B7} \(hidden) hidden" }
        return s
    }

    private func load() async {
        do {
            listing = try await store.api.fsList(path)
            error = nil
        } catch is CancellationError {
        } catch {
            self.error = APIClient.describe(error)
        }
    }

    private func download(_ e: FsEntry) {
        transfers.download(e, api: store.api)
        Haptics.tap()
        showTransfers = true
    }

    private func preview(_ e: FsEntry) async {
        guard previewing == nil else { return }
        previewing = e.path
        defer { previewing = nil }
        do {
            let tmp = try await store.api.fsDownload(e.path)
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("preview", isDirectory: true)
            try? FileManager.default.removeItem(at: dir)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let dest = dir.appendingPathComponent(e.name)
            try FileManager.default.moveItem(at: tmp, to: dest)
            previewURL = dest
        } catch is CancellationError {
        } catch {
            self.error = "\(e.name): \(APIClient.describe(error))"
        }
    }

    private func makeFolder() async {
        let name = newFolderName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !name.contains("/") else { return }
        do {
            _ = try await store.api.fsMkdir(FsPath.join(path, name))
            await load()
        } catch {
            self.error = APIClient.describe(error)
        }
    }

    private func rename() async {
        guard let e = renaming else { return }
        renaming = nil
        let name = renameText.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !name.contains("/"), name != e.name else { return }
        do {
            _ = try await store.api.fsMove(e.path, to: FsPath.join(path, name))
            await load()
        } catch {
            self.error = APIClient.describe(error)
        }
    }

    private func delete() async {
        guard let e = deleting else { return }
        deleting = nil
        do {
            try await store.api.fsDelete(e.path)
            Haptics.tap()
            await load()
        } catch {
            self.error = APIClient.describe(error)
        }
    }

    private func uploadPhotos(_ items: [PhotosPickerItem]) async {
        var urls: [URL] = []
        var failed = 0
        for item in items {
            if let f = try? await item.loadTransferable(type: PhotoFile.self) { urls.append(f.url) } else { failed += 1 }
        }
        if failed > 0 { error = "\(failed) item\(failed == 1 ? "" : "s") couldn't be loaded from Photos" }
        guard !urls.isEmpty else { return }
        transfers.upload(urls, to: path, api: store.api, ownedTemp: true)
        showTransfers = true
    }
}

/// A photo or video exported from the library straight to a temp file (videos
/// can be gigabytes, so never via Data). Keeps the original filename.
struct PhotoFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { try copy($0.file) }
        FileRepresentation(importedContentType: .image) { try copy($0.file) }
        FileRepresentation(importedContentType: .item) { try copy($0.file) }
    }

    private static func copy(_ src: URL) throws -> PhotoFile {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("in-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(src.lastPathComponent)
        try FileManager.default.copyItem(at: src, to: dest)
        return PhotoFile(url: dest)
    }
}
