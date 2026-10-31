import SwiftUI

/// Remote-control hub for the box: system health, GPU-burst control, services,
/// tmux sessions, Claude history and a shell console. One screen, drill down.
struct BoxView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase

    @State private var system: BoxSystem?
    @State private var burst: [BurstModel] = []
    @State private var services: [BoxService] = []
    @State private var error: String?
    @State private var busyModel: String?

    var body: some View {
        NavigationStack {
            List {
                if let error { errorRow(error) }
                systemSection
                burstSection
                servicesSection
                activitySection
            }
            .navigationTitle("Box")
            .refreshable { await loadAll() }
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                while !Task.isCancelled {
                    await loadAll()
                    try? await Task.sleep(nanoseconds: 6_000_000_000)
                }
            }
        }
    }

    // MARK: System

    @ViewBuilder private var systemSection: some View {
        Section("System") {
            if let s = system {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Label(s.hostname, systemImage: "server.rack").font(.headline)
                        Spacer()
                        Text("up \(s.uptimeText)").font(.subheadline).foregroundStyle(.secondary)
                    }
                    if let load = s.loadavg.first, let cpus = s.cpus {
                        Meter(label: "Load", value: load, limit: Double(cpus),
                              text: String(format: "%.1f / %d", load, cpus),
                              tint: load > Double(cpus) ? .orange : .green)
                    }
                    Meter(label: "Memory", value: Double(s.memUsedMB), limit: Double(max(s.memTotalMB, 1)),
                          text: "\(s.memUsedMB) / \(s.memTotalMB) MB", tint: barTint(s.memUsedPct))
                    if s.swapTotalMB > 0 {
                        Meter(label: "Swap", value: Double(s.swapUsedMB), limit: Double(s.swapTotalMB),
                              text: "\(s.swapUsedMB) / \(s.swapTotalMB) MB", tint: barTint(s.swapUsedPct))
                    }
                    Meter(label: "Disk /", value: s.diskTotalGB - s.diskFreeGB, limit: max(s.diskTotalGB, 1),
                          text: String(format: "%.0f%% used, %.0f GB free", Double(s.diskUsedPct ?? 0), s.diskFreeGB),
                          tint: barTint(s.diskUsedPct ?? 0))
                }
                .padding(.vertical, 4)
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: GPU burst

    @ViewBuilder private var burstSection: some View {
        if !burst.isEmpty {
            Section("GPU burst") {
                ForEach(burst) { m in
                    HStack {
                        HarnessBadge(harness: m.model, size: 30)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(m.model.uppercased()).font(.subheadline.weight(.semibold))
                            Text(m.held ? "container pinned" : "scaled to zero")
                                .font(.caption).foregroundStyle(m.held ? .green : .secondary)
                        }
                        Spacer()
                        if busyModel == m.model {
                            ProgressView()
                        } else if m.held {
                            Button("Release") { Task { await burstAction(m.model, "release") } }
                                .buttonStyle(.bordered).tint(.red).controlSize(.small)
                        } else {
                            Button("Warm") { Task { await burstAction(m.model, "warm") } }
                                .buttonStyle(.bordered).tint(.green).controlSize(.small)
                        }
                    }
                }
            }
        }
    }

    // MARK: Services

    @ViewBuilder private var servicesSection: some View {
        Section("Services") {
            ForEach(services.prefix(5)) { svc in
                HStack {
                    Circle().fill(svc.isActive ? .green : .secondary).frame(width: 8, height: 8)
                    Text(svc.name).font(.subheadline)
                    Spacer()
                    Text(svc.active).font(.caption).foregroundStyle(.secondary)
                }
            }
            NavigationLink { ServicesView() } label: {
                Label("Manage services", systemImage: "gearshape.2")
            }
        }
    }

    // MARK: Activity

    @ViewBuilder private var activitySection: some View {
        Section("Activity") {
            NavigationLink { TmuxListView() } label: {
                Label("tmux sessions", systemImage: "rectangle.split.3x1")
            }
            NavigationLink { ClaudeHistoryView() } label: {
                Label("Claude history", systemImage: "clock.arrow.circlepath")
            }
            NavigationLink { ShellConsoleView() } label: {
                Label("Shell console", systemImage: "terminal")
            }
        }
    }

    private func errorRow(_ msg: String) -> some View {
        Label(msg, systemImage: "wifi.exclamationmark")
            .font(.footnote).foregroundStyle(.orange)
    }

    private func barTint(_ pct: Int) -> Color {
        pct >= 90 ? .red : pct >= 75 ? .orange : .green
    }

    // MARK: Loading

    private func loadAll() async {
        guard store.config.isConfigured else { return }
        do {
            async let sys = store.api.boxSystem()
            async let br = store.api.boxBurst()
            async let svc = store.api.boxServices()
            system = try await sys
            burst = try await br
            services = try await svc
            error = nil
        } catch is CancellationError {
        } catch {
            self.error = APIClient.describe(error)
        }
    }

    private func burstAction(_ model: String, _ action: String) async {
        busyModel = model
        defer { busyModel = nil }
        Haptics.tap()
        _ = try? await store.api.boxBurstAction(model, action: action)
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        burst = (try? await store.api.boxBurst()) ?? burst
    }
}

/// A labelled horizontal bar used across the box dashboard.
struct Meter: View {
    let label: String
    let value: Double
    let limit: Double
    let text: String
    var tint: Color = .green

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.caption.weight(.medium))
                Spacer()
                Text(text).font(.caption).foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.18))
                    Capsule().fill(tint)
                        .frame(width: max(2, min(1, value / max(limit, 0.001)) * geo.size.width))
                }
            }
            .frame(height: 6)
        }
    }
}
