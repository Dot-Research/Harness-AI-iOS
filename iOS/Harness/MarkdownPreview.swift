import SwiftUI
import HarnessCore

/// One rendered Markdown block. `line` is the block's first line in the full note text (front matter
/// included), so a task checkbox can be toggled in place.
struct MarkdownBlock: Identifiable, Equatable {
    enum Kind: Equatable {
        case heading(Int)
        case paragraph
        case bullet(indent: Int)
        case numbered(indent: Int, marker: String)
        case task(indent: Int, done: Bool)
        case quote
        case code(language: String)
        case table
        case rule
    }
    var kind: Kind
    var text: String
    var line: Int
    var id: Int { line }
}

enum MarkdownBlocks {
    static func parse(_ fullText: String) -> [MarkdownBlock] {
        let lines = fullText.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var index = 0
        // Skip front matter; it's shown as properties.
        if lines.first == "---", let end = lines.dropFirst().firstIndex(where: { $0 == "---" || $0 == "..." }) { index = end + 1 }
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = [], paragraphStart = 0
        func flush() {
            if !paragraph.isEmpty { blocks.append(MarkdownBlock(kind: .paragraph, text: paragraph.joined(separator: "\n"), line: paragraphStart)) }
            paragraph = []
        }
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let indent = (line.prefix { $0 == " " || $0 == "\t" }.count) / 2
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flush()
                let fence = String(trimmed.prefix(3)), start = index
                var code: [String] = []
                index += 1
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(fence) { code.append(lines[index]); index += 1 }
                blocks.append(MarkdownBlock(kind: .code(language: String(trimmed.dropFirst(3))), text: code.joined(separator: "\n"), line: start))
                index += 1
                continue
            }
            if trimmed.isEmpty { flush(); index += 1; continue }
            if let heading = MarkdownNote.headingText(trimmed) {
                flush()
                blocks.append(MarkdownBlock(kind: .heading(trimmed.prefix { $0 == "#" }.count), text: heading, line: index))
            } else if ["---", "***", "___"].contains(trimmed.replacingOccurrences(of: " ", with: "")) {
                flush(); blocks.append(MarkdownBlock(kind: .rule, text: "", line: index))
            } else if let task = taskItem(trimmed) {
                flush(); blocks.append(MarkdownBlock(kind: .task(indent: indent, done: task.done), text: task.text, line: index))
            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
                flush(); blocks.append(MarkdownBlock(kind: .bullet(indent: indent), text: String(trimmed.dropFirst(2)), line: index))
            } else if let numbered = numberedItem(trimmed) {
                flush(); blocks.append(MarkdownBlock(kind: .numbered(indent: indent, marker: numbered.marker), text: numbered.text, line: index))
            } else if trimmed.hasPrefix(">") {
                flush()
                let start = index
                var quote: [String] = []
                while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    quote.append(String(lines[index].trimmingCharacters(in: .whitespaces).dropFirst()).trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                blocks.append(MarkdownBlock(kind: .quote, text: quote.joined(separator: "\n"), line: start))
                continue
            } else if trimmed.hasPrefix("|") {
                flush()
                let start = index
                var rows: [String] = []
                while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("|") { rows.append(lines[index]); index += 1 }
                blocks.append(MarkdownBlock(kind: .table, text: rows.joined(separator: "\n"), line: start))
                continue
            } else {
                if paragraph.isEmpty { paragraphStart = index }
                paragraph.append(trimmed)
            }
            index += 1
        }
        flush()
        return blocks
    }

    static func taskItem(_ trimmed: String) -> (done: Bool, text: String)? {
        for prefix in ["- [ ] ", "* [ ] ", "- [x] ", "* [x] ", "- [X] ", "* [X] "] where trimmed.hasPrefix(prefix) {
            return (prefix.lowercased().contains("x"), String(trimmed.dropFirst(prefix.count)))
        }
        return nil
    }

    static func numberedItem(_ trimmed: String) -> (marker: String, text: String)? {
        let digits = trimmed.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count <= 4 else { return nil }
        let rest = trimmed.dropFirst(digits.count)
        guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
        return (String(digits) + ".", String(rest.dropFirst(2)))
    }

    /// Toggles the checkbox on `line` of `text`.
    static func toggleTask(in text: String, line: Int) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.indices.contains(line) else { return text }
        let current = lines[line]
        if let range = current.range(of: "[ ] ") { lines[line] = current.replacingCharacters(in: range, with: "[x] ") }
        else if let range = current.range(of: "[x] ") ?? current.range(of: "[X] ") { lines[line] = current.replacingCharacters(in: range, with: "[ ] ") }
        return lines.joined(separator: "\n")
    }

    /// Inline Markdown with `[[links]]` and `#tags` turned into tappable harness-vault:// links.
    static func inline(_ text: String) -> AttributedString {
        var converted = ""
        var inCode = false
        var segment = ""
        func emit() {
            converted += inCode ? segment : linkify(segment)
            segment = ""
        }
        for character in text {
            if character == "`" { emit(); converted.append("`"); inCode.toggle(); continue }
            segment.append(character)
        }
        emit()
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)
        return (try? AttributedString(markdown: converted, options: options)) ?? AttributedString(text)
    }

    private static func linkify(_ text: String) -> String {
        var output = ""
        var rest = Substring(text)
        while let open = rest.range(of: "[["), let close = rest[open.upperBound...].range(of: "]]") {
            var before = String(rest[..<open.lowerBound])
            let embed = before.hasSuffix("!")
            if embed { before.removeLast() }
            output += tagged(before)
            let inner = String(rest[open.upperBound..<close.lowerBound])
            if let link = MarkdownNote.wikiLinks(in: "[[" + inner + "]]").first,
               let encoded = link.target.addingPercentEncoding(withAllowedCharacters: .alphanumerics) {
                let label = (embed ? "⧉ " : "") + escape(link.displayText)
                output += "[\(label)](harness-vault://open?target=\(encoded))"
            } else {
                output += "[[" + inner + "]]"
            }
            rest = rest[close.upperBound...]
        }
        return output + tagged(String(rest))
    }

    /// `#tag` -> tappable link, using the same rules as `MarkdownNote.inlineTags`.
    private static func tagged(_ text: String) -> String {
        let characters = Array(text)
        var output = ""
        var index = 0
        while index < characters.count {
            if characters[index] == "#", index == 0 || characters[index - 1].isWhitespace {
                var end = index + 1
                while end < characters.count, characters[end].isLetter || characters[end].isNumber || "_-/".contains(characters[end]) { end += 1 }
                let raw = String(characters[(index + 1)..<end])
                var tag = raw
                while tag.hasSuffix("/") { tag.removeLast() }
                if !tag.isEmpty, !tag.hasPrefix("/"), tag.contains(where: { !$0.isNumber }),
                   let encoded = tag.addingPercentEncoding(withAllowedCharacters: .alphanumerics) {
                    output += "[#\(tag)](harness-vault://tag?name=\(encoded))" + raw.dropFirst(tag.count)
                } else {
                    output += String(characters[index..<end])
                }
                index = end
            } else {
                output.append(characters[index])
                index += 1
            }
        }
        return output
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
    }
}

struct MarkdownPreview: View {
    let text: String
    var onToggleTask: ((Int) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(MarkdownBlocks.parse(text)) { block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    @ViewBuilder private func blockView(_ block: MarkdownBlock) -> some View {
        switch block.kind {
        case .heading(let level):
            Text(MarkdownBlocks.inline(block.text))
                .font(level == 1 ? .system(.title, design: .serif) : level == 2 ? .system(.title2, design: .serif) : .headline)
                .padding(.top, level <= 2 ? 6 : 2)
                .accessibilityAddTraits(.isHeader)
        case .paragraph:
            Text(MarkdownBlocks.inline(block.text)).font(.body).lineSpacing(5)
        case .bullet(let indent):
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("•").foregroundStyle(HarnessTheme.coral)
                Text(MarkdownBlocks.inline(block.text)).lineSpacing(4)
            }.padding(.leading, CGFloat(indent) * 18)
        case .numbered(let indent, let marker):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(marker).font(.body.monospacedDigit()).foregroundStyle(HarnessTheme.secondary)
                Text(MarkdownBlocks.inline(block.text)).lineSpacing(4)
            }.padding(.leading, CGFloat(indent) * 18)
        case .task(let indent, let done):
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Button { onToggleTask?(block.line) } label: {
                    Image(systemName: done ? "checkmark.square.fill" : "square")
                        .foregroundStyle(done ? HarnessTheme.green : HarnessTheme.secondary)
                        .frame(minWidth: 28, minHeight: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(onToggleTask == nil)
                .accessibilityLabel(done ? "Completed task" : "Open task")
                .accessibilityHint("Toggles the task")
                Text(MarkdownBlocks.inline(block.text))
                    .strikethrough(done, color: HarnessTheme.secondary)
                    .foregroundStyle(done ? HarnessTheme.secondary : HarnessTheme.text)
            }.padding(.leading, CGFloat(indent) * 18)
        case .quote:
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 2).fill(HarnessTheme.amber.opacity(0.6)).frame(width: 3)
                Text(MarkdownBlocks.inline(block.text)).italic().foregroundStyle(HarnessTheme.secondary)
            }.fixedSize(horizontal: false, vertical: true)
        case .code:
            ScrollView(.horizontal, showsIndicators: false) {
                Text(block.text).font(.system(.callout, design: .monospaced)).padding(14)
            }
            .background(HarnessTheme.surface, in: RoundedRectangle(cornerRadius: 12))
        case .table:
            ScrollView(.horizontal, showsIndicators: false) {
                Text(block.text).font(.system(.caption, design: .monospaced)).padding(12)
            }
            .background(HarnessTheme.surface, in: RoundedRectangle(cornerRadius: 12))
        case .rule:
            Divider().overlay(HarnessTheme.border)
        }
    }
}
