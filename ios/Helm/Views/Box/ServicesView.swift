import SwiftUI

/// Full list of watched systemd services with start/stop/restart.
struct ServicesView: View {
    @Environment(AppStore.self) private var store
    @State private var services: [BoxService] = []
    @State private var busy: String?
    @State private var error: String?

    var body: some View {
        List {
            if let error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            ForEach(services) { svc in
                HStack(spacing: 12) {
                    Circle().fill(svc.isActive ? .green : .secondary).frame(width: 10, height: 10)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(svc.name).font(.subheadline.weight(.medium))
                        Text("\(svc.active) · \(svc.enabled)").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if busy == svc.name {
                        ProgressView()
                    } else {
                        Menu {
                            Button("Restart") { act(svc.name, "restart") }
                            Button("Start") { act(svc.name, "start") }
                            Button("Stop", role: .destructive) { act(svc.name, "stop") }
                        } label: {
                            Image(systemName: "ellipsis.circle").font(.title3)
                        }
                    }
                }
            }
        }
        .navigationTitle("Services")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        do { services = try await store.api.boxServices(); error = nil }
        catch { self.error = APIClient.describe(error) }
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
