import SwiftUI

/// Box controller dashboard: live vitals and history, alerts that link to the
/// fix, tiles into every subsystem (containers, services, processes, network,
/// cron), quick actions, disks, GPU burst and the shell/tmux/files tools.
struct BoxView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase

    @State private var overview: BoxOverview?
    @State private var points: [MetricPoint] = []
    @State private var burst: [BurstModel] = []
    @State private var actions: [QuickAction] = []
    @State private var error: String?
    @State private var busyModel: String?
    @State private var series: MetricChart.Series = .cpu
    @State private var minutes = 15
    @State private var runner = ActionRunner()
    @State private var tick = 0

    private let grid = [GridItem(.flexible(), spacing: HelmSpace.md), GridItem(.flexible(), spacing: HelmSpace.md)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: HelmSpace.xl) {
                    if let error { errorBanner(error) }
                    hero
                    alertsSection
                    tilesSection
                    actionsSection
                    disksSection
                    burstSection
                    toolsSection
                }
                .padding(.horizontal, HelmSpace.lg)
                .padding(.bottom, HelmSpace.xxl)
            }
            .helmScreen()
            .navigationTitle("Box")
            .refreshable { await refreshAll() }
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                await refreshAll()
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    tick += 1
                    await loadOverview()
                    if tick % 2 == 0 { await loadMetrics() }
                    if tick % 6 == 0 { await loadBurst() }
                }
            }
            .onChange(of: minutes) { _, _ in Task { await loadMetrics() } }
            .actionRunner(runner, api: store.api)
        }
    }

    // MARK: Hero: gauges and chart

    private var hero: some View {
        VStack(alignment: .leading, spacing: HelmSpace.lg) {
            HStack(spacing: HelmSpace.sm) {
                PulseDot(color: heroColor, size: 8, isActive: error == nil)
                VStack(alignment: .leading, spacing: 1) {
                    Text(overview?.system.hostname ?? "box")
                        .font(HelmFont.headline).foregroundStyle(HelmColor.textPrimary)
                    Text(heroSubtitle)
                        .font(HelmFont.mono(.caption2)).foregroundStyle(HelmColor.textTertiary)
                }
                Spacer()
                if let l = overview?.latest {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text("↓ \(Fmt.rate(l.rx))").foregroundStyle(HelmColor.lime)
                        Text("↑ \(Fmt.rate(l.tx))").foregroundStyle(HelmColor.amber)
                    }
                    .font(HelmFont.mono(.caption2))
                }
            }

            if let o = overview {
                HStack(spacing: 0) {
                    RingGauge(label: "CPU", value: o.latest?.cpu ?? 0)
                    RingGauge(label: "Mem", value: o.latest?.mem ?? Double(o.system.memUsedPct))
                    RingGauge(label: "Load", value: loadPct(o), display: String(format: "%.1f", o.system.loadavg.first ?? 0),
                              tint: levelTint(loadPct(o), warn: 100, crit: 200))
                    RingGauge(label: "Disk", value: Double(o.system.diskUsedPct ?? 0))
                }
            } else {
                HStack { ForEach(0..<4, id: \.self) { _ in SkeletonBlock(width: 58, height: 58, radius: 29).frame(maxWidth: .infinity) } }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(MetricChart.Series.allCases) { s in
                        Button { series = s; Haptics.tap() } label: {
                            Text(s.rawValue)
                                .font(HelmFont.mono(.caption2, weight: .semibold))
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .foregroundStyle(series == s ? HelmColor.onLime : HelmColor.textSecondary)
                                .background(Capsule().fill(series == s ? HelmColor.lime : HelmColor.raisedHigh))
                        }
                        .buttonStyle(HelmPressStyle())
                    }
                    Divider().frame(height: 16).overlay(HelmColor.hairlineStrong)
                    ForEach([15, 60], id: \.self) { m in
                        Button { minutes = m; Haptics.tap() } label: {
                            Text(m == 60 ? "1h" : "\(m)m")
                                .font(HelmFont.mono(.caption2, weight: .semibold))
                                .padding(.horizontal, 9).padding(.vertical, 5)
                                .foregroundStyle(minutes == m ? HelmColor.textPrimary : HelmColor.textTertiary)
                                .overlay(Capsule().strokeBorder(minutes == m ? HelmColor.hairlineStrong : .clear))
                        }
                        .buttonStyle(HelmPressStyle())
                    }
                }
            }

            Group {
                if points.count >= 2 {
                    MetricChart(points: points, series: series, cpus: overview?.system.cpus ?? 1)
                } else {
                    SkeletonBlock(height: 140, radius: 10)
                }
            }
            .frame(height: 140)

            if series == .net || series == .disk {
                HStack(spacing: HelmSpace.lg) {
                    legend(series == .net ? "in" : "read", HelmColor.lime)
                    legend(series == .net ? "out" : "write", HelmColor.amber)
                }
            }
        }
        .padding(HelmSpace.lg)
        .helmCard()
    }

    private func legend(_ t: String, _ c: Color) -> some View {
        HStack(spacing: 5) {
            Capsule().fill(c).frame(width: 12, height: 3)
            Text(t).font(HelmFont.mono(.caption2)).foregroundStyle(HelmColor.textTertiary)
        }
    }

    private var heroColor: Color {
        guard error == nil, let o = overview else { return HelmColor.amber }
        if o.critCount > 0 { return HelmColor.red }
        return o.alerts.isEmpty ? HelmColor.lime : HelmColor.amber
    }

    private var heroSubtitle: String {
        guard let o = overview else { return "connecting…" }
        var s = "up \(o.system.uptimeText)"
        if let c = o.system.cpus { s += " · \(c) CPUs" }
        s += " · \(o.system.memTotalMB / 1024) GB RAM"
        return s
    }

    private func loadPct(_ o: BoxOverview) -> Double {
        guard let l = o.system.loadavg.first, let c = o.system.cpus, c > 0 else { return 0 }
        return l / Double(c) * 100
    }

    // MARK: Alerts

    @ViewBuilder private var alertsSection: some View {
        if let o = overview {
            VStack(alignment: .leading, spacing: HelmSpace.sm) {
                HelmSectionHeader(title: "Attention", trailing: o.alerts.isEmpty ? "all clear" : "\(o.alerts.count)")
                if o.alerts.isEmpty {
                    HStack(spacing: HelmSpace.sm) {
                        Image(systemName: "checkmark.seal.fill").foregroundStyle(HelmColor.lime)
                        Text("Nothing needs you right now.").font(.footnote).foregroundStyle(HelmColor.textSecondary)
                        Spacer()
                    }
                    .padding(HelmSpace.md)
                    .helmCard()
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(o.alerts.enumerated()), id: \.element.id) { i, a in
                            NavigationLink { alertDestination(a) } label: { alertRow(a) }
                                .buttonStyle(HelmPressStyle())
                            if i < o.alerts.count - 1 { Divider().overlay(HelmColor.hairline).padding(.leading, 40) }
                        }
                    }
                    .helmCard(stroke: o.critCount > 0 ? HelmColor.red.opacity(0.3) : nil)
                }
            }
        }
    }

    private func alertRow(_ a: BoxAlert) -> some View {
        let tint = a.level == .crit ? HelmColor.red : HelmColor.amber
        return HStack(spacing: HelmSpace.md) {
            Image(systemName: alertIcon(a.kind))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 26, height: 26)
                .background(Circle().fill(tint.opacity(0.12)))
            VStack(alignment: .leading, spacing: 1) {
                Text(a.title).font(.system(.subheadline, weight: .medium)).foregroundStyle(HelmColor.textPrimary).lineLimit(1)
                if !a.detail.isEmpty {
                    Text(a.detail).font(HelmFont.mono(.caption2)).foregroundStyle(HelmColor.textTertiary).lineLimit(1)
                }
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(HelmColor.textTertiary)
        }
        .padding(.horizontal, HelmSpace.md)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    private func alertIcon(_ kind: String) -> String {
        switch kind {
        case "disk": return "internaldrive"
        case "memory": return "memorychip"
        case "swap": return "arrow.left.arrow.right"
        case "load": return "speedometer"
        case "unit": return "gearshape.2"
        case "container": return "shippingbox"
        default: return "exclamationmark.triangle"
        }
    }

    @ViewBuilder private func alertDestination(_ a: BoxAlert) -> some View {
        switch a.kind {
        case "unit":
            if let t = a.target {
                LogView(title: t) { try await store.api.boxUnitLogs(t, lines: 300) }
            } else { UnitsView(initialScope: .failed) }
        case "container":
            if let t = a.target {
                LogView(title: t) { try await store.api.boxDockerLogs(t, lines: 300) }
            } else { ContainersView() }
        case "memory", "swap", "load":
            ProcessesView()
        default:
            ActionsView()
        }
    }

    // MARK: Tiles

    private var tilesSection: some View {
        VStack(alignment: .leading, spacing: HelmSpace.sm) {
            HelmSectionHeader(title: "Control")
            LazyVGrid(columns: grid, spacing: HelmSpace.md) {
                let o = overview
                tile(ContainersView()) {
                    StatTile(title: "Containers", value: o.map { "\($0.containersRunning)/\($0.containersTotal)" } ?? "–",
                             caption: o.map { $0.containersUnhealthy > 0 ? "\($0.containersUnhealthy) unhealthy" : "running" } ?? "",
                             systemImage: "shippingbox", tint: HelmColor.lime,
                             alert: (o?.alerts.contains { $0.kind == "container" }) ?? false)
                }
                tile(UnitsView(initialScope: (o?.unitsFailed ?? 0) > 0 ? .failed : .watched)) {
                    StatTile(title: "Services", value: o.map { $0.unitsFailed > 0 ? "\($0.unitsFailed)" : "OK" } ?? "–",
                             caption: o.map { $0.unitsFailed > 0 ? "failed units" : "no failures" } ?? "",
                             systemImage: "gearshape.2", tint: HelmColor.lime, alert: (o?.unitsFailed ?? 0) > 0)
                }
                tile(ProcessesView()) {
                    StatTile(title: "Processes", value: o.map { String(format: "%.0f%%", $0.latest?.cpu ?? 0) } ?? "–",
                             caption: o.map { String(format: "load %.1f", $0.system.loadavg.first ?? 0) } ?? "",
                             systemImage: "cpu", tint: HelmColor.textSecondary)
                }
                tile(NetworkView()) {
                    StatTile(title: "Network", value: o.map { "\($0.peersOnline)/\($0.peers)" } ?? "–",
                             caption: "WireGuard peers", systemImage: "network", tint: HelmColor.textSecondary)
                }
                tile(TmuxListView()) {
                    StatTile(title: "tmux", value: o.map { "\($0.tmux)" } ?? "–",
                             caption: o.map { "\($0.helmChats) Helm chats" } ?? "",
                             systemImage: "rectangle.split.3x1", tint: HelmColor.textSecondary)
                }
                tile(CronView()) {
                    StatTile(title: "Cron", value: "⏱", caption: "crontab", systemImage: "calendar.badge.clock",
                             tint: HelmColor.textSecondary)
                }
            }
        }
    }

    private func tile<D: View, L: View>(_ dest: D, @ViewBuilder label: () -> L) -> some View {
        NavigationLink { dest } label: { label() }
            .buttonStyle(HelmPressStyle())
    }

    // MARK: Quick actions

    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: HelmSpace.sm) {
            HStack {
                HelmSectionHeader(title: "Quick actions")
                Spacer()
                NavigationLink { ActionsView() } label: {
                    Text("Edit").font(HelmFont.mono(.caption2, weight: .semibold)).foregroundStyle(HelmColor.lime)
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: HelmSpace.sm) {
                    if actions.isEmpty {
                        ForEach(0..<4, id: \.self) { _ in SkeletonBlock(width: 110, height: 36, radius: 18) }
                    }
                    ForEach(actions) { a in
                        Button { runner.trigger(a, api: store.api) } label: {
                            HStack(spacing: 6) {
                                if runner.running?.id == a.id {
                                    ProgressView().controlSize(.mini)
                                } else {
                                    Image(systemName: a.icon).font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(a.confirm ? HelmColor.amber : HelmColor.lime)
                                }
                                Text(a.title).font(.system(.footnote, weight: .semibold))
                                    .foregroundStyle(HelmColor.textPrimary)
                            }
                            .padding(.horizontal, 12).padding(.vertical, 9)
                            .background(Capsule().fill(HelmColor.raised))
                            .overlay(Capsule().strokeBorder(HelmColor.hairlineStrong))
                        }
                        .buttonStyle(HelmPressStyle())
                        .disabled(runner.running != nil)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    // MARK: Disks

    @ViewBuilder private var disksSection: some View {
        if let disks = overview?.disks, !disks.isEmpty {
            VStack(alignment: .leading, spacing: HelmSpace.sm) {
                HelmSectionHeader(title: "Storage", trailing: "\(disks.count) mounts")
                VStack(alignment: .leading, spacing: HelmSpace.md) {
                    ForEach(disks) { d in
                        if d.ok {
                            Meter(label: d.mount, value: d.usedGB, limit: max(d.totalGB, 0.001),
                                  text: String(format: "%d%% · %@ free", d.usedPct, gb(d.freeGB)),
                                  tint: levelTint(Double(d.usedPct)))
                        } else {
                            HStack(spacing: HelmSpace.sm) {
                                PulseDot(color: HelmColor.red, size: 6)
                                Text(d.mount).font(.system(size: 10, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(HelmColor.textPrimary)
                                Spacer()
                                Text(d.error ?? "not responding").font(HelmFont.mono(.caption2)).foregroundStyle(HelmColor.red)
                            }
                        }
                    }
                }
                .padding(HelmSpace.lg)
                .helmCard()
            }
        }
    }

    private func gb(_ v: Double) -> String { v >= 1000 ? String(format: "%.1f TB", v / 1000) : String(format: "%.0f GB", v) }

    // MARK: GPU burst

    @ViewBuilder private var burstSection: some View {
        if !burst.isEmpty {
            VStack(alignment: .leading, spacing: HelmSpace.sm) {
                HelmSectionHeader(title: "GPU burst")
                VStack(spacing: HelmSpace.md) {
                    ForEach(burst) { m in burstRow(m) }
                }
                .padding(HelmSpace.lg)
                .helmCard()
            }
        }
    }

    private func burstRow(_ m: BurstModel) -> some View {
        HStack(spacing: HelmSpace.md) {
            HarnessBadge(harness: m.model, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(m.model.uppercased()).font(HelmFont.rowTitle).foregroundStyle(HelmColor.textPrimary)
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

    // MARK: Tools

    private var toolsSection: some View {
        VStack(alignment: .leading, spacing: HelmSpace.sm) {
            HelmSectionHeader(title: "Tools")
            VStack(spacing: 0) {
                toolRow("Shell console", "terminal") { ShellConsoleView() }
                toolRow("Files", "folder") { FileBrowserView(path: "/root") }
                toolRow("Claude history", "clock.arrow.circlepath") { ClaudeHistoryView() }
                toolRow("Journal errors (1h)", "exclamationmark.bubble") {
                    LogView(title: "Journal errors") { try await store.api.boxJournalErrors(minutes: 60) }
                }
                toolRow("All services", "gearshape.2") { UnitsView(initialScope: .all) }
                toolRow("Quick actions", "bolt", last: true) { ActionsView() }
            }
            .helmCard()
        }
    }

    private func toolRow<D: View>(_ title: String, _ icon: String, last: Bool = false,
                                  @ViewBuilder dest: @escaping () -> D) -> some View {
        VStack(spacing: 0) {
            NavigationLink { dest() } label: {
                HStack(spacing: HelmSpace.md) {
                    Image(systemName: icon).font(.system(size: 14)).foregroundStyle(HelmColor.textSecondary).frame(width: 22)
                    Text(title).font(.subheadline).foregroundStyle(HelmColor.textPrimary)
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(HelmColor.textTertiary)
                }
                .padding(.horizontal, HelmSpace.lg)
                .padding(.vertical, 13)
                .contentShape(Rectangle())
            }
            .buttonStyle(HelmPressStyle())
            if !last { Divider().overlay(HelmColor.hairline).padding(.leading, 50) }
        }
    }

    private func errorBanner(_ msg: String) -> some View {
        HStack(spacing: HelmSpace.sm) {
            Image(systemName: "wifi.exclamationmark")
            Text(msg).lineLimit(2)
            Spacer()
        }
        .font(.footnote)
        .foregroundStyle(HelmColor.amber)
        .padding(HelmSpace.md)
        .helmCard(stroke: HelmColor.amber.opacity(0.3))
    }

    // MARK: Loading

    private func refreshAll() async {
        async let a: Void = loadOverview()
        async let b: Void = loadMetrics()
        async let c: Void = loadBurst()
        async let d: Void = loadActions()
        _ = await (a, b, c, d)
    }

    private func loadOverview() async {
        guard store.config.isConfigured else { return }
        do {
            let o = try await store.api.boxOverview()
            withAnimation(HelmMotion.gentle) { overview = o }
            error = nil
        } catch is CancellationError {
        } catch {
            self.error = APIClient.describe(error)
        }
    }

    private func loadMetrics() async {
        guard store.config.isConfigured else { return }
        if let p = try? await store.api.boxMetrics(minutes: minutes, points: minutes == 15 ? 180 : 240) {
            points = p
        }
    }

    private func loadBurst() async {
        guard store.config.isConfigured else { return }
        if let b = try? await store.api.boxBurst() { burst = b }
    }

    private func loadActions() async {
        guard store.config.isConfigured else { return }
        if let a = try? await store.api.boxActions() { actions = a }
    }

    private func burstAction(_ model: String, _ action: String) async {
        busyModel = model
        defer { busyModel = nil }
        Haptics.tap()
        _ = try? await store.api.boxBurstAction(model, action: action)
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        await loadBurst()
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
                    .lineLimit(1)
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
