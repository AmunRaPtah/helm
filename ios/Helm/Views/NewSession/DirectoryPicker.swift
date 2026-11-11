import SwiftUI

struct DirectoryPicker: View {
    @Binding var selection: String
    var startPath: String = "/root/projects"

    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var path = ""
    @State private var listing: DirListing?
    @State private var error: String?
    @State private var loading = false
    @State private var filter = ""

    var body: some View {
        List {
            if path == startPath || listing == nil, !Recents.all.isEmpty, filter.isEmpty {
                Section {
                    ForEach(Recents.all, id: \.self) { r in
                        Button { choose(r) } label: {
                            Label {
                                Text(r)
                                    .font(HelmFont.mono(.callout))
                                    .foregroundStyle(HelmColor.textPrimary)
                                    .lineLimit(1)
                                    .truncationMode(.head)
                            } icon: {
                                Image(systemName: "clock.arrow.circlepath")
                                    .foregroundStyle(HelmColor.textTertiary)
                            }
                        }
                    }
                } header: {
                    HelmSectionHeader(title: "Recent")
                }
                .helmRow()
            }
            Section {
                if path != "/" {
                    Button {
                        Haptics.tap()
                        Task { await load(parent(of: path)) }
                    } label: {
                        Label {
                            Text("..")
                                .font(HelmFont.mono(.body, weight: .medium))
                                .foregroundStyle(HelmColor.textSecondary)
                        } icon: {
                            Image(systemName: "arrow.turn.left.up")
                                .foregroundStyle(HelmColor.textTertiary)
                        }
                    }
                }
                if let error {
                    Label {
                        Text(error).font(HelmFont.mono(.caption))
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                    }
                    .foregroundStyle(HelmColor.red)
                    .font(.footnote)
                }
                if loading && listing == nil {
                    ForEach(0..<6, id: \.self) { _ in
                        SkeletonRow()
                    }
                }
                ForEach(visible) { e in
                    Button {
                        Haptics.tap()
                        Task { await load(join(path, e.name)) }
                    } label: {
                        HStack(spacing: HelmSpace.md) {
                            Image(systemName: "folder.fill")
                                .font(.body)
                                .foregroundStyle(HelmColor.textSecondary.opacity(0.8))
                                .frame(width: 24)
                            Text(e.name)
                                .font(HelmFont.body)
                                .foregroundStyle(HelmColor.textPrimary)
                                .lineLimit(1)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(HelmColor.textTertiary)
                        }
                    }
                    .foregroundStyle(HelmColor.textPrimary)
                }
                if listing != nil && visible.isEmpty && error == nil {
                    HelmEmptyState(title: filter.isEmpty ? "No subfolders" : "No matches",
                                   message: filter.isEmpty ? "You can still use this folder." : "Nothing here matches \u{201C}\(filter)\u{201D}.",
                                   systemImage: "folder")
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                }
            } header: {
                Text(path)
                    .font(HelmFont.mono(.caption, weight: .medium))
                    .foregroundStyle(HelmColor.textTertiary)
                    .textCase(nil)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            .helmRow()
        }
        .helmScreen()
        .tint(HelmColor.lime)
        .refreshable {
            guard !path.isEmpty else { return }
            await load(path)
        }
        .searchable(text: $filter, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Filter")
        .navigationTitle((path as NSString).lastPathComponent.isEmpty ? "/" : (path as NSString).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            Button { choose(path) } label: {
                Label("Use this folder", systemImage: "checkmark")
            }
            .buttonStyle(HelmPrimaryButtonStyle())
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
            .disabled(path.isEmpty)
        }
        .task {
            guard listing == nil else { return }
            await load(selection.hasPrefix("/") ? selection : startPath)
        }
    }

    private var visible: [DirEntry] {
        let all = listing?.entries ?? []
        let shown = all.filter { !$0.name.hasPrefix(".") || filter.hasPrefix(".") }
        guard !filter.isEmpty else { return shown }
        return all.filter { $0.name.localizedCaseInsensitiveContains(filter) }
    }

    private func load(_ p: String) async {
        loading = true
        defer { loading = false }
        do {
            let l = try await store.api.dirs(p)
            listing = l
            path = l.path
            error = nil
            filter = ""
        } catch {
            if listing == nil { path = p }
            self.error = APIClient.describe(error)
        }
    }

    private func choose(_ p: String) {
        selection = p
        Recents.add(p)
        Haptics.tap()
        dismiss()
    }

    private func parent(of p: String) -> String {
        let parent = (p as NSString).deletingLastPathComponent
        return parent.isEmpty ? "/" : parent
    }

    private func join(_ base: String, _ name: String) -> String {
        base.hasSuffix("/") ? base + name : base + "/" + name
    }
}
