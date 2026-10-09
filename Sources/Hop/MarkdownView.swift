import AppKit
import HopCore
import SwiftUI

/// Claude's answer laid out: headings, lists, code blocks, quotes and math, with
/// SwiftUI's inline Markdown (bold, italics, code, links) inside each block.
struct MarkdownView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(Markdown.blocks(text).enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func view(for block: Markdown.Block) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(inline(text))
                .font(.system(size: level <= 1 ? 16 : level == 2 ? 15 : 13, weight: .semibold))
                .padding(.top, 4)
        case .paragraph(let text):
            Text(inline(text))
        case .list(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(item.marker)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 14, alignment: .trailing)
                        Text(inline(item.text))
                    }
                    .padding(.leading, CGFloat(item.depth) * 16)
                }
            }
        case .code(let language, let code):
            CodeBlock(language: language, code: code)
        case .quote(let text):
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 1).fill(.tertiary).frame(width: 3)
                Text(inline(text)).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .math(let math):
            Text(math)
                .font(.system(size: 15, design: .serif))
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 2)
        case .rule:
            Divider()
        }
    }

    /// Inline math to Unicode, then SwiftUI's inline Markdown.
    private func inline(_ text: String) -> AttributedString {
        let prepared = Markdown.inlineMath(text)
        return (try? AttributedString(markdown: prepared, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(prepared)
    }
}

private struct CodeBlock: View {
    let language: String?
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language ?? "code").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                }
                .labelStyle(.titleAndIcon)
                .buttonStyle(.borderless)
                .font(.system(size: 11))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            Divider()
            ScrollView(.horizontal) {
                Text(code)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize()
                    .padding(10)
            }
        }
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}
