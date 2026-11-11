import SwiftUI

struct CodeBlockView: View {
    let language: String
    let code: String
    @State private var copied = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: HelmRadius.control, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: HelmSpace.sm) {
                Text(language.isEmpty ? "code" : language.lowercased())
                    .font(HelmFont.mono(.caption2, weight: .medium))
                    .tracking(0.6)
                    .foregroundStyle(HelmColor.textTertiary)
                Spacer()
                Button {
                    UIPasteboard.general.string = code
                    Haptics.tap()
                    copied = true
                    Task {
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        copied = false
                    }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(HelmFont.mono(.caption2, weight: .medium))
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(copied ? HelmColor.lime : HelmColor.textSecondary)
                .helmAnimation(HelmMotion.snappy, value: copied)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Color.white.opacity(0.025))
            .overlay(alignment: .bottom) {
                Rectangle().fill(HelmColor.hairline).frame(height: 1)
            }

            ScrollView(.horizontal, showsIndicators: true) {
                Text(code)
                    .font(HelmFont.mono(.footnote))
                    .foregroundStyle(HelmColor.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(12)
            }
        }
        .background(HelmColor.surface, in: shape)
        .clipShape(shape)
        .overlay(shape.strokeBorder(HelmColor.hairlineStrong, lineWidth: 1))
    }
}
