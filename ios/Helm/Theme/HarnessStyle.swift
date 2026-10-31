import SwiftUI

/// Accent colour and glyph per harness id.
struct HarnessStyle {
    let color: Color
    let symbol: String
    let shortName: String

    static func of(_ id: String) -> HarnessStyle {
        switch id.lowercased() {
        case "claude": return .init(color: Color(hex: 0xD97757), symbol: "sparkle", shortName: "Claude")
        case "codex": return .init(color: Color(hex: 0x10A37F), symbol: "chevron.left.forwardslash.chevron.right", shortName: "Codex")
        case "ds": return .init(color: Color(hex: 0x4D6BFE), symbol: "water.waves", shortName: "DeepSeek")
        case "cc": return .init(color: Color(hex: 0xA970FF), symbol: "bolt.fill", shortName: "Compound")
        case "agy": return .init(color: Color(hex: 0xF4B400), symbol: "atom", shortName: "Antigravity")
        case "dsh": return .init(color: Color(hex: 0x38BDF8), symbol: "terminal", shortName: "DSH")
        case "glm": return .init(color: Color(hex: 0x22C55E), symbol: "cpu.fill", shortName: "GLM")
        case "dsv": return .init(color: Color(hex: 0x0EA5E9), symbol: "water.waves", shortName: "DeepSeek V4")
        case "sukuna": return .init(color: Color(hex: 0xDC2626), symbol: "flame.fill", shortName: "Sukuna")
        default: return .init(color: .gray, symbol: "cpu", shortName: id)
        }
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}

struct HarnessBadge: View {
    let harness: String
    var size: CGFloat = 36

    var body: some View {
        let style = HarnessStyle.of(harness)
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(style.color.opacity(0.18))
            Image(systemName: style.symbol)
                .font(.system(size: size * 0.44, weight: .semibold))
                .foregroundStyle(style.color)
        }
        .frame(width: size, height: size)
        .accessibilityLabel(style.shortName)
    }
}
