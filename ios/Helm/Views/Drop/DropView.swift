import PhotosUI
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

/// Drop: a chat with your box. Send photos, files and notes from the phone; anything
/// the box sends (`helm-send file`) shows up here to tap, preview and keep.
struct DropView: View {
    @Environment(AppStore.self) private var store
    @State private var drop = DropStore.shared
    @State private var draft = ""
    @State private var showFiles = false
    @State private var showPhotos = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var previewURL: URL?
    @State private var confirmDelete: DropItem?
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: HelmSpace.sm) {
                        if drop.loaded && drop.items.isEmpty && drop.pending.isEmpty {
                            HelmEmptyState(title: "Nothing dropped yet",
                                           message: "Send photos, files or notes to the box with +. On the box, run helm-send <file> to send something here.",
                                           systemImage: "paperplane") { EmptyView() }
                                .padding(.top, 80)
                        }
                        ForEach(drop.items) { item in
                            bubble(item).id("i\(item.id)")
                        }
                        ForEach(drop.pending) { p in
                            pendingBubble(p).id(p.id)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.horizontal, HelmSpace.md)
                    .padding(.vertical, HelmSpace.sm)
                }
                .defaultScrollAnchor(.bottom)
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: drop.items.count + drop.pending.count) { _, _ in
                    withAnimation(HelmMotion.animation()) { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
            .safeAreaInset(edge: .bottom) { composer }
            .safeAreaInset(edge: .top) {
                if let e = drop.error {
                    Label(e, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(HelmColor.red)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity)
                        .background(.bar)
                }
            }
            .background(HelmBackground())
            .navigationTitle("Drop")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        NavigationLink { FileBrowserView(path: drop.boxDir) } label: {
                            Label("Box folder (\(drop.boxDir))", systemImage: "server.rack")
                        }
                        NavigationLink { PhoneFilesView(url: DropStore.phoneDir) } label: {
                            Label("On this iPhone", systemImage: "iphone")
                        }
                    } label: {
                        Image(systemName: "folder")
                    }
                    .accessibilityLabel("Drop folders")
                }
            }
            .tint(HelmColor.lime)
            .quickLookPreview($previewURL)
            .photosPicker(isPresented: $showPhotos, selection: $photoItems, maxSelectionCount: 50,
                          matching: .any(of: [.images, .videos]))
            .fileImporter(isPresented: $showFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                if case .success(let urls) = result { sendFiles(urls, owned: false) }
            }
            .onChange(of: photoItems) { _, items in
                guard !items.isEmpty else { return }
                photoItems = []
                Task { await sendPhotos(items) }
            }
            .confirmationDialog("Delete", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
                                presenting: confirmDelete) { item in
                Button("Remove from Drop") { Task { await drop.delete(item, everywhere: false) } }
                if item.kind == .file {
                    Button("Delete file on box and phone", role: .destructive) { Task { await drop.delete(item, everywhere: true) } }
                }
            } message: { item in
                Text(item.kind == .file ? "Removing keeps the file in \(drop.boxDir). Deleting moves it to the box trash." : "Remove this note?")
            }
            .onAppear { drop.isVisible = true }
            .onDisappear { drop.isVisible = false }
            .refreshable { await drop.refresh() }
        }
    }

    // MARK: Composer

    private var composer: some View {
        HStack(alignment: .bottom, spacing: HelmSpace.sm) {
            Menu {
                Button { showPhotos = true } label: { Label("Photos & videos", systemImage: "photo.on.rectangle") }
                Button { showFiles = true } label: { Label("Files", systemImage: "folder") }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .background(Color.white.opacity(0.06), in: Circle())
                    .foregroundStyle(HelmColor.textSecondary)
            }
            .accessibilityLabel("Attach")

            TextField("Note to the box", text: $draft, axis: .vertical)
                .lineLimit(1...6)
                .focused($focused)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .frame(minHeight: 36)
                .background(HelmColor.raised, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(HelmColor.hairline))

            Button {
                drop.sendNote(draft)
                draft = ""
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 16, weight: .bold))
                    .frame(width: 36, height: 36)
                    .background(canSend ? HelmColor.lime : Color.white.opacity(0.06), in: Circle())
                    .foregroundStyle(canSend ? HelmColor.onLime : HelmColor.textTertiary)
            }
            .disabled(!canSend)
            .accessibilityLabel("Send note")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var canSend: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func sendFiles(_ urls: [URL], owned: Bool) {
        guard !urls.isEmpty else { return }
        // A typed draft rides along as the caption of the last file, like Telegram.
        let caption = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = ""
        drop.send(urls, owned: owned, caption: caption)
    }

    private func sendPhotos(_ items: [PhotosPickerItem]) async {
        var urls: [URL] = []
        for item in items {
            if let f = try? await item.loadTransferable(type: PhotoFile.self) { urls.append(f.url) }
        }
        if urls.count < items.count { drop.error = "\(items.count - urls.count) item(s) couldn't be loaded from Photos" }
        sendFiles(urls, owned: true)
    }

    // MARK: Bubbles

    private func bubble(_ item: DropItem) -> some View {
        let mine = item.sender == .phone
        return HStack {
            if mine { Spacer(minLength: 48) }
            VStack(alignment: mine ? .trailing : .leading, spacing: 4) {
                VStack(alignment: .leading, spacing: 6) {
                    if item.kind == .file { fileCard(item) }
                    if !item.text.isEmpty {
                        Text(item.text)
                            .font(HelmFont.body)
                            .foregroundStyle(HelmColor.textPrimary)
                            .textSelection(.enabled)
                    }
                }
                .padding(10)
                .background(mine ? HelmColor.lime.opacity(0.13) : HelmColor.raised,
                            in: RoundedRectangle(cornerRadius: HelmRadius.card, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: HelmRadius.card, style: .continuous)
                    .strokeBorder(mine ? HelmColor.lime.opacity(0.25) : HelmColor.hairline, lineWidth: 0.5))
                .contentShape(RoundedRectangle(cornerRadius: HelmRadius.card))
                .onTapGesture { open(item) }
                .contextMenu { menu(item) }
                Text((mine ? "" : "box \u{00B7} ") + item.date.formatted(date: .abbreviated, time: .shortened))
                    .font(HelmFont.mono(.caption2))
                    .foregroundStyle(HelmColor.textTertiary)
            }
            if !mine { Spacer(minLength: 48) }
        }
    }

    @ViewBuilder private func fileCard(_ item: DropItem) -> some View {
        let local = drop.localURL(item)
        if let local, UTType(filenameExtension: local.pathExtension)?.conforms(to: .image) == true {
            DropThumbnail(url: local)
        }
        HStack(spacing: HelmSpace.md) {
            ZStack {
                RoundedRectangle(cornerRadius: HelmRadius.chip, style: .continuous)
                    .fill(Color.white.opacity(0.06))
                    .frame(width: 40, height: 40)
                if drop.downloading.contains(item.id) {
                    ProgressView().controlSize(.small).tint(HelmColor.lime)
                } else {
                    Image(systemName: local != nil ? icon(for: item) : (item.exists ? "arrow.down" : "questionmark"))
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(local != nil ? HelmColor.textSecondary : HelmColor.lime)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.localName)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(HelmColor.textPrimary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                Text(status(item, local: local))
                    .font(HelmFont.mono(.caption2))
                    .foregroundStyle(drop.downloadErrors[item.id] != nil ? HelmColor.red : HelmColor.textTertiary)
                    .lineLimit(2)
            }
        }
    }

    private func status(_ item: DropItem, local: URL?) -> String {
        if let e = drop.downloadErrors[item.id] { return e + " \u{00B7} tap to retry" }
        if !item.exists && local == nil { return "No longer on the box" }
        if drop.downloading.contains(item.id) { return "\(item.sizeText) \u{00B7} downloading\u{2026}" }
        return item.sizeText + (local == nil ? " \u{00B7} tap to download" : "")
    }

    private func icon(for item: DropItem) -> String {
        if item.isDir { return "doc.zipper" }
        guard let t = UTType(filenameExtension: (item.name as NSString).pathExtension) else { return "doc" }
        if t.conforms(to: .image) { return "photo" }
        if t.conforms(to: .movie) || t.conforms(to: .video) { return "film" }
        if t.conforms(to: .audio) { return "waveform" }
        if t.conforms(to: .pdf) { return "doc.richtext" }
        if t.conforms(to: .archive) { return "doc.zipper" }
        if t.conforms(to: .sourceCode) || t.conforms(to: .text) { return "doc.text" }
        return "doc"
    }

    private func open(_ item: DropItem) {
        guard item.kind == .file else { return }
        Haptics.tap()
        if let u = drop.localURL(item) {
            previewURL = u
        } else if item.exists {
            drop.download(item) { previewURL = $0 }
        }
    }

    @ViewBuilder private func menu(_ item: DropItem) -> some View {
        if item.kind == .file {
            if let u = drop.localURL(item) {
                Button { previewURL = u } label: { Label("Open", systemImage: "eye") }
                ShareLink(item: u) { Label("Share / Save", systemImage: "square.and.arrow.up") }
            } else if item.exists {
                Button { drop.download(item) } label: { Label("Download", systemImage: "arrow.down.circle") }
            }
            if let p = item.path {
                Button { UIPasteboard.general.string = p } label: { Label("Copy box path", systemImage: "doc.on.doc") }
            }
        }
        if !item.text.isEmpty {
            Button { UIPasteboard.general.string = item.text } label: { Label("Copy text", systemImage: "text.quote") }
        }
        Button(role: .destructive) { confirmDelete = item } label: { Label("Delete\u{2026}", systemImage: "trash") }
    }

    private func pendingBubble(_ p: DropStore.Pending) -> some View {
        HStack {
            Spacer(minLength: 48)
            VStack(alignment: .trailing, spacing: 4) {
                VStack(alignment: .leading, spacing: 6) {
                    if p.file != nil {
                        HStack(spacing: HelmSpace.md) {
                            Image(systemName: p.error == nil ? "arrow.up" : "exclamationmark.triangle.fill")
                                .foregroundStyle(p.error == nil ? HelmColor.lime : HelmColor.red)
                                .frame(width: 40, height: 40)
                                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: HelmRadius.chip))
                            VStack(alignment: .leading, spacing: 4) {
                                Text(p.name).font(.subheadline.weight(.medium)).foregroundStyle(HelmColor.textPrimary).lineLimit(1)
                                if p.error == nil && p.size > 0 {
                                    ProgressView(value: min(1, Double(p.sent) / Double(p.size))).tint(HelmColor.lime)
                                }
                            }
                        }
                    }
                    if !p.text.isEmpty {
                        Text(p.text).font(HelmFont.body).foregroundStyle(HelmColor.textPrimary)
                    }
                }
                .padding(10)
                .background(HelmColor.lime.opacity(0.08), in: RoundedRectangle(cornerRadius: HelmRadius.card, style: .continuous))
                .opacity(p.error == nil ? 0.7 : 1)
                .contextMenu {
                    if p.error != nil {
                        Button { drop.retry(p) } label: { Label("Retry", systemImage: "arrow.clockwise") }
                    }
                    Button(role: .destructive) { drop.discard(p) } label: { Label("Discard", systemImage: "xmark") }
                }
                .onTapGesture { if p.error != nil { drop.retry(p) } }
                Text(p.error.map { "Failed: \($0) \u{00B7} tap to retry" } ?? "Sending\u{2026}")
                    .font(HelmFont.mono(.caption2))
                    .foregroundStyle(p.error == nil ? HelmColor.textTertiary : HelmColor.red)
                    .lineLimit(2)
            }
        }
    }
}

/// Downscaled preview of an image that's already on the phone.
private struct DropThumbnail: View {
    let url: URL
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: 240, maxHeight: 240)
                    .clipShape(RoundedRectangle(cornerRadius: HelmRadius.control, style: .continuous))
            }
        }
        .task(id: url) {
            let u = url
            image = await Task.detached {
                UIImage(contentsOfFile: u.path)?.preparingThumbnail(of: CGSize(width: 480, height: 480))
            }.value
        }
    }
}
