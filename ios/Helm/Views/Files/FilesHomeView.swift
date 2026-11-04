import SwiftUI

/// The Files tab: box folders on one side, Helm's folder on the phone on the other,
/// and the transfer list between them.
struct FilesHomeView: View {
    @State private var transfers = Transfers.shared
    @AppStorage("helm.uploadDir") private var uploadDir = "/root/uploads"

    var body: some View {
        NavigationStack {
            List {
                Section("Box") {
                    place("Home", "/root", "house")
                    place("Projects", "/root/projects", "hammer")
                    place("Uploads", uploadDir, "tray.and.arrow.down")
                    place("Everything", "/", "externaldrive")
                }
                Section("Phone") {
                    NavigationLink { PhoneFilesView() } label: {
                        Label("On this iPhone", systemImage: "iphone")
                    }
                }
                Section {
                    NavigationLink { TransfersView() } label: {
                        HStack {
                            Label("Transfers", systemImage: "arrow.up.arrow.down")
                            Spacer()
                            if transfers.activeCount > 0 {
                                Text("\(transfers.activeCount) active").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                } footer: {
                    Text("Open a box folder and use + to upload files or whole folders into it. Swipe right on anything to download it; folders come down with all their subfolders.")
                }
            }
            .navigationTitle("Files")
        }
    }

    private func place(_ title: String, _ path: String, _ icon: String) -> some View {
        NavigationLink { FileBrowserView(path: path) } label: {
            VStack(alignment: .leading, spacing: 2) {
                Label(title, systemImage: icon)
                Text(path).font(.caption.monospaced()).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.head)
            }
        }
    }
}
