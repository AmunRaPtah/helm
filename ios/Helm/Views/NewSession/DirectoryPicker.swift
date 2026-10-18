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
                Section("Recent") {
                    ForEach(Recents.all, id: \.self) { r in
                        Button { choose(r) } label: {
                            Label(r, systemImage: "clock.arrow.circlepath")
                                .font(.callout.monospaced())
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                    }
                }
            }
            Section {
                if path != "/" {
                    Button { Task { await load(parent(of: path)) } } label: {
                        Label("..", systemImage: "arrow.turn.left.up")
                    }
                }
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.footnote)
                }
                ForEach(visible) { e in
                    Button { Task { await load(join(path, e.name)) } } label: {
                        HStack {
                            Label(e.name, systemImage: "folder")
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                    .foregroundStyle(.primary)
                }
            } header: {
                Text(path).font(.caption.monospaced()).textCase(nil)
            }
        }
        .searchable(text: $filter, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Filter")
        .overlay { if loading && listing == nil { ProgressView() } }
        .navigationTitle((path as NSString).lastPathComponent.isEmpty ? "/" : (path as NSString).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            Button { choose(path) } label: {
                Label("Use this folder", systemImage: "checkmark")
                    .frame(maxWidth: .infinity)
                    .font(.headline)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
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
