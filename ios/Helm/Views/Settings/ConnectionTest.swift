import SwiftUI

enum ConnectionTest {
    enum State {
        case idle
        case running
        case success(version: String, harnesses: [Harness])
        case failure(step: String, message: String)
    }

    static func run(_ config: ServerConfig) async -> State {
        let api = APIClient(config: config)
        let version: String
        do {
            let h = try await api.health()
            version = h["version"]?.string ?? "?"
            if h["ok"]?.bool == false { return .failure(step: "/health", message: "Server reported not ok.") }
        } catch {
            return .failure(step: "/health", message: APIClient.describe(error))
        }
        do {
            let hs = try await api.harnesses()
            return .success(version: version, harnesses: hs)
        } catch {
            return .failure(step: "/harnesses", message: APIClient.describe(error))
        }
    }
}

struct ConnectionTestResult: View {
    let state: ConnectionTest.State

    var body: some View {
        switch state {
        case .idle:
            EmptyView()
        case .running:
            HStack(spacing: HelmSpace.sm) {
                PulseDot(color: HelmColor.amber, size: 7)
                Text("probing /health")
                    .font(HelmFont.mono(.caption, weight: .medium))
                    .foregroundStyle(HelmColor.amber)
            }
            .padding(.vertical, 2)
            .transition(.opacity)
        case .success(let version, let harnesses):
            VStack(alignment: .leading, spacing: HelmSpace.sm) {
                HStack(spacing: HelmSpace.sm) {
                    PulseDot(color: HelmColor.lime, size: 7, isActive: false)
                    Text("Connected")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(HelmColor.lime)
                    Spacer(minLength: 0)
                    Text("helmd v\(version)")
                        .font(HelmFont.mono(.caption, weight: .medium))
                        .foregroundStyle(HelmColor.textSecondary)
                }
                if harnesses.isEmpty {
                    Text("no harnesses reported")
                        .font(HelmFont.mono(.caption))
                        .foregroundStyle(HelmColor.textTertiary)
                } else {
                    FlowRow(harnesses: harnesses)
                }
            }
            .padding(.vertical, 2)
            .transition(.opacity)
        case .failure(let step, let message):
            VStack(alignment: .leading, spacing: HelmSpace.xs) {
                HStack(spacing: HelmSpace.sm) {
                    Image(systemName: "xmark.octagon.fill")
                        .font(.subheadline)
                    Text("Failed")
                        .font(.subheadline.weight(.semibold))
                    Spacer(minLength: 0)
                    Text(step)
                        .font(HelmFont.mono(.caption, weight: .medium))
                }
                .foregroundStyle(HelmColor.red)
                Text(message)
                    .font(HelmFont.mono(.caption))
                    .foregroundStyle(HelmColor.textSecondary)
                    .textSelection(.enabled)
            }
            .padding(.vertical, 2)
            .transition(.opacity)
        }
    }
}

private struct FlowRow: View {
    let harnesses: [Harness]
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(harnesses) { h in
                    let style = HarnessStyle.of(h.id)
                    HStack(spacing: 4) {
                        Image(systemName: style.symbol)
                        Text(h.name)
                    }
                    .font(HelmFont.mono(.caption2, weight: .medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(style.color.opacity(h.available ? 0.14 : 0.05)))
                    .overlay(Capsule().strokeBorder(h.available ? style.color.opacity(0.3) : HelmColor.hairline, lineWidth: 0.5))
                    .foregroundStyle(h.available ? style.color : HelmColor.textTertiary)
                }
            }
        }
    }
}
