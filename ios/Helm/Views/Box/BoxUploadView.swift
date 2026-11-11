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
            Section {
                NavigationLink { DirectoryPicker(selection: $dir, startPath: dir) } label: {
                    Label {
                        Text(dir)
                            .font(HelmFont.mono(.callout))
                            .foregroundStyle(HelmColor.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    } icon: {
                        Image(systemName: "folder").foregroundStyle(HelmColor.textSecondary)
                    }
                }
                .helmRow()
            } header: {
                HelmSectionHeader(title: "Destination")
            }
            Section {
                Button { Haptics.tap(); importFolders = false; showImporter = true } label: {
                    pickerLabel("Choose files", systemImage: "doc.badge.plus")
                }
                .helmRow()
                Button { Haptics.tap(); importFolders = true; showImporter = true } label: {
                    pickerLabel("Choose a folder", systemImage: "folder.badge.plus")
                }
                .helmRow()
                PhotosPicker(selection: $photoItems, maxSelectionCount: 50, matching: .any(of: [.images, .videos])) {
                    pickerLabel("Choose photos or videos", systemImage: "photo.on.rectangle")
                }
                .helmRow()
            } header: {
                HelmSectionHeader(title: "Send")
            } footer: {
                Text("Tip: in any app, Share \u{2192} Helm sends a file straight here. Existing files are never overwritten.")
                    .foregroundStyle(HelmColor.textTertiary)
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(HelmColor.red)
                    .helmRow()
            }
            let mine = transfers.items.filter { started.contains($0.id) }
            if !mine.isEmpty {
                Section {
                    ForEach(mine) { t in row(t).helmRow() }
                } header: {
                    HelmSectionHeader(title: "Uploads", trailing: "\(mine.count)")
                }
            }
        }
        .helmScreen()
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

    private func pickerLabel(_ title: String, systemImage: String) -> some View {
        Label {
            Text(title).foregroundStyle(HelmColor.textPrimary)
        } icon: {
            Image(systemName: systemImage).foregroundStyle(HelmColor.lime)
        }
    }

    private func row(_ t: Transfer) -> some View {
        HStack(spacing: HelmSpace.md) {
            stateIcon(t)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(t.name)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(HelmColor.textPrimary)
                    .lineLimit(1)
                Group {
                    switch t.state {
                    case .running:
                        Text(t.fraction.map { "\(Int($0 * 100))%" + (t.isFolder ? " \u{00B7} \(t.doneFiles)/\(t.totalFiles) files" : "") } ?? "Uploading\u{2026}")
                    case .done: Text(t.remotePath ?? "")
                    case .failed(let m): Text(m)
                    case .cancelled: Text("Cancelled")
                    }
                }
                .font(HelmFont.mono(.caption2))
                .monospacedDigit()
                .foregroundStyle(detailTint(t))
                .lineLimit(2)
                .truncationMode(.head)
                if t.isRunning, let f = t.fraction {
                    progressTrack(f)
                }
            }
        }
        .padding(.vertical, 2)
        .contextMenu {
            if let p = t.remotePath {
                Button { UIPasteboard.general.string = p } label: { Label("Copy path", systemImage: "doc.on.doc") }
            }
            if t.isRunning {
                Button(role: .destructive) { transfers.cancel(t) } label: { Label("Cancel", systemImage: "xmark") }
            }
        }
    }

    @ViewBuilder private func stateIcon(_ t: Transfer) -> some View {
        switch t.state {
        case .running: ProgressView().controlSize(.small).tint(HelmColor.lime)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(HelmColor.lime)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(HelmColor.red)
        case .cancelled: Image(systemName: "xmark.circle").foregroundStyle(HelmColor.textTertiary)
        }
    }

    private func progressTrack(_ f: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.06))
                Capsule()
                    .fill(HelmColor.lime)
                    .frame(width: max(2, min(1, max(0, f)) * geo.size.width))
            }
        }
        .frame(height: 3)
        .helmAnimation(HelmMotion.gentle, value: f)
        .accessibilityHidden(true)
    }

    private func detailTint(_ t: Transfer) -> Color {
        switch t.state {
        case .failed: return HelmColor.red
        default: return HelmColor.textTertiary
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
