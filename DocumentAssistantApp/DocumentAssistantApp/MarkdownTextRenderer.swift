import UIKit

/// Renders Markdown into an `NSAttributedString` for display in a selectable
/// `UITextView` (the note preview).
///
/// Apple's `NSAttributedString(markdown:)` runs blocks together — it emits no line
/// break between a heading and the following paragraph, between list items, or
/// between paragraphs, and it collapses soft line breaks — which made note
/// previews read as one messy run-on line. This builds the layout directly from
/// parsed blocks (headings, bullets, numbered items, fenced code, paragraphs),
/// mirroring `MarkdownAnswerView`, so the preview matches the app's other Markdown
/// rendering while staying selectable for Fact Check.
enum MarkdownTextRenderer {

    static func render(_ text: String) -> NSAttributedString {
        let bodySize = UIFont.preferredFont(forTextStyle: .body).pointSize
        let result = NSMutableAttributedString()
        for (index, block) in parse(text).enumerated() {
            // A single newline between blocks; spacing is added via paragraph style
            // so we never rely on blank lines the parser would collapse.
            if index > 0 { result.append(NSAttributedString(string: "\n")) }
            result.append(attributed(block, bodySize: bodySize))
        }
        return result
    }

    // MARK: - Block model

    private enum Block {
        case heading(level: Int, content: String)
        case bullet(content: String)
        case numbered(marker: String, content: String)
        case code(String)
        case paragraph(String)
    }

    // MARK: - Block rendering

    private static func attributed(_ block: Block, bodySize: CGFloat) -> NSAttributedString {
        switch block {
        case .heading(let level, let content):
            let font = UIFont.systemFont(ofSize: bodySize * headingScale(level), weight: .bold)
            let style = NSMutableParagraphStyle()
            style.paragraphSpacingBefore = level <= 1 ? 2 : 8
            style.paragraphSpacing = 4
            return inline(content, base: font, color: .label, paragraphStyle: style)

        case .bullet(let content):
            return list(marker: "\u{2022}", markerWidth: 16, alignment: .left,
                        content: content, bodySize: bodySize)

        case .numbered(let marker, let content):
            return list(marker: marker, markerWidth: 26, alignment: .right,
                        content: content, bodySize: bodySize)

        case .code(let content):
            let font = UIFont.monospacedSystemFont(ofSize: bodySize * 0.92, weight: .regular)
            let style = NSMutableParagraphStyle()
            style.paragraphSpacingBefore = 4
            style.paragraphSpacing = 4
            style.firstLineHeadIndent = 8
            style.headIndent = 8
            return joinedLines(content, font: font, color: .label,
                               background: .secondarySystemBackground, paragraphStyle: style)

        case .paragraph(let content):
            let font = UIFont.systemFont(ofSize: bodySize)
            let style = NSMutableParagraphStyle()
            style.paragraphSpacing = 4
            style.lineSpacing = 2
            // Render each source line so the author's line breaks are preserved.
            let result = NSMutableAttributedString()
            for (index, line) in content.components(separatedBy: "\n").enumerated() {
                if index > 0 { result.append(NSAttributedString(string: "\n")) }
                result.append(inline(line, base: font, color: .label, paragraphStyle: style))
            }
            return result
        }
    }

    private static func headingScale(_ level: Int) -> CGFloat {
        switch level {
        case 1: return 1.45
        case 2: return 1.25
        case 3: return 1.12
        default: return 1.05
        }
    }

    /// A list row: a dimmed marker, a tab to a hanging indent, then the content so
    /// wrapped lines align under the first character (not under the marker).
    private static func list(marker: String, markerWidth: CGFloat, alignment: NSTextAlignment,
                             content: String, bodySize: CGFloat) -> NSAttributedString {
        let font = UIFont.systemFont(ofSize: bodySize)
        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = 0
        style.headIndent = markerWidth
        style.tabStops = [NSTextTab(textAlignment: alignment, location: markerWidth)]
        style.paragraphSpacing = 3
        let result = NSMutableAttributedString()
        result.append(NSAttributedString(string: marker + "\t", attributes: [
            .font: font,
            .foregroundColor: UIColor.secondaryLabel,
            .paragraphStyle: style
        ]))
        for (index, line) in content.components(separatedBy: "\n").enumerated() {
            if index > 0 { result.append(NSAttributedString(string: "\n")) }
            result.append(inline(line, base: font, color: .label, paragraphStyle: style))
        }
        return result
    }

    /// Renders each line of `content` (typically a code block) with a fixed font and
    /// optional background, preserving internal line breaks verbatim.
    private static func joinedLines(_ content: String, font: UIFont, color: UIColor,
                                    background: UIColor?,
                                    paragraphStyle: NSParagraphStyle) -> NSAttributedString {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraphStyle
        ]
        if let background { attributes[.backgroundColor] = background }
        let result = NSMutableAttributedString()
        for (index, line) in content.components(separatedBy: "\n").enumerated() {
            if index > 0 { result.append(NSAttributedString(string: "\n")) }
            result.append(NSAttributedString(string: line, attributes: attributes))
        }
        return result
    }

    // MARK: - Inline formatting

    /// Parses inline Markdown (bold, italic, code) within a single line and applies
    /// the given base font, color, and paragraph style. Falls back to plain text if
    /// the line has no inline markup or parsing fails.
    private static func inline(_ string: String, base: UIFont, color: UIColor,
                               paragraphStyle: NSParagraphStyle) -> NSAttributedString {
        let plain: [NSAttributedString.Key: Any] = [
            .font: base, .foregroundColor: color, .paragraphStyle: paragraphStyle
        ]
        guard let parsed = try? AttributedString(
            markdown: string,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) else {
            return NSAttributedString(string: string, attributes: plain)
        }
        let result = NSMutableAttributedString()
        for run in parsed.runs {
            let chunk = String(parsed[run.range].characters)
            guard !chunk.isEmpty else { continue }
            var attributes: [NSAttributedString.Key: Any] = [
                .foregroundColor: color, .paragraphStyle: paragraphStyle
            ]
            var font = base
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.code) {
                    font = UIFont.monospacedSystemFont(ofSize: base.pointSize, weight: .regular)
                    attributes[.backgroundColor] = UIColor.secondarySystemBackground
                } else {
                    font = applying(
                        to: base,
                        bold: intent.contains(.stronglyEmphasized),
                        italic: intent.contains(.emphasized)
                    )
                }
            }
            attributes[.font] = font
            result.append(NSAttributedString(string: chunk, attributes: attributes))
        }
        return result.length > 0 ? result : NSAttributedString(string: string, attributes: plain)
    }

    /// Adds bold/italic traits to a font, tolerating fonts that lack a trait variant.
    private static func applying(to base: UIFont, bold: Bool, italic: Bool) -> UIFont {
        var traits: UIFontDescriptor.SymbolicTraits = []
        if bold { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }
        guard !traits.isEmpty,
              let descriptor = base.fontDescriptor.withSymbolicTraits(traits) else { return base }
        return UIFont(descriptor: descriptor, size: base.pointSize)
    }

    // MARK: - Block parsing (mirrors MarkdownAnswerView)

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
            if line.hasPrefix("```") { flushParagraph(); inCode = true; continue }
            if line.isEmpty { flushParagraph(); continue }
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
        if inCode, !codeLines.isEmpty { blocks.append(.code(codeLines.joined(separator: "\n"))) }
        flushParagraph()
        return blocks
    }

    private static func bulletContent(_ line: String) -> String? {
        guard let first = line.first,
              first == "-" || first == "*" || first == "+" || first == "\u{2022}" else { return nil }
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
}
