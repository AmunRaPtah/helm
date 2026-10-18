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
        case .idle, .running:
            EmptyView()
        case .success(let version, let harnesses):
            VStack(alignment: .leading, spacing: 8) {
                Label("Connected to helmd v\(version)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.subheadline.weight(.medium))
                if harnesses.isEmpty {
                    Text("No harnesses reported.").font(.footnote).foregroundStyle(.secondary)
                } else {
                    FlowRow(harnesses: harnesses)
                }
            }
            .padding(.vertical, 2)
        case .failure(let step, let message):
            VStack(alignment: .leading, spacing: 4) {
                Label("\(step) failed", systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                    .font(.subheadline.weight(.medium))
                Text(message).font(.footnote).foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
        }
    }
}

private struct FlowRow: View {
    let harnesses: [Harness]
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(harnesses) { h in
                    HStack(spacing: 4) {
                        Image(systemName: HarnessStyle.of(h.id).symbol)
                        Text(h.name)
                    }
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(HarnessStyle.of(h.id).color.opacity(h.available ? 0.18 : 0.06), in: Capsule())
                    .foregroundStyle(h.available ? HarnessStyle.of(h.id).color : .secondary)
                }
            }
        }
    }
}
