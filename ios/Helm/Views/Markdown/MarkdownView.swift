import SwiftUI

struct MarkdownView: View {
    let text: String

    var body: some View {
        let blocks = MarkdownParser.parse(text)
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                BlockView(block: block)
            }
        }
        .foregroundStyle(HelmColor.textPrimary)
        .tint(HelmColor.lime)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct BlockView: View {
    let block: MarkdownBlock

    var body: some View {
        switch block {
        case .paragraph(let t):
            StyledInlineText(source: t)
        case .heading(let level, let t):
            StyledInlineText(source: t)
                .font(Self.headingFont(level))
                .tracking(level <= 1 ? -0.4 : -0.2)
                .foregroundStyle(HelmColor.textPrimary)
                .padding(.top, level <= 2 ? 6 : 2)
        case .code(let lang, let code):
            CodeBlockView(language: lang, code: code)
        case .listItem(let indent, let marker, let t):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(marker)
                    .font(HelmFont.mono(.callout, weight: .medium))
                    .foregroundStyle(HelmColor.textTertiary)
                    .frame(minWidth: 14, alignment: .trailing)
                StyledInlineText(source: t)
            }
            .padding(.leading, CGFloat(indent) * 16)
        case .quote(let t):
            HStack(spacing: 12) {
                Rectangle()
                    .fill(HelmColor.hairlineStrong)
                    .frame(width: 2)
                StyledInlineText(source: t)
                    .foregroundStyle(HelmColor.textSecondary)
                    .padding(.vertical, 2)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .table(let rows):
            TableBlock(rows: rows)
        case .rule:
            Rectangle()
                .fill(HelmColor.hairlineStrong)
                .frame(height: 1)
                .padding(.vertical, 6)
        }
    }

    private static func headingFont(_ level: Int) -> Font {
        switch level {
        case ...1: return .system(.title3, design: .default, weight: .bold)
        case 2: return .system(.headline, design: .default, weight: .bold)
        default: return .system(.subheadline, design: .default, weight: .bold)
        }
    }
}

/// InlineText with Helm styling for inline code and links. Only used inside
/// MarkdownView; `InlineText.attributed(_:)` stays unstyled for other callers.
private struct StyledInlineText: View {
    let source: String

    var body: some View {
        Text(Self.styled(source))
            .fixedSize(horizontal: false, vertical: true)
    }

    static func styled(_ s: String) -> AttributedString {
        var out = InlineText.attributed(s)
        let codeInk: Color = HelmColor.limeGlow
        let codeFill: Color = Color.white.opacity(0.07)
        let linkInk: Color = HelmColor.lime
        for run in out.runs {
            if let intent = run.inlinePresentationIntent, intent.contains(.code) {
                out[run.range].foregroundColor = codeInk
                out[run.range].backgroundColor = codeFill
            }
            if run.link != nil {
                out[run.range].foregroundColor = linkInk
            }
        }
        return out
    }
}

struct InlineText: View {
    let source: String
    init(_ source: String) { self.source = source }

    var body: some View {
        Text(Self.attributed(source))
            .fixedSize(horizontal: false, vertical: true)
    }

    static func attributed(_ s: String) -> AttributedString {
        let opts = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        return (try? AttributedString(markdown: s, options: opts)) ?? AttributedString(s)
    }
}

private struct TableBlock: View {
    let rows: [String]

    var body: some View {
        let parsed = rows
            .filter { row in !row.replacingOccurrences(of: "|", with: "").allSatisfy { "-: ".contains($0) } }
            .map { row in
                row.trimmingCharacters(in: CharacterSet(charactersIn: "| "))
                    .components(separatedBy: "|")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
            }
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                ForEach(Array(parsed.enumerated()), id: \.offset) { idx, cells in
                    GridRow {
                        ForEach(Array(cells.enumerated()), id: \.offset) { _, c in
                            Text(StyledInlineText.styled(c))
                                .font(idx == 0 ? .footnote.weight(.semibold) : .footnote)
                                .foregroundStyle(idx == 0 ? HelmColor.textPrimary : HelmColor.textSecondary)
                                .fixedSize()
                        }
                    }
                    if idx == 0 {
                        Rectangle()
                            .fill(HelmColor.hairlineStrong)
                            .frame(height: 1)
                            .gridCellUnsizedAxes(.horizontal)
                    }
                }
            }
            .padding(12)
        }
        .background(HelmColor.surface, in: RoundedRectangle(cornerRadius: HelmRadius.control, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: HelmRadius.control, style: .continuous).strokeBorder(HelmColor.hairline, lineWidth: 1))
    }
}
