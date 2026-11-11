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
            .helmScreen()
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
        Section {
            if let s = system {
                systemCard(s)
                    .padding(.vertical, HelmSpace.xs)
                    .helmRow()
            } else {
                systemSkeleton
                    .helmRow()
            }
        } header: {
            HelmSectionHeader(title: "System", trailing: system.map { "up \($0.uptimeText)" })
        }
    }

    private func systemCard(_ s: BoxSystem) -> some View {
        VStack(alignment: .leading, spacing: HelmSpace.md) {
            HStack(spacing: HelmSpace.sm) {
                PulseDot(color: error == nil ? HelmColor.lime : HelmColor.amber, size: 7, isActive: error == nil)
                Text(s.hostname)
                    .font(HelmFont.headline)
                    .foregroundStyle(HelmColor.textPrimary)
                Spacer()
                Image(systemName: "server.rack")
                    .font(.footnote)
                    .foregroundStyle(HelmColor.textTertiary)
            }
            if let load = s.loadavg.first, let cpus = s.cpus {
                Meter(label: "Load", value: load, limit: Double(cpus),
                      text: String(format: "%.1f / %d", load, cpus),
                      tint: load > Double(cpus) ? HelmColor.amber : HelmColor.lime)
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
    }

    private var systemSkeleton: some View {
        VStack(alignment: .leading, spacing: HelmSpace.md) {
            SkeletonBlock(width: 140, height: 14)
            ForEach(0..<3, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 6) {
                    SkeletonBlock(width: 90, height: 9)
                    SkeletonBlock(height: 3, radius: 1.5)
                }
            }
        }
        .padding(.vertical, HelmSpace.xs)
        .accessibilityHidden(true)
    }

    // MARK: GPU burst

    @ViewBuilder private var burstSection: some View {
        if !burst.isEmpty {
            Section {
                ForEach(burst) { m in
                    burstRow(m).helmRow()
                }
            } header: {
                HelmSectionHeader(title: "GPU burst")
            }
        }
    }

    private func burstRow(_ m: BurstModel) -> some View {
        HStack(spacing: HelmSpace.md) {
            HarnessBadge(harness: m.model, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(m.model.uppercased())
                    .font(HelmFont.rowTitle)
                    .foregroundStyle(HelmColor.textPrimary)
                HStack(spacing: 5) {
                    if m.held { PulseDot(color: HelmColor.lime, size: 6) }
                    Text(m.held ? "container pinned" : "scaled to zero")
                        .font(HelmFont.mono(.caption2))
                        .foregroundStyle(m.held ? HelmColor.lime : HelmColor.textTertiary)
                }
            }
            Spacer()
            if busyModel == m.model {
                ProgressView().tint(HelmColor.textSecondary)
            } else if m.held {
                Button("Release") { Task { await burstAction(m.model, "release") } }
                    .buttonStyle(HelmSecondaryButtonStyle(tint: HelmColor.red))
            } else {
                Button("Warm") { Task { await burstAction(m.model, "warm") } }
                    .buttonStyle(HelmSecondaryButtonStyle(tint: HelmColor.lime))
            }
        }
    }

    // MARK: Services

    @ViewBuilder private var servicesSection: some View {
        Section {
            ForEach(services.prefix(5)) { svc in
                HStack(spacing: HelmSpace.sm) {
                    PulseDot(color: svc.isActive ? HelmColor.lime : HelmColor.textTertiary,
                             size: 7, isActive: false)
                    Text(svc.name)
                        .font(HelmFont.mono(.subheadline))
                        .foregroundStyle(HelmColor.textPrimary)
                    Spacer()
                    Text(svc.active)
                        .font(HelmFont.mono(.caption2))
                        .foregroundStyle(svc.isActive ? HelmColor.textSecondary : HelmColor.textTertiary)
                }
                .helmRow()
            }
            NavigationLink { ServicesView() } label: {
                navLabel("Manage services", systemImage: "gearshape.2")
            }
            .helmRow()
        } header: {
            HelmSectionHeader(title: "Services", trailing: servicesTrailing)
        }
    }

    private var servicesTrailing: String? {
        guard !services.isEmpty else { return nil }
        let up = services.filter(\.isActive).count
        return "\(up)/\(services.count) up"
    }

    // MARK: Activity

    @ViewBuilder private var activitySection: some View {
        Section {
            NavigationLink { TmuxListView() } label: {
                navLabel("tmux sessions", systemImage: "rectangle.split.3x1")
            }
            .helmRow()
            NavigationLink { ClaudeHistoryView() } label: {
                navLabel("Claude history", systemImage: "clock.arrow.circlepath")
            }
            .helmRow()
            NavigationLink { ShellConsoleView() } label: {
                navLabel("Shell console", systemImage: "terminal")
            }
            .helmRow()
            NavigationLink { FileBrowserView(path: "/root") } label: {
                navLabel("Files", systemImage: "folder")
            }
            .helmRow()
        } header: {
            HelmSectionHeader(title: "Activity")
        }
    }

    private func navLabel(_ title: String, systemImage: String) -> some View {
        Label {
            Text(title).foregroundStyle(HelmColor.textPrimary)
        } icon: {
            Image(systemName: systemImage).foregroundStyle(HelmColor.textSecondary)
        }
    }

    private func errorRow(_ msg: String) -> some View {
        Label(msg, systemImage: "wifi.exclamationmark")
            .font(.footnote)
            .foregroundStyle(HelmColor.amber)
            .helmRow()
    }

    private func barTint(_ pct: Int) -> Color {
        if pct >= 90 { return HelmColor.red }
        if pct >= 75 { return HelmColor.amber }
        return HelmColor.lime
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

/// A labelled instrument gauge used across the box dashboard:
/// mono label and reading over a hairline track with a tinted fill.
struct Meter: View {
    let label: String
    let value: Double
    let limit: Double
    let text: String
    var tint: Color = HelmColor.lime

    private var fraction: Double {
        let f = value / max(limit, 0.001)
        return min(1, max(0, f))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(label.uppercased())
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(0.8)
                    .foregroundStyle(HelmColor.textTertiary)
                Spacer()
                Text(text)
                    .font(HelmFont.mono(.caption))
                    .monospacedDigit()
                    .foregroundStyle(HelmColor.textSecondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.06))
                    Capsule()
                        .fill(tint)
                        .frame(width: max(2, fraction * geo.size.width))
                        .shadow(color: tint.opacity(0.45), radius: 4)
                }
            }
            .frame(height: 3)
            .helmAnimation(HelmMotion.gentle, value: fraction)
        }
        .accessibilityElement(children: .combine)
    }
}
