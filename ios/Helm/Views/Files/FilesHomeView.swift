import SwiftUI

/// The Files tab: box folders on one side, Helm's folder on the phone on the other,
/// and the transfer list between them.
struct FilesHomeView: View {
    @State private var transfers = Transfers.shared
    @AppStorage("helm.uploadDir") private var uploadDir = "/root/uploads"

    var body: some View {
        NavigationStack {
            List {
                Section {
                    place("Home", "/root", "house")
                    place("Projects", "/root/projects", "hammer")
                    place("Uploads", uploadDir, "tray.and.arrow.down")
                    place("Everything", "/", "externaldrive")
                } header: {
                    HelmSectionHeader(title: "Box")
                }
                .helmRow()
                Section {
                    NavigationLink { PhoneFilesView() } label: {
                        rowLabel("On this iPhone", icon: "iphone", detail: "On My iPhone \u{203A} Helm")
                    }
                } header: {
                    HelmSectionHeader(title: "Phone")
                }
                .helmRow()
                Section {
                    NavigationLink { TransfersView() } label: {
                        HStack(spacing: HelmSpace.md) {
                            iconBadge("arrow.up.arrow.down", live: transfers.activeCount > 0)
                            Text("Transfers")
                                .font(HelmFont.body)
                                .foregroundStyle(HelmColor.textPrimary)
                            Spacer()
                            if transfers.activeCount > 0 {
                                HStack(spacing: 6) {
                                    PulseDot(color: HelmColor.lime, size: 6)
                                    Text("\(transfers.activeCount) active")
                                        .font(HelmFont.mono(.caption, weight: .medium))
                                        .foregroundStyle(HelmColor.lime)
                                }
                            }
                        }
                    }
                } header: {
                    HelmSectionHeader(title: "Activity")
                } footer: {
                    Text("Open a box folder and use + to upload files or whole folders into it. Swipe right on anything to download it; folders come down with all their subfolders.")
                        .foregroundStyle(HelmColor.textTertiary)
                }
                .helmRow()
            }
            .helmScreen()
            .tint(HelmColor.lime)
            .navigationTitle("Files")
        }
    }

    private func place(_ title: String, _ path: String, _ icon: String) -> some View {
        NavigationLink { FileBrowserView(path: path) } label: {
            rowLabel(title, icon: icon, detail: path)
        }
    }

    private func rowLabel(_ title: String, icon: String, detail: String) -> some View {
        HStack(spacing: HelmSpace.md) {
            iconBadge(icon, live: false)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(HelmFont.body)
                    .foregroundStyle(HelmColor.textPrimary)
                Text(detail)
                    .font(HelmFont.mono(.caption2))
                    .foregroundStyle(HelmColor.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
    }

    private func iconBadge(_ name: String, live: Bool) -> some View {
        Image(systemName: name)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(live ? HelmColor.lime : HelmColor.textSecondary)
            .frame(width: 32, height: 32)
            .background(RoundedRectangle(cornerRadius: HelmRadius.chip, style: .continuous).fill(Color.white.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: HelmRadius.chip, style: .continuous).strokeBorder(HelmColor.hairline, lineWidth: 0.5))
    }
}
