import SwiftUI

struct HarnessGrid: View {
    let harnesses: [Harness]
    @Binding var selection: String

    private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    var body: some View {
        if harnesses.isEmpty {
            HStack {
                ProgressView()
                Text("Loading harnesses\u{2026}").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 60)
        } else {
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(harnesses) { h in
                    HarnessCard(harness: h, isSelected: h.id == selection)
                        .onTapGesture {
                            guard h.available else { return }
                            Haptics.tap()
                            selection = h.id
                        }
                }
            }
        }
    }
}

struct HarnessCard: View {
    let harness: Harness
    let isSelected: Bool

    var body: some View {
        let style = HarnessStyle.of(harness.id)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                HarnessBadge(harness: harness.id, size: 30)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(style.color)
                }
            }
            Text(harness.name)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            Text(harness.available ? harness.command : (harness.note ?? "Unavailable"))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isSelected ? style.color.opacity(0.14) : Color(.tertiarySystemFill))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(isSelected ? style.color : .clear, lineWidth: 1.5)
        )
        .opacity(harness.available ? 1 : 0.45)
        .contentShape(Rectangle())
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint(harness.available ? "" : (harness.note ?? "Unavailable"))
    }
}
