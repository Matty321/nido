// SPDX-License-Identifier: Apache-2.0
import SwiftUI

/// Markdown in the design's type: a chat answer, the release notes. Each block is its own view
/// compared by value, so while an answer streams only the block that grows is laid out again.
struct NidoMarkdown: View {
    private let blocks: [MarkdownBlock]

    init(_ text: String) {
        blocks = MarkdownBlock.parse(text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            ForEach(blocks.indices, id: \.self) { index in
                NidoMarkdownBlock(block: blocks[index]).equatable()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct NidoMarkdownBlock: View, Equatable {
    let block: MarkdownBlock

    var body: some View {
        switch block {
        case .paragraph(let text):
            inline(text)
        case .heading(let level, let text):
            inline(text, size: level == 1 ? Theme.TypeSize.headline : Theme.TypeSize.body, weight: .semibold)
                .padding(.top, Theme.Space.xs)
                .accessibilityAddTraits(.isHeader)
        case .listItem(let marker, let depth, let text):
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                Text(marker)
                    .font(.nido(Theme.TypeSize.body))
                    .foregroundStyle(Theme.Color.textSecondary)
                    .monospacedDigit()
                    .frame(minWidth: Theme.Layout.markdownMarkerWidth, alignment: .trailing)
                inline(text)
            }
            .padding(.leading, CGFloat(depth) * Theme.Layout.markdownListIndent)
        case .code(let language, let text, _):
            code(language: language, text: text)
        case .quote(let text):
            HStack(spacing: Theme.Space.s) {
                Rectangle()
                    .fill(Theme.Color.border)
                    .frame(width: Theme.Layout.markdownQuoteBar)
                inline(text, color: Theme.Color.textSecondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .rule:
            Divider()
        }
    }

    private func inline(
        _ text: String, size: CGFloat = Theme.TypeSize.body, weight: Font.Weight = .regular,
        color: Color = Theme.Color.textPrimary
    ) -> some View {
        Text(Self.styled(MarkdownBlock.inline(text), size: size))
            .font(.nido(size, weight))
            .foregroundStyle(color)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Only a web link opens, in the browser (checked again here, whatever the text holds).
            .environment(\.openURL, OpenURLAction { url in
                MarkdownBlock.isWebLink(url) ? .systemAction : .discarded
            })
    }

    private func code(language: String?, text: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            if let language {
                Text(language)
                    .font(.nido(Theme.TypeSize.caption, .semibold))
                    .foregroundStyle(Theme.Color.textSecondary)
            }
            ScrollView(.horizontal) {
                Text(text)
                    .font(.system(size: Theme.TypeSize.body, design: .monospaced))
                    .foregroundStyle(Theme.Color.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize()
            }
        }
        .padding(Theme.Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Color.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.s))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.s)
                .strokeBorder(Theme.Color.border, lineWidth: Theme.Layout.hairline)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(language.map { Text("\($0) code", comment: "A code block; the programming language.") }
            ?? Text("Code", comment: "A code block."))
        .accessibilityValue(text)
    }

    /// Inline code in the monospaced type on a raised background; the rest keeps the Text's font.
    static func styled(_ text: AttributedString, size: CGFloat) -> AttributedString {
        var text = text
        for run in text.runs where run.inlinePresentationIntent?.contains(.code) == true {
            text[run.range].font = .system(size: size, design: .monospaced)
            text[run.range].backgroundColor = Theme.Color.surfaceRaised
        }
        return text
    }
}
