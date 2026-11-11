import SwiftUI

/// Full list of watched systemd services with start/stop/restart.
struct ServicesView: View {
    @Environment(AppStore.self) private var store
    @State private var services: [BoxService] = []
    @State private var busy: String?
    @State private var error: String?
    @State private var loaded = false

    var body: some View {
        List {
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(HelmColor.amber)
                    .helmRow()
            }
            if !loaded && services.isEmpty && error == nil {
                ForEach(0..<5, id: \.self) { _ in SkeletonRow().helmRow() }
            }
            ForEach(services) { svc in
                serviceRow(svc).helmRow()
            }
        }
        .helmScreen()
        .navigationTitle("Services")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
    }

    private func serviceRow(_ svc: BoxService) -> some View {
        HStack(spacing: HelmSpace.md) {
            PulseDot(color: svc.isActive ? HelmColor.lime : HelmColor.textTertiary,
                     size: 8, isActive: svc.isActive)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 3) {
                Text(svc.name)
                    .font(HelmFont.mono(.subheadline, weight: .medium))
                    .foregroundStyle(HelmColor.textPrimary)
                Text("\(svc.active) · \(svc.enabled)")
                    .font(HelmFont.mono(.caption2))
                    .foregroundStyle(HelmColor.textTertiary)
            }
            Spacer()
            if busy == svc.name {
                ProgressView().tint(HelmColor.textSecondary)
            } else {
                Menu {
                    Button("Restart") { act(svc.name, "restart") }
                    Button("Start") { act(svc.name, "start") }
                    Button("Stop", role: .destructive) { act(svc.name, "stop") }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title3)
                        .foregroundStyle(HelmColor.textSecondary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func load() async {
        do { services = try await store.api.boxServices(); error = nil }
        catch { self.error = APIClient.describe(error) }
        loaded = true
    }

    private func act(_ name: String, _ action: String) {
        Task {
            busy = name; defer { busy = nil }
            Haptics.tap()
            do { _ = try await store.api.boxServiceAction(name, action: action) }
            catch { self.error = APIClient.describe(error) }
            try? await Task.sleep(nanoseconds: 800_000_000)
            await load()
        }
    }
}
