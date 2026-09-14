import SwiftUI

/// Renders a streamed model answer as sensible formatted text instead of showing
/// raw Markdown symbols. It splits the answer into blocks (headings, bullets,
/// numbered items, fenced code, paragraphs) and renders each appropriately,
/// using inline Markdown parsing (bold, italic, code, links) within each block.
///
/// Parsing is tolerant of partial input, so it re-renders cleanly while tokens
/// are still streaming.
struct MarkdownAnswerView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Block model

    private enum Block {
        case heading(level: Int, content: String)
        case bullet(content: String)
        case numbered(marker: String, content: String)
        case code(String)
        case paragraph(String)
    }

    private var blocks: [Block] { Self.parse(text) }

    @ViewBuilder private func blockView(_ block: Block) -> some View {
        switch block {
        case .heading(let level, let content):
            Text(Self.inline(content))
                .font(Self.headingFont(level))
                .padding(.top, level <= 1 ? 4 : 2)
        case .bullet(let content):
            listRow(marker: "•", markerWidth: 12, alignment: .center, content: content)
        case .numbered(let marker, let content):
            listRow(marker: marker, markerWidth: 24, alignment: .trailing, content: content)
        case .code(let content):
            Text(content)
                .font(.system(.footnote, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                .textSelection(.enabled)
        case .paragraph(let content):
            Text(Self.inline(content))
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }

    private func listRow(marker: String, markerWidth: CGFloat, alignment: HorizontalAlignment, content: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(marker)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: markerWidth, alignment: alignment == .center ? .center : .trailing)
            Text(Self.inline(content))
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }

    private static func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .headline
        case 2: return .subheadline.bold()
        case 3: return .footnote.bold()
        default: return .caption.bold()
        }
    }

    // MARK: - Parsing

    private static func parse(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var codeLines: [String] = []
        var inCode = false

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: "\n")))
            paragraph.removeAll()
        }

        for rawLine in text.components(separatedBy: "\n") {
            // Inside a fenced code block, preserve the raw line until the fence closes.
            if inCode {
                if rawLine.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    blocks.append(.code(codeLines.joined(separator: "\n")))
                    codeLines.removeAll()
                    inCode = false
                } else {
                    codeLines.append(rawLine)
                }
                continue
            }

            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)

            if line.hasPrefix("```") {
                flushParagraph()
                inCode = true
                continue
            }
            if line.isEmpty {
                flushParagraph()
                continue
            }
            if line.hasPrefix("#") {
                let level = line.prefix(while: { $0 == "#" }).count
                let content = line.dropFirst(level).trimmingCharacters(in: .whitespaces)
                if (1...6).contains(level), !content.isEmpty {
                    flushParagraph()
                    blocks.append(.heading(level: level, content: content))
                    continue
                }
            }
            if let bullet = bulletContent(line) {
                flushParagraph()
                blocks.append(.bullet(content: bullet))
                continue
            }
            if let (marker, content) = numberedContent(line) {
                flushParagraph()
                blocks.append(.numbered(marker: marker, content: content))
                continue
            }
            paragraph.append(line)
        }

        if inCode, !codeLines.isEmpty {
            blocks.append(.code(codeLines.joined(separator: "\n")))
        }
        flushParagraph()
        return blocks
    }

    private static func bulletContent(_ line: String) -> String? {
        guard let first = line.first, first == "-" || first == "*" || first == "+" || first == "•" else { return nil }
        let rest = line.dropFirst()
        guard rest.first == " " else { return nil }
        let content = rest.trimmingCharacters(in: .whitespaces)
        return content.isEmpty ? nil : content
    }

    private static func numberedContent(_ line: String) -> (String, String)? {
        let digits = line.prefix(while: { $0.isNumber })
        guard !digits.isEmpty, digits.count <= 2 else { return nil }
        let rest = line.dropFirst(digits.count)
        guard let delim = rest.first, delim == "." || delim == ")" else { return nil }
        let afterDelim = rest.dropFirst()
        guard afterDelim.first == " " else { return nil }
        let content = afterDelim.trimmingCharacters(in: .whitespaces)
        guard !content.isEmpty else { return nil }
        return (String(digits) + String(delim), content)
    }

    private static func inline(_ string: String) -> AttributedString {
        (try? AttributedString(
            markdown: string,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(string)
    }
}
